import XCTest
import CoreData
@testable import StashCore

final class UndoRegressionTests: XCTestCase {
    @MainActor func testUndoMovePreservesLaterBoardMetadata() throws {
        let store = try LibraryStore(inMemory: true)
        var board = try store.createBoard(name: "Before", colorHex: "111111")
        let item = ClipItem(kind: .text, text: "saved")
        try store.add(item)
        try store.pin([item.id], to: board.id)
        try store.pin([item.id], to: nil)
        board.name = "Renamed later"
        board.colorHex = "ABCDEF"
        try store.updateBoard(board)

        try store.undo()

        XCTAssertEqual(store.items.first?.pinboardID, board.id)
        XCTAssertEqual(store.pinboards.first?.name, "Renamed later")
        XCTAssertEqual(store.pinboards.first?.colorHex, "ABCDEF")
    }

    @MainActor func testUndoMovePreservesLaterContentAndRestoresHistoryAndOrder() throws {
        let store = try LibraryStore(inMemory: true)
        let board = try store.createBoard(name: "Saved")
        var item = ClipItem(kind: .richText, text: "before")
        item.pinboardID = board.id
        item.isInHistory = false
        item.order = 4.25
        item.data = Data([1])
        item.richData = Data([2])
        try store.importArchive(LibraryArchive(items: [item], pinboards: [board], settings: store.settings).encode())
        try store.pin([item.id], to: nil)
        var edited = try store.materialized(XCTUnwrap(store.items.first))
        edited.title = "A later title"
        edited.text = "A later edit"
        edited.data = Data([8, 9])
        edited.richData = nil
        edited.thumbnail = Data([6])
        try store.update(edited, replacingAssets: true)

        try store.undo()

        let restored = try store.materialized(XCTUnwrap(store.items.first))
        XCTAssertEqual(restored.pinboardID, board.id)
        XCTAssertFalse(restored.isInHistory)
        XCTAssertEqual(restored.order, 4.25)
        XCTAssertEqual(restored.title, "A later title")
        XCTAssertEqual(restored.text, "A later edit")
        XCTAssertEqual(restored.data, Data([8, 9]))
        XCTAssertNil(restored.richData)
        XCTAssertEqual(restored.thumbnail, Data([6]))
    }

    @MainActor func testUndoDeletedItemKeepsSurvivingBoardMetadata() throws {
        let store = try LibraryStore(inMemory: true)
        var board = try store.createBoard(name: "Before")
        var item = ClipItem(kind: .image, text: "deleted content")
        item.data = Data([3, 4, 5])
        item.richData = Data([9])
        try store.add(item)
        try store.pin([item.id], to: board.id)
        try store.delete([item.id])
        board.name = "Renamed after deletion"
        board.colorHex = "123456"
        try store.updateBoard(board)

        try store.undo()

        let restored = try store.materialized(XCTUnwrap(store.items.first))
        XCTAssertEqual(restored.text, "deleted content")
        XCTAssertEqual(restored.data, Data([3, 4, 5]))
        XCTAssertEqual(restored.richData, Data([9]))
        XCTAssertEqual(restored.pinboardID, board.id)
        XCTAssertEqual(store.pinboards.first?.name, "Renamed after deletion")
        XCTAssertEqual(store.pinboards.first?.colorHex, "123456")
    }

    @MainActor func testUndoDeletedBoardRecreatesAbsentBoardAndAttachment() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt")
        try Data("saved attachment".utf8).write(to: source)
        let directory = root.appendingPathComponent("library")
        let store = try LibraryStore(directory: directory, inMemory: true)
        let board = try store.createBoard(name: "Deleted board", colorHex: "010203")
        let item = try FileAssets.importFile(from: source, name: "notes.txt", type: "public.plain-text", directory: directory)
        try store.add(item)
        try store.pin([item.id], to: board.id)
        try store.deleteBoard(board.id)
        // Model the deletion-time cleanup that #6 adds without relying on the old file.
        let managed = try XCTUnwrap(item.fileURLs.first.flatMap(URL.init(string:)))
        try FileManager.default.removeItem(at: managed)

        try store.undo()

        XCTAssertEqual(store.pinboards, [board])
        let restored = try store.materialized(XCTUnwrap(store.items.first))
        XCTAssertEqual(restored.pinboardID, board.id)
        let resolved = try FileAssets.resolve(restored, directory: directory)
        XCTAssertEqual(try Data(contentsOf: resolved), Data("saved attachment".utf8))
    }

    @MainActor func testUndoDeletedBoardPreservesARecreatedBoardsNewMetadata() throws {
        let store = try LibraryStore(inMemory: true)
        var board = try store.createBoard(name: "Original")
        let item = ClipItem(kind: .text, text: "restore me")
        try store.add(item)
        try store.pin([item.id], to: board.id)
        try store.deleteBoard(board.id)
        board.name = "Recreated by another writer"
        board.colorHex = "EEEEEE"
        try store.importArchive(LibraryArchive(items: [], pinboards: [board], settings: store.settings).encode())

        try store.undo()

        XCTAssertEqual(store.pinboards, [board])
        XCTAssertEqual(store.items.first?.text, "restore me")
        XCTAssertEqual(store.items.first?.pinboardID, board.id)
    }

    @MainActor func testUndoMoveRecoversPrivateHistoryWhenOriginalBoardDisappears() throws {
        let store = try LibraryStore(inMemory: true)
        let original = try store.createBoard(name: "Removed remotely")
        let destination = try store.createBoard(name: "Current board")
        let item = ClipItem(kind: .text, text: "keep original private content")
        try store.add(item)
        try store.pin([item.id], to: original.id)
        try store.pin([item.id], to: destination.id)
        let removed = try XCTUnwrap(store.boardObject(original.id))
        store.context.delete(removed)
        try store.context.save()
        try store.reload()

        try store.undo()

        XCTAssertNil(store.items.first?.pinboardID)
        XCTAssertEqual(store.items.first?.text, "keep original private content")
        XCTAssertTrue(store.items.first?.isInHistory == true)
        XCTAssertEqual(Set(store.pinboards.map(\.id)), [destination.id])
        XCTAssertEqual(try store.sharedGraphItemIDs(destination.id), [])
        XCTAssertNil(try store.boardObject(original.id))
    }

    @MainActor func testFailedUndoRollsBackAllItemsAndCanRetryItsRecoveryEntry() throws {
        let store = try LibraryStore(inMemory: true)
        let original = try store.createBoard(name: "Original")
        let destination = try store.createBoard(name: "Destination")
        let first = ClipItem(kind: .text, text: "first")
        let second = ClipItem(kind: .text, text: "second")
        try store.add(first)
        try store.add(second)
        let ids = [first.id, second.id]
        try store.pin(ids, to: original.id)
        try store.pin(ids, to: destination.id)
        let deniedID = try XCTUnwrap(store.items.last?.id).uuidString
        store.writePermissionCheck = { object in
            object.entity.name != "SharedClipRecord" || object.value(forKey: "id") as? String != deniedID
        }

        XCTAssertThrowsError(try store.undo()) { error in
            guard case LibraryStore.StoreError.readOnly = error else { return XCTFail("Expected read-only failure") }
        }
        try store.reload()
        XCTAssertEqual(Set(store.items.compactMap(\.pinboardID)), [destination.id])
        XCTAssertEqual(Set(try store.sharedGraphItemIDs(destination.id)), Set(ids))
        XCTAssertEqual(try store.sharedGraphItemIDs(original.id), [])
        store.writePermissionCheck = nil

        try store.undo()

        XCTAssertEqual(Set(store.items.compactMap(\.pinboardID)), [original.id])
        XCTAssertEqual(Set(try store.sharedGraphItemIDs(original.id)), Set(ids))
    }

    @MainActor func testFailedDeletionUndoKeepsBytesForRetry() throws {
        let store = try LibraryStore(inMemory: true)
        let board = try store.createBoard(name: "Board")
        var item = ClipItem(kind: .image, text: "recover")
        item.data = Data([2, 4, 6])
        try store.add(item)
        try store.pin([item.id], to: board.id)
        try store.delete([item.id])
        store.writePermissionCheck = { _ in false }
        XCTAssertThrowsError(try store.undo())
        XCTAssertTrue(store.items.isEmpty)
        store.writePermissionCheck = nil

        try store.undo()

        let restored = try store.materialized(XCTUnwrap(store.items.first))
        XCTAssertEqual(restored.data, Data([2, 4, 6]))
        XCTAssertEqual(restored.pinboardID, board.id)
    }

    @MainActor func testUndoDoesNotReplaceAnItemRecoveredByAnotherWriter() throws {
        let store = try LibraryStore(inMemory: true)
        var item = ClipItem(kind: .text, text: "deleted version")
        try store.add(item)
        try store.delete([item.id])
        item.text = "later recovered version"
        try store.add(item)

        try store.undo()

        XCTAssertEqual(store.items.first?.text, "later recovered version")
    }

    @MainActor func testUndoRestoresAnEmptyDeliberatelyDeletedBoard() throws {
        let store = try LibraryStore(inMemory: true)
        let board = try store.createBoard(name: "Empty")
        try store.deleteBoard(board.id)
        try store.undo()
        XCTAssertEqual(store.pinboards, [board])
    }

    @MainActor func testErasureClearsDeletionRecovery() throws {
        let store = try LibraryStore(inMemory: true)
        let item = ClipItem(kind: .text, text: "deleted")
        try store.add(item)
        try store.delete([item.id])
        try store.eraseHistory()
        try store.undo()
        XCTAssertTrue(store.items.isEmpty)
    }

    @MainActor func testDeletionRecoveryRemainsBoundedToTenOperations() throws {
        let store = try LibraryStore(inMemory: true)
        let items = (0..<11).map { ClipItem(kind: .text, text: "fixture \($0)") }
        for item in items { try store.add(item) }
        for item in items { try store.delete([item.id]) }
        for _ in 0..<11 { try store.undo() }
        XCTAssertEqual(Set(store.items.map(\.id)), Set(items.dropFirst().map(\.id)))
    }

    @MainActor func testFailedMoveDoesNotDisplaceThePreviousUndoOperation() throws {
        let store = try LibraryStore(inMemory: true)
        let original = try store.createBoard(name: "Original")
        let denied = try store.createBoard(name: "Denied")
        let item = ClipItem(kind: .text, text: "saved")
        try store.add(item)
        try store.pin([item.id], to: original.id)
        store.writePermissionCheck = { object in object.value(forKey: "id") as? String != denied.id.uuidString }
        XCTAssertThrowsError(try store.pin([item.id], to: denied.id))
        store.writePermissionCheck = nil

        try store.undo()

        XCTAssertNil(store.items.first?.pinboardID)
        XCTAssertEqual(try store.sharedGraphItemIDs(original.id), [])
    }

    @MainActor func testUndoDeletedAcceptedSharedBoardRecoversOnlyThePrivateOriginal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(directory: root)
        let board = Pinboard(name: "Accepted shared board")
        // Simulate a received shared graph in the separate shared persistent store.
        let sharedStore = try XCTUnwrap(store.container.persistentStoreCoordinator.persistentStores.first {
            $0.url?.lastPathComponent == "Shared.sqlite"
        })
        let record = NSEntityDescription.insertNewObject(forEntityName: "BoardRecord", into: store.context)
        record.setValue(board.id.uuidString, forKey: "id")
        record.setValue(try JSONEncoder().encode(board), forKey: "payload")
        store.context.assign(record, to: sharedStore)
        try store.context.save()
        try store.reload()
        let item = ClipItem(kind: .text, text: "private original")
        try store.add(item)
        try store.pin([item.id], to: board.id)
        try store.deleteBoard(board.id)

        try store.undo()

        XCTAssertTrue(store.pinboards.isEmpty)
        XCTAssertEqual(store.items.first?.text, "private original")
        XCTAssertNil(store.items.first?.pinboardID)
        XCTAssertTrue(store.items.first?.isInHistory == true)
        XCTAssertNil(try store.boardObject(board.id))
    }
}
