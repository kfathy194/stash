import XCTest
@testable import StashCore

final class StoreTests: XCTestCase {
    @MainActor func testLocalModePreservesSyncPreferenceAndAllowsLocalWrites() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let boardID: UUID
        let item = ClipItem(kind: .text, text: "local fixture")
        do {
            let first = try LibraryStore(directory: folder)
            boardID = try first.createBoard(name: "Local").id
            try first.add(item)
            var preferences = first.settings
            preferences.syncEnabled = true
            try first.updateSettings(preferences)
        }
        let store = try LibraryStore(directory: folder, syncEnabled: false)
        XCTAssertTrue(store.settings.syncEnabled, "Preserve the owner's preference for a capable build")
        XCTAssertEqual(store.syncStatus, "On this device")
        XCTAssertTrue(store.boardIsWritable(boardID))
        try store.pin([item.id], to: boardID)
        var updated = try XCTUnwrap(store.items.first)
        updated.text = "edited locally"
        try store.update(updated)
        XCTAssertEqual(store.items.first?.text, "edited locally")
        XCTAssertEqual(store.items.first?.pinboardID, boardID)
        XCTAssertTrue(store.settings.syncEnabled)
        let reopened = try LibraryStore(directory: folder, syncEnabled: false)
        XCTAssertTrue(reopened.settings.syncEnabled)
        XCTAssertEqual(reopened.items.first?.text, "edited locally")
    }

    @MainActor func testPinMovesErasePreservesAndBoardDeletionRemoves() throws {
        let store = try LibraryStore(inMemory: true)
        let first = try store.createBoard(name: "Work"), second = try store.createBoard(name: "Personal")
        let item = ClipItem(kind: .text, text: "private note")
        try store.add(item); try store.pin([item.id], to: first.id); try store.pin([item.id], to: second.id)
        XCTAssertEqual(store.items.first?.pinboardID, second.id)
        try store.eraseHistory()
        XCTAssertEqual(store.items.count, 1); XCTAssertFalse(store.items[0].isInHistory)
        try store.deleteBoard(second.id)
        XCTAssertTrue(store.items.isEmpty)
    }
    @MainActor func testPersistenceAndArchiveImportMerge() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try LibraryStore(directory: folder)
        var item = ClipItem(kind: .image, text: "image"); item.data = Data([1,2,3])
        try store.add(item)
        let backup = try store.archive()
        let other = try LibraryStore(inMemory: true)
        try other.importArchive(backup); try other.importArchive(backup)
        XCTAssertEqual(other.items.count, 1)
        XCTAssertEqual(try other.materialized(other.items[0]).data, item.data)
        let reopened = try LibraryStore(directory: folder)
        XCTAssertEqual(reopened.items.first?.id, item.id)
    }
    @MainActor func testSharedGraphContainsNoHistoryRelationships() throws {
        let store = try LibraryStore(inMemory: true)
        let board = try store.createBoard(name: "Shared work")
        try store.add(ClipItem(kind: .text, text: "secret"))
        let chosen = ClipItem(kind: .text, text: "chosen"); try store.add(chosen); try store.pin([chosen.id], to: board.id)
        XCTAssertEqual(try store.sharedGraphItemIDs(board.id), [chosen.id])
    }
    @MainActor func testUndoPinRestoresUnpinnedState() throws {
        let store = try LibraryStore(inMemory:true)
        let board = try store.createBoard(name:"Undo")
        let item = ClipItem(kind:.text,text:"keep")
        try store.add(item); try store.pin([item.id],to:board.id); try store.undo()
        XCTAssertNil(store.items.first?.pinboardID)
        XCTAssertEqual(try store.sharedGraphItemIDs(board.id),[])
    }
    @MainActor func testUnpinExpiredPinnedItemReturnsItToHistory() throws {
        let store = try LibraryStore(inMemory:true)
        let board = try store.createBoard(name:"Pinned")
        let item = ClipItem(kind:.text,text:"old",createdAt:.now.addingTimeInterval(-100*86400))
        try store.add(item); try store.pin([item.id],to:board.id); try store.applyRetention()
        try store.pin([item.id],to:nil)
        XCTAssertTrue(store.items.first?.isInHistory == true)
    }

}
