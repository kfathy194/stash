import XCTest
@testable import StashCore

// Observable settings/retention behavior for #65's custom whole-day period, through
// the public LibraryStore seam. The Settings editor's own input validation is private
// Mac UI logic; its rejection messages are covered by the documented native journey.
final class RetentionSettingsTests: XCTestCase {
    @MainActor func testCustomDaysPersistAcrossRestartThroughExistingSettings() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try LibraryStore(directory: folder)
        var settings = store.settings
        settings.retentionDays = 45
        try store.updateSettings(settings)
        XCTAssertEqual(store.settings.retentionDays, 45)
        XCTAssertEqual(try LibraryStore(directory: folder).settings.retentionDays, 45, "A custom period must still be shown after restarting, through the same persisted setting")
    }
    @MainActor func testCustomPeriodUsesTheSharedRetentionEntryPathAtFixedCutoff() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = try LibraryStore(directory: folder)
        var settings = store.settings
        settings.retentionDays = 45
        try store.updateSettings(settings)
        try store.add(ClipItem(kind: .text, text: "expired draft", createdAt: now.addingTimeInterval(-46 * 86400)))
        try store.add(ClipItem(kind: .text, text: "recent note", createdAt: now.addingTimeInterval(-10 * 86400)))
        let oldPinned = ClipItem(kind: .text, text: "old pinned", createdAt: now.addingTimeInterval(-400 * 86400))
        try store.add(oldPinned)
        let board = try store.createBoard(name: "Keep")
        try store.pin([oldPinned.id], to: board.id)
        try store.applyRetention(now: now)
        let survivors = Dictionary(uniqueKeysWithValues: store.items.map { ($0.text, $0) })
        XCTAssertFalse(survivors.keys.contains("expired draft"), "Unpinned history before the custom cutoff is deleted")
        XCTAssertEqual(survivors["recent note"]?.isInHistory, true, "History after the custom cutoff is kept")
        XCTAssertEqual(survivors["old pinned"]?.pinboardID, board.id, "Pinboard membership survives a custom period")
        XCTAssertFalse(survivors["old pinned"]?.isInHistory ?? true, "An expired pinned item leaves history but keeps its pinboard")
        XCTAssertTrue(store.pinboards.contains { $0.id == board.id })
    }
    @MainActor func testLibraryAcceptsLargeRepresentableCustomDayCountsWithoutACeiling() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = try LibraryStore(directory: folder)
        var settings = store.settings
        settings.retentionDays = 100_001
        try store.updateSettings(settings)
        try store.add(ClipItem(kind: .text, text: "older than the period", createdAt: now.addingTimeInterval(-100_002 * 86400)))
        try store.add(ClipItem(kind: .text, text: "within the period", createdAt: now.addingTimeInterval(-100_000 * 86400)))
        try store.applyRetention(now: now)
        let survivors = Dictionary(uniqueKeysWithValues: store.items.map { ($0.text, $0) })
        XCTAssertFalse(survivors.keys.contains("older than the period"))
        XCTAssertEqual(survivors["within the period"]?.isInHistory, true)
        XCTAssertEqual(try LibraryStore(directory: folder).settings.retentionDays, 100_001, "Any representable day count persists like a preset does")
        var largest = store.settings
        largest.retentionDays = Int.max
        try store.updateSettings(largest)
        try store.applyRetention(now: now)
        XCTAssertEqual(store.items.count, 1, "The largest representable day count is safely used by the existing retention calculation")
    }
    @MainActor func testFailedSettingsUpdateKeepsThePreviousRetentionPolicyActive() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = try LibraryStore(directory: folder)
        var settings = store.settings
        settings.retentionDays = 365
        try store.updateSettings(settings)
        try store.add(ClipItem(kind: .text, text: "older than 30 days", createdAt: now.addingTimeInterval(-40 * 86400)))
        store.persistenceSaveCheck = { throw CocoaError(.fileWriteOutOfSpace) }
        var shortened = store.settings
        shortened.retentionDays = 30
        XCTAssertThrowsError(try store.updateSettings(shortened))
        store.persistenceSaveCheck = nil
        XCTAssertEqual(store.settings.retentionDays, 365, "A failed settings update must leave the previous period active")
        XCTAssertEqual(try LibraryStore(directory: folder).settings.retentionDays, 365, "The failed period must not persist")
        try store.applyRetention(now: now)
        XCTAssertEqual(store.items.count, 1, "Retention cleanup must not treat a period whose save failed as active")
    }
    @MainActor func testCustomPeriodRetentionCleansManagedAttachmentsAndKeepsExternalOriginal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt")
        try Data("saved attachment".utf8).write(to: source)
        let directory = root.appendingPathComponent("library")
        var item = try FileAssets.importFile(from: source, name: "note.txt", type: "public.plain-text", directory: directory)
        item.createdAt = Date(timeIntervalSince1970: 1)
        let store = try LibraryStore(directory: directory)
        try store.add(item)
        var settings = store.settings
        settings.retentionDays = 45
        try store.updateSettings(settings)
        try store.applyRetention(now: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try FileAssets.managedFolder(for: item.id, directory: directory).path), "Managed cleanup safeguards apply to a custom period")
        XCTAssertEqual(try Data(contentsOf: source), Data("saved attachment".utf8), "External originals are never retention targets")
    }
}
