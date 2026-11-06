import AppKit
import XCTest
@testable import StashCore
@testable import StashMac

@MainActor final class PinboardEditorTests: XCTestCase {
    func testNewTextCapturesPinboardThenSaveIgnoresTabChanges() throws {
        _ = NSApplication.shared
        let store = try LibraryStore(inMemory: true)
        let first = try store.createBoard(name: "First")
        let second = try store.createBoard(name: "Second")
        let model = AppModel(store: store)
        model.currentBoard = first.id
        model.newText()
        let editor = try XCTUnwrap(EditorWindow.editors.last)
        defer { editor.window.close() }
        editor.textView.string = "\tGenerated Pinboard note  \n"
        model.currentBoard = second.id
        editor.save()
        XCTAssertEqual(store.results(boardID: first.id).first?.text, "\tGenerated Pinboard note  \n")
        XCTAssertTrue(store.results(boardID: second.id).isEmpty)
        XCTAssertTrue(store.results().isEmpty)
    }

    func testProductionCommandNEntryRespectsReadOnlyAndSearchFocus() throws {
        _ = NSApplication.shared
        let store = try LibraryStore(inMemory: true)
        let board = try store.createBoard(name: "First")
        let model = AppModel(store: store)
        model.currentBoard = board.id
        model.searchFocused = true
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil, characters: "n", charactersIgnoringModifiers: "n", isARepeat: false, keyCode: 45))
        XCTAssertTrue(PanelController.handleNewTextShortcut(event, model: model))
        let editor = try XCTUnwrap(EditorWindow.editors.last)
        editor.window.close()
        store.writePermissionCheck = { $0.entity.name != "BoardRecord" }
        let before = EditorWindow.editors.count
        XCTAssertTrue(PanelController.handleNewTextShortcut(event, model: model))
        XCTAssertEqual(EditorWindow.editors.count, before)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertNotNil(model.toast)
    }

    func testLostDestinationOrWriteAccessKeepsDraftAndCanRetryWithoutHistoryLeak() throws {
        _ = NSApplication.shared
        let store = try LibraryStore(inMemory: true)
        let board = try store.createBoard(name: "First")
        let model = AppModel(store: store)
        model.currentBoard = board.id
        model.newText()
        let editor = try XCTUnwrap(EditorWindow.editors.last)
        defer { editor.window.close() }
        editor.textView.string = "Recoverable generated draft"
        store.writePermissionCheck = { $0.entity.name != "BoardRecord" }
        editor.save()
        XCTAssertEqual(editor.textView.string, "Recoverable generated draft")
        XCTAssertFalse(editor.errorLabel.isHidden)
        XCTAssertTrue(editor.window.isVisible)
        XCTAssertTrue(store.items.isEmpty)
        store.writePermissionCheck = nil
        editor.save()
        XCTAssertEqual(store.results(boardID: board.id).count, 1)
        XCTAssertTrue(store.results().isEmpty)

        model.newText()
        let deleted = try XCTUnwrap(EditorWindow.editors.last)
        defer { deleted.window.close() }
        deleted.textView.string = "Destination deleted"
        try store.deleteBoard(board.id)
        deleted.save()
        XCTAssertTrue(deleted.window.isVisible)
        XCTAssertEqual(deleted.textView.string, "Destination deleted")
        XCTAssertFalse(deleted.errorLabel.isHidden)
        XCTAssertTrue(store.items.isEmpty)
    }
}
