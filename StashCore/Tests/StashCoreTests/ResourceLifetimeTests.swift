import XCTest
import CSQLite
import CoreData
@testable import StashCore

final class ResourceLifetimeTests: XCTestCase {
    @MainActor func testSearchIndexConfigurationAndSchemaFailuresCloseAcquiredConnections() throws {
        let configurationProbe = SQLiteLifetimeProbe()
        XCTAssertThrowsError(try configurationProbe.makeIndex(url: nil, failConfiguration: true))
        XCTAssertEqual(configurationProbe.acquired, 1)
        XCTAssertEqual(configurationProbe.released, 1)

        let folder = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let corruptDatabase = folder.appendingPathComponent("corrupt.sqlite")
        try Data(repeating: 0xFF, count: 512).write(to: corruptDatabase)
        let schemaProbe = SQLiteLifetimeProbe()
        XCTAssertThrowsError(try schemaProbe.makeIndex(url: corruptDatabase))
        XCTAssertEqual(schemaProbe.acquired, 1)
        XCTAssertEqual(schemaProbe.released, 1)
    }

    @MainActor func testOpenFailureSurfacesAndExplicitCloseIsIdempotent() throws {
        let folder = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let probe = SQLiteLifetimeProbe()
        XCTAssertThrowsError(try probe.makeIndex(url: folder.appendingPathComponent("absent/index.sqlite")))
        XCTAssertEqual(probe.acquired, 0, "Opening failed before the connection-configuration seam")
        try autoreleasepool {
            let index = try probe.makeIndex(url: nil)
            index.close()
            index.close()
            XCTAssertEqual(probe.released, 1)
            XCTAssertThrowsError(try index.upsert(ClipItem(kind: .text, text: "closed")))
        }
        XCTAssertEqual(probe.acquired, 1)
        XCTAssertEqual(probe.released, 1, "Discard after explicit close must not dispose twice")
    }

    @MainActor func testStoreInitializationFailureReleasesItsAcquiredIndex() throws {
        let folder = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        // A directory where a database file must be makes Core Data fail after
        // the search connection was acquired, without touching a real library.
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("History.sqlite"), withIntermediateDirectories: false)
        let probe = SQLiteLifetimeProbe()
        let center = CountingNotificationCenter()
        try autoreleasepool {
            XCTAssertThrowsError(try LibraryStore(directory: folder, inMemory: false, syncEnabled: false,
                                                 notificationCenter: center, makeIndex: { try probe.makeIndex(url: nil) }))
        }
        XCTAssertEqual(probe.acquired, 1)
        XCTAssertEqual(probe.released, 1)
        XCTAssertEqual(center.activeCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("History.sqlite").path))
    }

    @MainActor func testLibraryReplacementAndQueuedCallbacksPreservePersistentContent() async throws {
        let folder = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let probe = SQLiteLifetimeProbe()
        let center = CountingNotificationCenter()
        let item = ClipItem(kind: .text, text: "persist across replacement")
        weak var discarded: LibraryStore?
        try autoreleasepool {
            var store: LibraryStore? = try LibraryStore(directory: folder, inMemory: false, syncEnabled: false,
                                                      notificationCenter: center, makeIndex: { try probe.makeIndex(url: nil) })
            try store?.add(item)
            discarded = store
            store = try LibraryStore(directory: folder, inMemory: false, syncEnabled: false,
                                     notificationCenter: center, makeIndex: { try probe.makeIndex(url: nil) })
            XCTAssertNil(discarded)
            XCTAssertEqual(store?.items.map(\.id), [item.id])
            XCTAssertEqual(center.activeCount, 2)
            XCTAssertEqual(probe.released, 1)
            // Tasks queued while a live library is on MainActor must not keep
            // it alive until their later actor turn.
            for callback in center.queuedCallbacks {
                callback(Notification(name: .NSPersistentStoreRemoteChange))
            }
            discarded = store
            store = nil
        }
        XCTAssertNil(discarded)
        XCTAssertEqual(center.activeCount, 0)
        XCTAssertEqual(probe.acquired, 2)
        XCTAssertEqual(probe.released, 2)
        // Deliver callbacks already copied by the system before deregistration.
        // Their Tasks must keep the weak-library check through MainActor dispatch.
        for callback in center.queuedCallbacks {
            callback(Notification(name: .NSPersistentStoreRemoteChange))
        }
        await Task.yield()
        XCTAssertNil(discarded)
        XCTAssertEqual(center.activeCount, 0)
        let reopened = try LibraryStore(directory: folder)
        XCTAssertEqual(reopened.items.map(\.id), [item.id])
    }

    private func fixtureDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("stash-lifetime-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @MainActor func testDiscardedLibrariesReleaseSearchConnectionsAndNotificationRegistrations() throws {
        let probe = SQLiteLifetimeProbe()
        let center = CountingNotificationCenter()
        for _ in 0..<3 {
            try autoreleasepool {
                let store = try LibraryStore(directory: nil, inMemory: true, syncEnabled: false,
                                             notificationCenter: center, makeIndex: { try probe.makeIndex(url: nil) })
                try store.add(ClipItem(kind: .text, text: "short-lived library"))
                XCTAssertEqual(center.activeCount, 2)
            }
            XCTAssertEqual(center.activeCount, 0, "A discarded library must unregister both observers")
        }
        XCTAssertEqual(probe.acquired, 3)
        XCTAssertEqual(probe.released, 3)
    }

    @MainActor func testDiscardedSearchIndexesCloseTheirSQLiteConnections() throws {
        let probe = SQLiteLifetimeProbe()
        for _ in 0..<4 {
            try autoreleasepool {
                let index = try probe.makeIndex(url: nil)
                let item = ClipItem(kind: .text, text: "temporary index")
                try index.upsert(item)
                XCTAssertEqual(try index.search("temporary"), [item.id])
            }
        }
        XCTAssertEqual(probe.acquired, 4)
        XCTAssertEqual(probe.released, 4, "SQLite must invoke the registered native destructor when each index is discarded")
    }
}

/// SQLite owns the function's user data, releasing it only when the real
/// connection closes. This observes native disposal rather than ARC alone.
private final class SQLiteLifetimeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var acquisitions = 0
    private var releases = 0

    var acquired: Int { lock.withLock { acquisitions } }
    var released: Int { lock.withLock { releases } }

    @MainActor func makeIndex(url: URL?, failConfiguration: Bool = false) throws -> SearchIndex {
        try SearchIndex(url: url) { database in
            self.lock.withLock { self.acquisitions += 1 }
            let result = sqlite3_create_function_v2(database, "stash_lifetime_probe", 0, SQLITE_UTF8, Unmanaged.passRetained(self).toOpaque(), { context, _, _ in
                sqlite3_result_null(context)
            }, nil, nil, { pointer in
                guard let pointer else { return }
                let probe = Unmanaged<SQLiteLifetimeProbe>.fromOpaque(pointer).takeRetainedValue()
                probe.lock.withLock { probe.releases += 1 }
            })
            guard result == SQLITE_OK else { throw NSError(domain: "Stash.SQLiteLifetimeTest", code: Int(result)) }
            if failConfiguration { throw CocoaError(.coderInvalidValue) }
        }
    }
}

/// The actual NotificationCenter still performs registration and removal; only
/// the system boundary is counted to verify that releasing a library unregisters.
private final class CountingNotificationCenter: NotificationCenter, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: Set<ObjectIdentifier> = []
    private var callbacks: [@Sendable (Notification) -> Void] = []
    var activeCount: Int { lock.withLock { tokens.count } }
    var queuedCallbacks: [@Sendable (Notification) -> Void] { lock.withLock { callbacks } }

    override func addObserver(forName name: NSNotification.Name?, object obj: Any?, queue: OperationQueue?, using block: @escaping @Sendable (Notification) -> Void) -> NSObjectProtocol {
        let token = super.addObserver(forName: name, object: obj, queue: queue, using: block)
        lock.withLock {
            tokens.insert(ObjectIdentifier(token))
            callbacks.append(block)
        }
        return token
    }
    override func removeObserver(_ observer: Any) {
        _ = lock.withLock { tokens.remove(ObjectIdentifier(observer as AnyObject)) }
        super.removeObserver(observer)
    }
}
