import XCTest
import CoreData
import Darwin
@testable import StashCore

final class ManagedCleanupTests: XCTestCase {
    private func fixture() throws -> (URL, URL, ClipItem) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.txt")
        try Data("saved attachment".utf8).write(to: source)
        let directory = root.appendingPathComponent("library")
        let item = try FileAssets.importFile(from: source, name: "note.txt", type: "public.plain-text", directory: directory)
        return (root, directory, item)
    }
    @MainActor func testErasureRemovesImportedManagedCopy() throws {
        let (root, directory, item) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(directory: directory)
        try store.add(item)
        try store.eraseHistory()
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try FileAssets.managedFolder(for: item.id, directory: directory).path))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("source.txt")), Data("saved attachment".utf8))
    }
    @MainActor func testDeletionRemovesCopyAndUndoRecreatesSavedBytes() throws {
        let (root, directory, item) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(directory: directory)
        try store.add(item)
        let board = try store.createBoard(name: "Keep newer metadata")
        try store.pin([item.id], to: board.id)
        try store.delete([item.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: URL(string: item.fileURLs[0])!.path))
        var renamed = board; renamed.name = "New name"
        try store.updateBoard(renamed)
        try store.undo()
        XCTAssertEqual(store.pinboards.first?.name, "New name")
        let restored = try store.materialized(XCTUnwrap(store.items.first))
        XCTAssertEqual(try Data(contentsOf: FileAssets.resolve(restored, directory: directory)), Data("saved attachment".utf8))
    }
    @MainActor func testStaleInstanceErasurePreservesNewPinAndRetentionKeepsAttachment() throws {
        let (root, directory, item) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try LibraryStore(directory: directory)
        var expired = item; expired.createdAt = Date(timeIntervalSince1970: 1)
        try first.add(expired)
        let second = try LibraryStore(directory: directory)
        let board = try second.createBoard(name: "Saved")
        try second.pin([item.id], to: board.id)
        try first.eraseHistory()
        try first.applyRetention()
        XCTAssertEqual(first.items.first?.pinboardID, board.id)
        XCTAssertEqual(try Data(contentsOf: FileAssets.resolve(try first.materialized(XCTUnwrap(first.items.first)), directory: directory)), item.data)
        XCTAssertEqual(try first.sharedGraphItemIDs(board.id), [item.id])
    }
    @MainActor func testRetentionDeletesExpiredUnpinnedCopy() throws {
        let (root, directory, item) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(directory: directory)
        var expired = item; expired.createdAt = Date(timeIntervalSince1970: 1)
        try store.add(expired)
        try store.applyRetention()
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: URL(string: item.fileURLs[0])!.path))
    }
    @MainActor func testBoardDeletionCleansAndUndoRestoresBoardAttachment() throws {
        let (root, directory, item) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(directory: directory)
        try store.add(item)
        let board = try store.createBoard(name: "Deleted board")
        try store.pin([item.id], to: board.id)
        try store.deleteBoard(board.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: URL(string: item.fileURLs[0])!.path))
        try store.undo()
        XCTAssertEqual(store.pinboards.first?.id, board.id)
        XCTAssertEqual(try Data(contentsOf: FileAssets.resolve(try store.materialized(XCTUnwrap(store.items.first)), directory: directory)), item.data)
    }
    @MainActor func testFailedDeletionKeepsRecordAndFile() throws {
        let (root, directory, item) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(directory: directory)
        try store.add(item)
        store.writePermissionCheck = { _ in false }
        XCTAssertThrowsError(try store.delete([item.id]))
        XCTAssertEqual(store.items.first?.id, item.id)
        XCTAssertEqual(try Data(contentsOf: URL(string: item.fileURLs[0])!), item.data)
    }
    @MainActor func testPostCommitFailureRetriesAndProtectsResurrectedIdentity() throws {
        let (root, directory, item) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(directory: directory)
        try store.add(item)
        store.managedFileRemoval = { _ in throw CocoaError(.fileWriteNoPermission) }
        XCTAssertThrowsError(try store.delete([item.id])) { error in
            XCTAssertTrue(error is LibraryStore.ManagedFileCleanupError)
        }
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: URL(string: item.fileURLs[0])!.path))
        let other = try LibraryStore(directory: directory)
        try other.add(item)
        store.managedFileRemoval = nil
        try store.retryManagedFileCleanup()
        XCTAssertEqual(try Data(contentsOf: URL(string: item.fileURLs[0])!), item.data)
        try store.delete([item.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: URL(string: item.fileURLs[0])!.path))
        try store.retryManagedFileCleanup()
    }
    @MainActor func testErasureRetriesPendingCleanupAndClearsUndo() throws {
        let (root, directory, item) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(directory: directory)
        try store.add(item)
        store.managedFileRemoval = { _ in throw CocoaError(.fileWriteNoPermission) }
        XCTAssertThrowsError(try store.delete([item.id]))
        store.managedFileRemoval = nil
        try store.eraseHistory()
        try store.undo()
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: URL(string: item.fileURLs[0])!.path))
    }
    @MainActor func testCleanupNeverSweepsAnImportedFileAwaitingDatabaseSave() throws {
        let (root, directory, item) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(directory: directory)
        try store.add(item)
        let importing = try FileAssets.importFile(from: root.appendingPathComponent("source.txt"), name: "incoming.txt", type: "public.plain-text", directory: directory)
        try store.eraseHistory()
        XCTAssertEqual(try Data(contentsOf: URL(string: importing.fileURLs[0])!), importing.data)
        try store.add(importing)
        XCTAssertEqual(store.items.first?.id, importing.id)
    }
    @MainActor func testExternalReferenceAndSymlinkEscapeAreNeverRemoved() throws {
        let (root, directory, item) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(directory: directory)
        var reference = ClipItem(kind: .file)
        reference.fileURLs = [root.appendingPathComponent("source.txt").absoluteString]
        try store.add(reference)
        try store.delete([reference.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("source.txt").path))
        let owned = try FileAssets.managedFolder(for: item.id, directory: directory)
        try FileManager.default.removeItem(at: owned)
        try FileManager.default.createSymbolicLink(at: owned, withDestinationURL: root)
        try store.add(item)
        XCTAssertThrowsError(try store.delete([item.id]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("source.txt").path))
    }
    @MainActor func testDatabaseSaveFailurePreservesRecordAndAttachment() throws {
        let (root, directory, item) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(directory: directory)
        try store.add(item)
        store.persistenceSaveCheck = { throw CocoaError(.fileWriteOutOfSpace) }
        XCTAssertThrowsError(try store.eraseHistory())
        let reopened = try LibraryStore(directory: directory)
        XCTAssertEqual(reopened.items.first?.id, item.id)
        XCTAssertEqual(try Data(contentsOf: URL(string: item.fileURLs[0])!), item.data)
        store.persistenceSaveCheck = nil
        try store.eraseHistory()
        XCTAssertFalse(FileManager.default.fileExists(atPath: URL(string: item.fileURLs[0])!.path))
    }
    @MainActor func testRetryPreservesSharedOnlyCommittedOwner() throws {
        let (root, directory, item) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(directory: directory)
        try store.add(item)
        store.managedFileRemoval = { _ in throw CocoaError(.fileWriteNoPermission) }
        XCTAssertThrowsError(try store.delete([item.id]))
        let writer = try LibraryStore(directory: directory)
        try writer.add(item)
        let board = try writer.createBoard(name: "Shared surviving owner")
        try writer.pin([item.id], to: board.id)
        // Platform fixture: accepted-share ownership can contain no private original.
        let request = NSFetchRequest<NSManagedObject>(entityName: "ClipRecord")
        request.predicate = NSPredicate(format: "id == %@", item.id.uuidString)
        for object in try writer.context.fetch(request) { writer.context.delete(object) }
        try writer.context.save()
        store.managedFileRemoval = nil
        try store.retryManagedFileCleanup()
        XCTAssertEqual(try store.sharedGraphItemIDs(board.id), [item.id])
        XCTAssertEqual(try Data(contentsOf: URL(string: item.fileURLs[0])!), item.data)
    }
    @MainActor func testCleanupHoldsTheSameLockAsActiveImportAndResolution() throws {
        let (root, directory, item) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(directory: directory)
        try store.add(item)
        var inspected = false
        store.managedFileRemoval = { folder in
            let fd = open(directory.appendingPathComponent(".attachment-lock").path, O_RDWR | O_NOFOLLOW)
            XCTAssertGreaterThanOrEqual(fd, 0)
            guard fd >= 0 else { throw CocoaError(.fileReadUnknown) }
            defer { close(fd) }
            let result = flock(fd, LOCK_EX | LOCK_NB)
            let failure = errno
            if result == 0 { flock(fd, LOCK_UN) }
            XCTAssertEqual(result, -1)
            XCTAssertEqual(failure, EWOULDBLOCK)
            inspected = true
            try FileManager.default.removeItem(at: folder)
        }
        try store.delete([item.id])
        XCTAssertTrue(inspected)
    }
    @MainActor func testPinnedAliasInAnotherStorePreservesManagedOriginalUntilLastAliasDeletionAndUndo() throws {
        let (root, directory, item) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(directory: directory)
        try store.add(item)
        let second = try LibraryStore(directory: directory)
        var alias = ClipItem(kind: .file, text: "reference to managed original")
        alias.fileURLs = item.fileURLs
        try second.add(alias)
        let board = try second.createBoard(name: "Pinned alias")
        try second.pin([alias.id], to: board.id)
        try store.eraseHistory()
        let survivor = try XCTUnwrap(store.items.first(where: { $0.id == alias.id }))
        XCTAssertEqual(survivor.pinboardID, board.id)
        XCTAssertEqual(try Data(contentsOf: FileAssets.resolve(try store.materialized(survivor), directory: directory)), item.data)
        try store.delete([alias.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: URL(string: item.fileURLs[0])!.path))
        try store.undo()
        let restored = try store.materialized(XCTUnwrap(store.items.first))
        XCTAssertEqual(try Data(contentsOf: FileAssets.resolve(restored, directory: directory)), item.data)
    }

    @MainActor func testMultiFileAliasUndoRestoresManagedBytesAndPreservesExternalOriginal() throws {
        let (root, directory, first) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(directory: directory)
        let second = try FileAssets.importFile(from: root.appendingPathComponent("source.txt"), name: "second.txt", type: "public.plain-text", directory: directory)
        try store.add(first); try store.add(second)
        var alias = ClipItem(kind: .file)
        alias.fileURLs = first.fileURLs + second.fileURLs + [root.appendingPathComponent("source.txt").absoluteString]
        try store.add(alias)
        let board = try store.createBoard(name: "Multiple files")
        try store.pin([alias.id], to: board.id)
        try store.eraseHistory()
        try store.deleteBoard(board.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: URL(string: first.fileURLs[0])!.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: URL(string: second.fileURLs[0])!.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("source.txt").path))
        try store.undo()
        let restored = try store.materialized(XCTUnwrap(store.items.first))
        let urls = try FileAssets.resolvedURLs(for: restored, directory: directory)
        XCTAssertEqual(urls.count, 3)
        for url in urls { XCTAssertEqual(try Data(contentsOf: url), Data("saved attachment".utf8)) }
    }

    @MainActor func testAliasUndoFailureRemovesOnlyNewlyReconstructedCopiesAndRetainsRetry() throws {
        let (root, directory, item) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(directory: directory)
        try store.add(item)
        let second = try FileAssets.importFile(from: root.appendingPathComponent("source.txt"), name: "second.txt", type: "public.plain-text", directory: directory)
        try store.add(second)
        var alias = ClipItem(kind: .file); alias.fileURLs = item.fileURLs + second.fileURLs
        try store.add(alias)
        let board = try store.createBoard(name: "Keep")
        try store.pin([alias.id], to: board.id)
        try store.eraseHistory()
        try store.delete([alias.id])
        let url = try XCTUnwrap(URL(string: item.fileURLs[0]))
        let secondURL = try XCTUnwrap(URL(string: second.fileURLs[0]))
        store.writePermissionCheck = { _ in false }
        XCTAssertThrowsError(try store.undo())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondURL.path))
        store.writePermissionCheck = nil
        store.persistenceSaveCheck = { throw CocoaError(.fileWriteOutOfSpace) }
        XCTAssertThrowsError(try store.undo())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondURL.path))
        let reopened = try LibraryStore(directory: directory)
        XCTAssertTrue(reopened.items.isEmpty)
        store.persistenceSaveCheck = nil
        try store.undo()
        XCTAssertEqual(try Data(contentsOf: url), item.data)
        XCTAssertEqual(try Data(contentsOf: secondURL), second.data)
    }

    @MainActor func testAliasUndoPreservesNewerManagedContentsAndExternalLookalikePaths() throws {
        let (root, directory, item) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(directory: directory)
        try store.add(item)
        var alias = ClipItem(kind: .file); alias.fileURLs = item.fileURLs
        try store.add(alias)
        try store.delete([item.id], undoable: false)
        try store.delete([alias.id])
        var newer = item; newer.data = Data("newer bytes".utf8)
        let url = try FileAssets.resolve(newer, directory: directory)
        try store.add(newer)
        try store.undo()
        XCTAssertEqual(try Data(contentsOf: url), newer.data)
        let outside = root.appendingPathComponent("outside/Files/" + item.id.uuidString + "/report.txt")
        try FileManager.default.createDirectory(at: outside.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("external original".utf8).write(to: outside)
        var external = ClipItem(kind: .file); external.fileURLs = [outside.absoluteString]
        try store.add(external); try store.delete([external.id])
        XCTAssertEqual(try Data(contentsOf: outside), Data("external original".utf8))
    }

    @MainActor func testCleanupRetryRecognizesDifferentSharedOnlyAliasIdentity() throws {
        let (root, directory, item) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(directory: directory)
        try store.add(item)
        store.managedFileRemoval = { _ in throw CocoaError(.fileWriteNoPermission) }
        XCTAssertThrowsError(try store.delete([item.id]))
        let writer = try LibraryStore(directory: directory)
        var alias = ClipItem(kind: .file); alias.fileURLs = item.fileURLs
        try writer.add(alias)
        let board = try writer.createBoard(name: "Shared alias")
        try writer.pin([alias.id], to: board.id)
        let request = NSFetchRequest<NSManagedObject>(entityName: "ClipRecord")
        request.predicate = NSPredicate(format: "id == %@", alias.id.uuidString)
        for object in try writer.context.fetch(request) { writer.context.delete(object) }
        try writer.context.save()
        store.managedFileRemoval = nil
        try store.retryManagedFileCleanup()
        XCTAssertEqual(try Data(contentsOf: URL(string: item.fileURLs[0])!), item.data)
        try store.deleteBoard(board.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: URL(string: item.fileURLs[0])!.path))
        try store.undo()
        XCTAssertEqual(try Data(contentsOf: URL(string: item.fileURLs[0])!), item.data)
    }

    #if os(macOS)
    @MainActor func testBookmarkAliasPreservesItsManagedOriginalAndUndoBytes() throws {
        let (root, directory, item) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(directory: directory)
        try store.add(item)
        let url = try XCTUnwrap(URL(string: item.fileURLs[0]))
        var alias = ClipItem(kind: .file)
        alias.fileURLs = [root.appendingPathComponent("old-name.txt").absoluteString]
        alias.fileBookmarks = [try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)]
        try store.add(alias)
        let board = try store.createBoard(name: "Bookmark")
        try store.pin([alias.id], to: board.id)
        try store.eraseHistory()
        XCTAssertEqual(try Data(contentsOf: url), item.data)
        try store.delete([alias.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        try store.undo()
        XCTAssertEqual(try Data(contentsOf: url), item.data)
    }
    #endif

    @MainActor func testRetentionPreservesPinnedAliasThenErasureRemovesLastUnpinnedAlias() throws {
        let (root, directory, item) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(directory: directory)
        var expired = item; expired.createdAt = Date(timeIntervalSince1970: 1)
        try store.add(expired)
        var alias = ClipItem(kind: .file); alias.fileURLs = item.fileURLs
        try store.add(alias)
        let board = try store.createBoard(name: "Keep alias")
        try store.pin([alias.id], to: board.id)
        try store.applyRetention()
        XCTAssertEqual(store.items.map(\.id), [alias.id])
        XCTAssertEqual(try Data(contentsOf: FileAssets.resolve(alias, directory: directory)), item.data)
        try store.pin([alias.id], to: nil)
        try store.eraseHistory()
        XCTAssertFalse(FileManager.default.fileExists(atPath: URL(string: item.fileURLs[0])!.path))
        try store.undo()
        XCTAssertTrue(store.items.isEmpty)
    }

}
