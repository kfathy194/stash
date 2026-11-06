import XCTest
@testable import StashCore

final class PinboardCreationTests: XCTestCase {
    @MainActor func testReadOnlyAndMissingDestinationsCannotCreateOrOfferCreation() throws {
        let store = try LibraryStore(inMemory: true)
        let board = try store.createBoard(name: "Generated board")
        store.writePermissionCheck = { $0.entity.name != "BoardRecord" }
        XCTAssertFalse(store.boardIsWritable(board.id))
        XCTAssertThrowsError(try store.add(ClipItem(kind: .text, text: "Denied"), to: board.id))
        XCTAssertTrue(store.items.isEmpty)
        store.writePermissionCheck = nil
        try store.deleteBoard(board.id)
        XCTAssertFalse(store.boardIsWritable(board.id))
        XCTAssertThrowsError(try store.add(ClipItem(kind: .text, text: "Missing"), to: board.id))
        XCTAssertTrue(store.items.isEmpty)
    }

    @MainActor func testFailedSaveAndRetryDoNotLeakOrDuplicateContent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(directory: root)
        let board = try store.createBoard(name: "Generated board")
        let item = ClipItem(kind: .text, text: "Retry fixture")
        store.persistenceSaveCheck = { throw NSError(domain: "Generated disk failure", code: 1) }
        XCTAssertThrowsError(try store.add(item, to: board.id))
        let reopened = try LibraryStore(directory: root)
        XCTAssertTrue(reopened.items.isEmpty)
        store.persistenceSaveCheck = nil
        try store.add(item, to: board.id)
        XCTAssertThrowsError(try store.add(item, to: board.id))
        XCTAssertEqual(store.results(boardID: board.id).map(\.id), [item.id])
        XCTAssertTrue(store.results().isEmpty)
        let privateItem = ClipItem(kind: .text, text: "Existing private content")
        try store.add(privateItem)
        XCTAssertThrowsError(try store.add(privateItem, to: board.id))
        XCTAssertEqual(store.results().map(\.id), [privateItem.id])
    }

    @MainActor func testCreationRechecksDeletionFromAnotherLibraryInstance() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(directory: root)
        let board = try store.createBoard(name: "Generated board")
        let other = try LibraryStore(directory: root)
        try other.deleteBoard(board.id)
        XCTAssertThrowsError(try store.add(ClipItem(kind: .text, text: "Stale destination"), to: board.id))
        XCTAssertTrue(store.items.isEmpty)
    }

    @MainActor func testDirectCreationStaysInPinboardAcrossReopenWithoutHistoryCopy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(directory: root)
        let board = try store.createBoard(name: "Generated board")
        let secret = ClipItem(kind: .text, text: "Unrelated History fixture")
        try store.add(secret)
        let item = ClipItem(kind: .text, text: "\tPinboard source  \n")
        try store.add(item, to: board.id)
        let reopened = try LibraryStore(directory: root)
        XCTAssertEqual(reopened.results(boardID: board.id).map(\.id), [item.id])
        XCTAssertEqual(reopened.results().map(\.id), [secret.id])
        XCTAssertFalse(try XCTUnwrap(reopened.items.first { $0.id == item.id }).isInHistory)
        XCTAssertEqual(try reopened.sharedGraphItemIDs(board.id), [item.id])
        try reopened.deleteBoard(board.id)
        XCTAssertEqual(reopened.items.map(\.id), [secret.id], "No private copy may reappear as History")
    }
}
