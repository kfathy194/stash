import AppKit
import XCTest
@testable import StashCore
@testable import StashMac

@MainActor final class EditorWindowTests: XCTestCase {
    func testNonRichTextRemainsReadableInDarkAppearance() throws {
        _ = NSApplication.shared
        let store = try LibraryStore(inMemory: true)
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        for kind in [ClipKind.text, .link, .color] {
            let editor = try EditorWindow(item: ClipItem(kind: kind, text: "VISIBLE SOURCE TEXT"), model: AppModel(store: store), isNew: true)
            editor.window.appearance = dark
            editor.window.contentView?.layoutSubtreeIfNeeded()
            let view = editor.textView
            view.layoutManager?.ensureLayout(for: try XCTUnwrap(view.textContainer))
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            dark.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
            var readablePixels = 0
            for y in 0..<min(bitmap.pixelsHigh, 65) {
                for x in 0..<min(bitmap.pixelsWide, 500) {
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                       min(color.redComponent, color.greenComponent, color.blueComponent) > 0.6 { readablePixels += 1 }
                }
            }
            XCTAssertGreaterThan(readablePixels, 20, "\(kind) must draw readable glyphs on the dark background")
            XCTAssertEqual(view.string, "VISIBLE SOURCE TEXT")
            XCTAssertFalse(editor.hasUnsavedChanges)
        }
    }

    func testNewPlainTextSavesOptionalTitleAndExactText() throws {
        _ = NSApplication.shared
        let store = try LibraryStore(inMemory: true)
        let model = AppModel(store: store)
        let editor = try EditorWindow(item: ClipItem(kind: .text), model: model, isNew: true)
        editor.titleField.stringValue = "Generated note"
        editor.textView.string = "\tPlain source  \n"
        editor.save()
        let saved = try XCTUnwrap(store.items.first)
        XCTAssertEqual(saved.title, "Generated note")
        XCTAssertEqual(saved.text, "\tPlain source  \n")
        XCTAssertEqual(saved.kind, .text)
        XCTAssertNil(try store.materialized(saved).richData)
    }

    func testSavingLegacyCodeKeepsItsKindAndExactSource() throws {
        _ = NSApplication.shared
        let store = try LibraryStore(inMemory: true)
        let item = ClipItem(kind: .code, text: "\tconst café = '<div>';  \n")
        try store.add(item)
        let model = AppModel(store: store)
        let editor = try EditorWindow(item: item, model: model, isNew: false)
        editor.save()
        let saved = try XCTUnwrap(store.items.first)
        XCTAssertEqual(saved.kind, .code)
        XCTAssertEqual(saved.text, "\tconst café = '<div>';  \n")
        XCTAssertNil(try store.materialized(saved).richData)
    }

    func testRichConversionCanBeDeclinedAcceptedAndUndoneBeforeSave() throws {
        _ = NSApplication.shared
        let store = try LibraryStore(inMemory: true)
        let styled = NSAttributedString(string: "Rich café\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 19)])
        var item = ClipItem(kind: .richText, text: styled.string)
        item.richData = try styled.data(from: NSRange(location: 0, length: styled.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        try store.add(item)
        let answer = ConfirmationAnswer()
        let model = AppModel(store: store)
        let editor = try EditorWindow(item: item, model: model, isNew: false, confirm: { _ in answer.accept })
        let before = NSAttributedString(attributedString: editor.textView.attributedString())
        editor.formatPopup.selectItem(at: 0)
        editor.changeFormat()
        XCTAssertEqual(editor.selectedKind, .richText)
        XCTAssertEqual(editor.textView.attributedString(), before)
        answer.accept = true
        editor.formatPopup.selectItem(at: 0)
        editor.changeFormat()
        XCTAssertEqual(editor.selectedKind, .text)
        XCTAssertEqual(editor.textView.string, "Rich café\n")
        editor.textView.undoManager?.undo()
        XCTAssertEqual(editor.selectedKind, .richText)
        XCTAssertEqual(editor.textView.attributedString(), before)
        editor.save()
        XCTAssertEqual(store.items.first?.kind, .richText)
        XCTAssertNotNil(try store.materialized(try XCTUnwrap(store.items.first)).richData)
    }

    func testCloseAndCancelProtectDirtyDraftAndNeverSaveDiscardedChanges() throws {
        _ = NSApplication.shared
        let store = try LibraryStore(inMemory: true)
        let item = ClipItem(kind: .text, text: "Original")
        try store.add(item)
        let model = AppModel(store: store)
        let editor = try EditorWindow(item: item, model: model, isNew: false, confirm: { _ in false })
        XCTAssertTrue(editor.windowShouldClose(editor.window))
        editor.titleField.stringValue = "Unsaved title"
        XCTAssertFalse(editor.windowShouldClose(editor.window))
        editor.cancel()
        XCTAssertTrue(editor.hasUnsavedChanges)
        XCTAssertNil(store.items.first?.title)
        let discard = try EditorWindow(item: item, model: model, isNew: false, confirm: { _ in true })
        discard.textView.string = "Discard this"
        XCTAssertTrue(discard.windowShouldClose(discard.window))
        discard.cancel()
        XCTAssertEqual(store.items.first?.text, "Original")
    }

    func testSaveFailureKeepsDraftAndExplainsFailureThenRetrySucceeds() throws {
        _ = NSApplication.shared
        let store = try LibraryStore(inMemory: true)
        let item = ClipItem(kind: .text, text: "Original")
        try store.add(item)
        let model = AppModel(store: store)
        let editor = try EditorWindow(item: item, model: model, isNew: false, confirm: { _ in false })
        editor.textView.string = "\tRecoverable draft  \n"
        editor.titleField.stringValue = "Recoverable title"
        store.persistenceSaveCheck = { throw NSError(domain: "Generated", code: 1, userInfo: [NSLocalizedDescriptionKey: "Generated disk failure"]) }
        editor.save()
        XCTAssertEqual(store.items.first?.text, "Original")
        XCTAssertEqual(editor.textView.string, "\tRecoverable draft  \n")
        XCTAssertEqual(editor.titleField.stringValue, "Recoverable title")
        XCTAssertTrue(editor.errorLabel.stringValue.contains("Generated disk failure"))
        XCTAssertFalse(editor.windowShouldClose(editor.window))
        store.persistenceSaveCheck = nil
        editor.save()
        XCTAssertEqual(store.items.first?.text, "\tRecoverable draft  \n")
        XCTAssertEqual(store.items.first?.title, "Recoverable title")
        XCTAssertFalse(editor.hasUnsavedChanges)
    }

    func testAcceptedPlainConversionClearsRichBytesAndPreservesCurrentLocation() throws {
        _ = NSApplication.shared
        let store = try LibraryStore(inMemory: true)
        let first = try store.createBoard(name: "First")
        let second = try store.createBoard(name: "Second")
        let styled = NSAttributedString(string: "\tExact café  \n", attributes: [.font: NSFont.boldSystemFont(ofSize: 19)])
        var item = ClipItem(kind: .richText, text: styled.string)
        item.richData = try styled.data(from: NSRange(location: 0, length: styled.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        try store.add(item)
        try store.pin([item.id], to: first.id)
        try store.eraseHistory()
        let model = AppModel(store: store)
        let editor = try EditorWindow(item: try XCTUnwrap(store.items.first), model: model, isNew: false, confirm: { _ in true })
        try store.pin([item.id], to: second.id)
        model.currentBoard = nil
        editor.formatPopup.selectItem(at: 0)
        editor.changeFormat()
        editor.save()
        let saved = try XCTUnwrap(store.items.first)
        XCTAssertEqual(saved.pinboardID, second.id)
        XCTAssertFalse(saved.isInHistory)
        XCTAssertEqual(saved.text, "\tExact café  \n")
        XCTAssertEqual(saved.kind, .text)
        XCTAssertNil(try store.materialized(saved).richData)
    }

    func testDeletedItemCannotSilentlyReportSaveSuccess() throws {
        _ = NSApplication.shared
        let store = try LibraryStore(inMemory: true)
        let item = ClipItem(kind: .text, text: "Original")
        try store.add(item)
        let model = AppModel(store: store)
        let editor = try EditorWindow(item: item, model: model, isNew: false, confirm: { _ in false })
        editor.textView.string = "Recoverable deleted item"
        try store.delete([item.id])
        editor.save()
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertFalse(editor.errorLabel.isHidden)
        XCTAssertTrue(editor.hasUnsavedChanges)
        XCTAssertEqual(editor.textView.string, "Recoverable deleted item")
    }
}

@MainActor private final class ConfirmationAnswer { var accept = false }
