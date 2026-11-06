import AppKit
import XCTest
@testable import StashCore
@testable import StashMac

@MainActor final class CodeEditorTests: XCTestCase {
    func testNativeWordCopyPasteAndDeletionPreserveCodeWhitespace() throws {
        _ = NSApplication.shared
        let store = try LibraryStore(inMemory: true)
        let model = AppModel(store: store)
        let source = try EditorWindow(item: ClipItem(kind: .text, text: "a color b"), model: model, isNew: true)
        let target = try EditorWindow(item: ClipItem(kind: .code, text: "foobar"), model: model, isNew: true)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        source.textView.setSelectedRange(NSRange(location: 2, length: 5))
        source.textView.selectionGranularity = .selectByWord
        XCTAssertTrue(source.textView.writeSelection(to: pasteboard, types: source.textView.writablePasteboardTypes))
        XCTAssertEqual(pasteboard.string(forType: .string), "color")
        target.textView.setSelectedRange(NSRange(location: 3, length: 0))
        XCTAssertTrue(target.textView.readSelection(from: pasteboard, type: .string))
        XCTAssertEqual(target.textView.string, "foocolorbar")
        target.textView.undoManager?.undo()
        XCTAssertEqual(target.textView.string, "foobar")

        target.textView.string = "alpha beta gamma"
        target.textView.setSelectedRange(NSRange(location: 6, length: 4))
        target.textView.selectionGranularity = .selectByWord
        target.textView.delete(nil)
        XCTAssertEqual(target.textView.string, "alpha  gamma")
        target.textView.undoManager?.undo()
        XCTAssertEqual(target.textView.string, "alpha beta gamma")

        target.formatPopup.selectItem(withTitle: "Plain Text")
        target.changeFormat()
        target.textView.string = "foobar"
        target.textView.setSelectedRange(NSRange(location: 3, length: 0))
        XCTAssertTrue(target.textView.readSelection(from: pasteboard, type: .string))
        XCTAssertEqual(target.textView.string, "foo color bar", "Plain Text retains native prose spacing")
        target.formatPopup.selectItem(withTitle: "CSS")
        target.changeFormat()
        target.textView.string = "foobar"
        target.textView.setSelectedRange(NSRange(location: 3, length: 0))
        XCTAssertTrue(target.textView.readSelection(from: pasteboard, type: .string))
        XCTAssertEqual(target.textView.string, "foocolorbar", "Switching back to Code restores literal insertion")
    }

    func testCodePresentationHighlightsEveryLanguageWithoutEditingSourceOrUndo() throws {
        _ = NSApplication.shared
        let store = try LibraryStore(inMemory: true)
        let model = AppModel(store: store)
        let examples = [
            ("css", ".note { color: red; }\n"), ("html", "<div>café</div>\n"),
            ("php", "<?php echo 'hi';\n"), ("javascript", "const value = 2;\n"),
            ("typescript", "interface Note {}\n"), ("json", "true\n"),
            ("markdown", "# Note\n"), ("sql", "SELECT name FROM notes;\n"),
            ("python", "def note():\n    return 2\n"), ("swift", "let note = 2\n"),
            ("bash", "if true; then echo hi; fi\n"), ("yaml", "name: note\n"),
            ("xml", "<note>hi</note>\n")
        ]
        for (language, source) in examples {
            var item = ClipItem(kind: .code, text: source)
            item.codeLanguage = language
            try store.add(item)
            let editor = try EditorWindow(item: item, model: model, isNew: false)
            let firstToken = try XCTUnwrap(editor.textView.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: 0, effectiveRange: nil) as? NSColor)
            XCTAssertNotEqual(firstToken, .textColor, language)
            XCTAssertNotNil(editor.textView.enclosingScrollView?.verticalRulerView, language)
            XCTAssertEqual(editor.textView.string, source)
            XCTAssertFalse(editor.hasUnsavedChanges, language)
            XCTAssertFalse(editor.textView.undoManager?.canUndo ?? true, language)
            editor.save()
            let saved = try XCTUnwrap(store.items.first(where: { $0.id == item.id }))
            XCTAssertEqual(saved.text, source)
            XCTAssertNil(try store.materialized(saved).richData)
        }
    }

    func testCodeIndentationAndOutdentAreNativeUndoableTextEdits() throws {
        _ = NSApplication.shared
        let store = try LibraryStore(inMemory: true)
        let model = AppModel(store: store)
        var item = ClipItem(kind: .code, text: "let café = 1\r\nlet b = 2\r\n")
        item.codeLanguage = "swift"
        let editor = try EditorWindow(item: item, model: model, isNew: true)
        editor.textView.setSelectedRange(NSRange(location: 0, length: (item.text as NSString).length))
        editor.textView.insertTab(nil)
        XCTAssertEqual(editor.textView.string, "\tlet café = 1\r\n\tlet b = 2\r\n")
        editor.textView.undoManager?.undo()
        XCTAssertEqual(editor.textView.string, "let café = 1\r\nlet b = 2\r\n")
        editor.textView.setSelectedRange(NSRange(location: 0, length: (item.text as NSString).length))
        editor.textView.insertTab(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        editor.textView.insertBacktab(nil)
        XCTAssertEqual(editor.textView.string, "let café = 1\r\nlet b = 2\r\n")
        editor.textView.undoManager?.undo()
        XCTAssertEqual(editor.textView.string, "\tlet café = 1\r\n\tlet b = 2\r\n")
    }

    func testLineNumbersFollowLogicalLinesAndNativeEditsWithoutLosingUnicodeOrSource() throws {
        _ = NSApplication.shared
        let store = try LibraryStore(inMemory: true)
        let model = AppModel(store: store)
        var item = ClipItem(kind: .code, text: "\tlet café = \"😀\"\n\n")
        item.codeLanguage = "swift"
        let editor = try EditorWindow(item: item, model: model, isNew: true)
        let ruler = try XCTUnwrap(editor.textView.enclosingScrollView?.verticalRulerView)
        XCTAssertEqual(ruler.accessibilityValue() as? String, "1\n2\n3")
        XCTAssertTrue(editor.textView.font?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)
        editor.window.setContentSize(NSSize(width: 460, height: 600))
        editor.window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(editor.textView.string, "\tlet café = \"😀\"\n\n")
        XCTAssertFalse(editor.hasUnsavedChanges)
        editor.textView.setSelectedRange(NSRange(location: 1, length: 0))
        editor.textView.insertNewline(nil)
        XCTAssertEqual(editor.textView.string, "\t\n\tlet café = \"😀\"\n\n")
        XCTAssertEqual(ruler.accessibilityValue() as? String, "1\n2\n3\n4")
        editor.textView.undoManager?.undo()
        XCTAssertEqual(editor.textView.string, "\tlet café = \"😀\"\n\n")
        XCTAssertEqual(ruler.accessibilityValue() as? String, "1\n2\n3")
        editor.textView.setSelectedRange(NSRange(location: 1, length: 0))
        editor.textView.insertBacktab(nil)
        XCTAssertEqual(editor.textView.string, "let café = \"😀\"\n\n")
    }

    func testTypingAndHighlightingKeepLiteralStringsAndUndoSourceOnly() throws {
        _ = NSApplication.shared
        let store = try LibraryStore(inMemory: true)
        let model = AppModel(store: store)
        var item = ClipItem(kind: .code)
        item.codeLanguage = "javascript"
        let editor = try EditorWindow(item: item, model: model, isNew: true)
        editor.textView.insertText("const café = \"// literal -- 😀\"; // comment\n", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(editor.textView.string, "const café = \"// literal -- 😀\"; // comment\n")
        let source = editor.textView.string as NSString
        let quoted = source.range(of: "// literal")
        let comment = source.range(of: "// comment")
        let quotedColor = try XCTUnwrap(editor.textView.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: quoted.location, effectiveRange: nil) as? NSColor)
        let commentColor = try XCTUnwrap(editor.textView.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: comment.location, effectiveRange: nil) as? NSColor)
        XCTAssertNotEqual(quotedColor, commentColor)
        editor.textView.undoManager?.undo()
        XCTAssertEqual(editor.textView.string, "")
        XCTAssertFalse(editor.hasUnsavedChanges)
        editor.textView.undoManager?.redo()
        XCTAssertEqual(editor.textView.string, "const café = \"// literal -- 😀\"; // comment\n")
        editor.save()
        let saved = try XCTUnwrap(store.items.first)
        XCTAssertEqual(PasteService.textPasteboardItem(for: saved).string(forType: .string), "const café = \"// literal -- 😀\"; // comment\n")
        XCTAssertNil(try store.materialized(saved).richData)
    }

    private func contrastRatio(_ color: NSColor, over background: NSColor) -> Double {
        func luminance(_ color: NSColor) -> Double {
            let alpha = color.alphaComponent
            let values = [(color.redComponent, background.redComponent), (color.greenComponent, background.greenComponent), (color.blueComponent, background.blueComponent)].map { foreground, back in
                let value = Double(foreground * alpha + back * (1 - alpha))
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return values[0] * 0.2126 + values[1] * 0.7152 + values[2] * 0.0722
        }
        let front = luminance(color), back = luminance(background)
        return (max(front, back) + 0.05) / (min(front, back) + 0.05)
    }

    func testSyntaxColorsRemainReadableInNativeLightAndDarkAppearances() throws {
        _ = NSApplication.shared
        let store = try LibraryStore(inMemory: true)
        var item = ClipItem(kind: .code, text: "const $note = \"source\"; // comment\n2")
        item.codeLanguage = "javascript"
        let editor = try EditorWindow(item: item, model: AppModel(store: store), isNew: true)
        for name in [NSAppearance.Name.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            appearance.performAsCurrentDrawingAppearance {
                guard let background = NSColor.textBackgroundColor.usingColorSpace(.deviceRGB) else { return XCTFail("Missing native background") }
                for token in ["const", "$note", "\"source\"", "// comment", "2"] {
                    let range = (item.text as NSString).range(of: token)
                    guard let dynamic = editor.textView.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: range.location, effectiveRange: nil) as? NSColor,
                          let color = dynamic.usingColorSpace(.deviceRGB) else { return XCTFail("Missing token color") }
                    let contrast = contrastRatio(color, over: background)
                    XCTAssertGreaterThanOrEqual(contrast, 4.5, "\(name.rawValue): \(token)")
                }
            }
        }
    }

    func testEditorControlsAndCodeDocumentHaveVisibleLayout() throws {
        _ = NSApplication.shared
        let store = try LibraryStore(inMemory: true)
        var item = ClipItem(kind: .code, text: "let visible = true\n")
        item.codeLanguage = "swift"
        let editor = try EditorWindow(item: item, model: AppModel(store: store), isNew: true)
        editor.window.makeKeyAndOrderFront(nil)
        defer { editor.window.close() }
        editor.window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertGreaterThan(editor.titleField.frame.height, 16)
        XCTAssertGreaterThan(editor.formatPopup.frame.height, 16)
        XCTAssertGreaterThan(editor.textView.frame.width, 100)
        XCTAssertGreaterThan(editor.textView.frame.height, 100)
        let layout = try XCTUnwrap(editor.textView.layoutManager)
        let container = try XCTUnwrap(editor.textView.textContainer)
        layout.ensureLayout(for: container)
        XCTAssertGreaterThan(layout.numberOfGlyphs, 10)
        XCTAssertGreaterThan(layout.usedRect(for: container).width, 100)
        XCTAssertGreaterThan(layout.glyphRange(forBoundingRect: editor.textView.visibleRect, in: container).length, 10)
    }

    func testRulerDrawingCannotPaintOverSurroundingEditorControls() throws {
        _ = NSApplication.shared
        let store = try LibraryStore(inMemory: true)
        let editor = try EditorWindow(item: ClipItem(kind: .code, text: "let note = true\n"), model: AppModel(store: store), isNew: true)
        let ruler = try XCTUnwrap(editor.textView.enclosingScrollView?.verticalRulerView)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 400, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.magenta.setFill()
        NSRect(x: 0, y: 0, width: 100, height: 400).fill()
        ruler.drawHashMarksAndLabels(in: NSRect(x: -1000, y: -1000, width: 2000, height: 2000))
        NSGraphicsContext.restoreGraphicsState()
        let outside = try XCTUnwrap(bitmap.colorAt(x: 80, y: 20)?.usingColorSpace(.deviceRGB))
        XCTAssertEqual(outside.redComponent, 1, accuracy: 0.01)
        XCTAssertEqual(outside.greenComponent, 0, accuracy: 0.01)
        XCTAssertEqual(outside.blueComponent, 1, accuracy: 0.01)
    }

    func testUnterminatedCommentIsHighlightedWithoutRescanningEveryOpeningDelimiter() throws {
        _ = NSApplication.shared
        let store = try LibraryStore(inMemory: true)
        let model = AppModel(store: store)
        for size in [3_000, 15_000, 30_000] {
            let source = String(repeating: "/* ", count: size / 3)
            var item = ClipItem(kind: .code, text: source)
            item.codeLanguage = "css"
            let start = Date()
            let editor = try EditorWindow(item: item, model: model, isNew: true)
            let elapsed = Date().timeIntervalSince(start)
            print("Generated malformed CSS: \(size) bytes in \(elapsed) seconds")
            XCTAssertLessThan(elapsed, 2, "A small malformed snippet must not block the editor for seconds")
            let first = try XCTUnwrap(editor.textView.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: 0, effectiveRange: nil) as? NSColor)
            let last = try XCTUnwrap(editor.textView.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: size - 1, effectiveRange: nil) as? NSColor)
            XCTAssertEqual(first, last)
            XCTAssertNotEqual(first, .textColor)
            XCTAssertEqual(editor.textView.string, source)
            XCTAssertFalse(editor.hasUnsavedChanges)
            XCTAssertTrue(editor.windowShouldClose(editor.window))
        }
    }

    func testCodeBaseTextRemainsReadableAfterBlackAttributedInputInKnownAndUnknownModes() throws {
        _ = NSApplication.shared
        let store = try LibraryStore(inMemory: true)
        let model = AppModel(store: store)
        for language in ["html", nil, "future-language"] as [String?] {
            var item = ClipItem(kind: .code)
            item.codeLanguage = language
            let editor = try EditorWindow(item: item, model: model, isNew: true)
            editor.textView.textColor = .black
            editor.textView.insertText("Unmatched café source", replacementRange: NSRange(location: 0, length: 0))
            let dynamic = try XCTUnwrap(editor.textView.layoutManager?.temporaryAttribute(.foregroundColor, atCharacterIndex: 0, effectiveRange: nil) as? NSColor)
            for name in [NSAppearance.Name.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua] {
                let appearance = try XCTUnwrap(NSAppearance(named: name))
                appearance.performAsCurrentDrawingAppearance {
                    guard let color = dynamic.usingColorSpace(.deviceRGB),
                          let background = NSColor.textBackgroundColor.usingColorSpace(.deviceRGB) else { return XCTFail("Missing native text color") }
                    XCTAssertGreaterThanOrEqual(contrastRatio(color, over: background), 4.5, name.rawValue)
                }
            }
            editor.textView.undoManager?.undo()
            XCTAssertFalse(editor.hasUnsavedChanges)
            editor.textView.undoManager?.redo()
            editor.save()
            let saved = try XCTUnwrap(store.items.first(where: { $0.id == item.id }))
            XCTAssertEqual(saved.text, "Unmatched café source")
            XCTAssertEqual(saved.codeLanguage, language)
            XCTAssertNil(try store.materialized(saved).richData)
        }
    }

    func testMalformedCommentsStringsAndIdentifiersRemainBoundedAndKeepSource() throws {
        _ = NSApplication.shared
        let store = try LibraryStore(inMemory: true)
        let model = AppModel(store: store)
        var cases = [
            ("css", String(repeating: "identifier", count: 3_000)),
            ("html", String(repeating: "identifier", count: 3_000)),
            ("markdown", String(repeating: "[label](", count: 4_000)),
            ("markdown", String(repeating: "[", count: 30_000)),
            ("markdown", "`" + String(repeating: "source ", count: 4_000)),
            ("python", "\"\"\"" + String(repeating: "source ", count: 4_000)),
            ("swift", "\"\"\"" + String(repeating: "source ", count: 4_000))
        ]
        cases += ["css", "javascript", "typescript", "php", "sql", "swift"].map { ($0, String(repeating: "/* ", count: 10_000)) }
        cases += ["html", "xml", "markdown"].map { ($0, String(repeating: "<!-- ", count: 6_000)) }
        cases += CodeLanguage.allCases.map { ($0.rawValue, "\"" + String(repeating: "\\\"source ", count: 3_000) + "\\") }
        for (language, source) in cases {
            var item = ClipItem(kind: .code, text: source)
            item.codeLanguage = language
            let start = Date()
            let editor = try EditorWindow(item: item, model: model, isNew: true)
            XCTAssertLessThan(Date().timeIntervalSince(start), 2, language)
            XCTAssertEqual(editor.textView.string, source)
            XCTAssertFalse(editor.hasUnsavedChanges, language)
            editor.save()
            let saved = try XCTUnwrap(store.items.first(where: { $0.id == item.id }))
            XCTAssertEqual(saved.text, source)
            XCTAssertNil(try store.materialized(saved).richData)
        }
    }

    func testEveryAgreedLanguageCanBeSelectedAndSaved() throws {
        _ = NSApplication.shared
        let store = try LibraryStore(inMemory: true)
        let model = AppModel(store: store)
        let languages = [("CSS", "css"), ("HTML", "html"), ("PHP", "php"), ("JavaScript", "javascript"), ("TypeScript", "typescript"), ("JSON", "json"), ("Markdown", "markdown"), ("SQL", "sql"), ("Python", "python"), ("Swift", "swift"), ("Bash", "bash"), ("YAML", "yaml"), ("XML", "xml")]
        for (label, language) in languages {
            let item = ClipItem(kind: .text, text: "\tExact café -- 'source'  \r\n")
            let editor = try EditorWindow(item: item, model: model, isNew: true)
            editor.formatPopup.selectItem(withTitle: label)
            editor.changeFormat()
            XCTAssertFalse(editor.textView.isAutomaticQuoteSubstitutionEnabled)
            XCTAssertFalse(editor.textView.isAutomaticDashSubstitutionEnabled)
            editor.save()
            let saved = try XCTUnwrap(store.items.first(where: { $0.id == item.id }))
            XCTAssertEqual(saved.codeLanguage, language)
            XCTAssertEqual(saved.kind, .code)
            XCTAssertEqual(saved.text, "\tExact café -- 'source'  \r\n")
        }
    }

    func testUnknownAndUnspecifiedLanguagesRemainCodeWhenSaved() throws {
        _ = NSApplication.shared
        let store = try LibraryStore(inMemory: true)
        let model = AppModel(store: store)
        for language in [nil, "future-language"] as [String?] {
            var item = ClipItem(kind: .code, text: "\tlegacy source  \n")
            item.codeLanguage = language
            try store.add(item)
            let editor = try EditorWindow(item: item, model: model, isNew: false)
            XCTAssertFalse(editor.hasUnsavedChanges)
            editor.save()
            let saved = try XCTUnwrap(store.items.first(where: { $0.id == item.id }))
            XCTAssertEqual(saved.codeLanguage, language)
            XCTAssertEqual(saved.kind, .code)
            XCTAssertEqual(saved.text, "\tlegacy source  \n")
        }
    }

    func testChangingCodeLanguagesPreservesSourceAndUndoRestoresLanguage() throws {
        _ = NSApplication.shared
        let store = try LibraryStore(inMemory: true)
        var item = ClipItem(kind: .code, text: "\t<div>café</div>  \r\n")
        item.codeLanguage = "html"
        try store.add(item)
        let model = AppModel(store: store)
        let editor = try EditorWindow(item: item, model: model, isNew: false)
        editor.textView.setSelectedRange(NSRange(location: 2, length: 5))
        editor.formatPopup.selectItem(withTitle: "PHP")
        editor.changeFormat()
        XCTAssertTrue(editor.hasUnsavedChanges)
        XCTAssertEqual(editor.textView.selectedRange(), NSRange(location: 2, length: 5))
        XCTAssertEqual(editor.textView.string, "\t<div>café</div>  \r\n")
        editor.textView.undoManager?.undo()
        XCTAssertEqual(editor.formatPopup.titleOfSelectedItem, "HTML")
        XCTAssertEqual(editor.selectedLanguage, "html")
        editor.save()
        XCTAssertEqual(store.items.first?.codeLanguage, "html")
        XCTAssertEqual(store.items.first?.text, "\t<div>café</div>  \r\n")
    }

    func testRichToCodeConfirmationAndUndoPreserveFormatting() throws {
        _ = NSApplication.shared
        let store = try LibraryStore(inMemory: true)
        let styled = NSAttributedString(string: "\t<div>café</div>  \n", attributes: [.font: NSFont.boldSystemFont(ofSize: 19)])
        var item = ClipItem(kind: .richText, text: styled.string)
        item.richData = try styled.data(from: NSRange(location: 0, length: styled.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        try store.add(item)
        let model = AppModel(store: store)
        let declined = try EditorWindow(item: item, model: model, isNew: false, confirm: { _ in false })
        let before = NSAttributedString(attributedString: declined.textView.attributedString())
        declined.formatPopup.selectItem(withTitle: "HTML")
        declined.changeFormat()
        XCTAssertEqual(declined.selectedKind, .richText)
        XCTAssertEqual(declined.textView.attributedString(), before)
        let accepted = try EditorWindow(item: item, model: model, isNew: false, confirm: { _ in true })
        accepted.formatPopup.selectItem(withTitle: "HTML")
        accepted.changeFormat()
        XCTAssertEqual(accepted.selectedKind, .code)
        accepted.textView.undoManager?.undo()
        XCTAssertEqual(accepted.selectedKind, .richText)
        XCTAssertEqual(accepted.textView.attributedString(), before)
        accepted.formatPopup.selectItem(withTitle: "HTML")
        accepted.changeFormat()
        accepted.save()
        let saved = try XCTUnwrap(store.items.first)
        XCTAssertEqual(saved.codeLanguage, "html")
        XCTAssertEqual(saved.text, "\t<div>café</div>  \n")
        XCTAssertNil(try store.materialized(saved).richData)
    }

    func testCopyRepresentationUsesExactSourceAndExcludesObsoleteCodeRTF() throws {
        var item = ClipItem(kind: .code, text: "\t<div>café</div>  \r\n")
        item.richData = Data("obsolete rich text".utf8)
        let writer = PasteService.textPasteboardItem(for: item)
        XCTAssertEqual(writer.string(forType: .string), "\t<div>café</div>  \r\n")
        XCTAssertNil(writer.data(forType: .rtf))
        item.kind = .richText
        XCTAssertEqual(PasteService.textPasteboardItem(for: item).data(forType: .rtf), Data("obsolete rich text".utf8))
    }

    func testSelectedLanguageSavesLiteralSourceAndReopensWithTheSameFormat() throws {
        _ = NSApplication.shared
        let store = try LibraryStore(inMemory: true)
        let model = AppModel(store: store)
        let editor = try EditorWindow(item: ClipItem(kind: .text), model: model, isNew: true)
        editor.textView.string = "\t.café { content: '<div>'; }  \r\n"
        _ = try XCTUnwrap(editor.formatPopup.item(withTitle: "CSS"))
        editor.formatPopup.selectItem(withTitle: "CSS")
        editor.changeFormat()
        editor.save()
        let saved = try XCTUnwrap(store.items.first)
        XCTAssertEqual(saved.kind, .code)
        XCTAssertEqual(saved.codeLanguage, "css")
        XCTAssertEqual(saved.text, "\t.café { content: '<div>'; }  \r\n")
        XCTAssertNil(try store.materialized(saved).richData)
        let reopened = try EditorWindow(item: saved, model: model, isNew: false)
        XCTAssertEqual(reopened.formatPopup.titleOfSelectedItem, "CSS")
    }
}
