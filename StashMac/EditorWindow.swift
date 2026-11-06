import AppKit
import StashCore

@MainActor final class EditorWindow: NSObject, NSTextViewDelegate, NSTextFieldDelegate, NSWindowDelegate {
    enum Confirmation { case discardChanges, removeFormatting }
    static var editors: [EditorWindow] = []
    let window: NSWindow
    let textView = CodeTextView()
    let titleField = NSTextField(string: "")
    let formatPopup = NSPopUpButton()
    let errorLabel = NSTextField(wrappingLabelWithString: "")
    private(set) var selectedKind: ClipKind
    private(set) var selectedLanguage: String?
    private struct Format: Equatable {
        let kind: ClipKind
        var language: String?
        var label: String {
            if kind == .code { return language.map { CodeLanguage(rawValue: $0)?.label ?? "Code (\($0))" } ?? "Code (unspecified)" }
            return kind == .text ? "Plain Text" : kind.label
        }
    }
    private let formats: [Format]
    private let store: LibraryStore
    private let item: ClipItem
    private let isNew: Bool
    private let destinationBoardID: UUID?
    private let confirm: @MainActor (Confirmation) -> Bool
    private let draftUndo = UndoManager()
    private var initialContent = NSAttributedString(string: "")
    private var didSave = false
    private var lineRuler: CodeLineRuler?

    var hasUnsavedChanges: Bool {
        !didSave && (titleField.stringValue != (item.title ?? "") || selectedKind != item.kind || selectedLanguage != item.codeLanguage || (selectedKind == .richText ? !textView.attributedString().isEqual(to: initialContent) : textView.string != initialContent.string))
    }

    init(item: ClipItem, model: AppModel, isNew: Bool, destinationBoardID: UUID? = nil, confirm: @escaping @MainActor (Confirmation) -> Bool = EditorWindow.confirmChange) throws {
        self.item = item
        self.store = model.store
        self.isNew = isNew
        self.destinationBoardID = destinationBoardID
        self.confirm = confirm
        selectedKind = item.kind
        selectedLanguage = item.codeLanguage
        var choices = [Format(kind: .text), Format(kind: .richText)] + CodeLanguage.allCases.map { Format(kind: .code, language: $0.rawValue) }
        let existing = Format(kind: item.kind, language: item.codeLanguage)
        if !choices.contains(existing) { choices.append(existing) }
        formats = choices
        let full = try model.store.materialized(item)
        let content: NSAttributedString
        if item.kind == .richText, let rich = full.richData {
            content = try NSAttributedString(data: rich, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        } else {
            content = NSAttributedString(string: item.text, attributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.textColor])
        }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 450), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = isNew ? "New text" : item.displayTitle
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 440, height: 450)
        let root = NSView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        window.contentView = root
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16)
        ])
        titleField.placeholderString = "Title (optional)"
        titleField.stringValue = item.title ?? ""
        titleField.setAccessibilityLabel("Title (optional)")
        titleField.delegate = self
        stack.addArrangedSubview(titleField)
        let formatRow = NSStackView()
        formatRow.addArrangedSubview(NSTextField(labelWithString: "Format"))
        formatPopup.addItems(withTitles: formats.map(\.label))
        formatPopup.selectItem(at: formats.firstIndex(of: existing) ?? 0)
        formatPopup.target = self
        formatPopup.action = #selector(changeFormat)
        formatPopup.setAccessibilityLabel("Item format")
        formatRow.addArrangedSubview(formatPopup)
        stack.addArrangedSubview(formatRow)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        textView.isRichText = selectedKind == .richText
        textView.allowsUndo = true
        textView.delegate = self
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.font = .systemFont(ofSize: 16)
        textView.setAccessibilityLabel("Item content")
        configureTextEditing()
        textView.textStorage?.setAttributedString(content)
        scroll.documentView = textView
        lineRuler = CodeLineRuler(scroll: scroll, text: textView)
        scroll.verticalRulerView = lineRuler
        refreshCodePresentation()
        stack.addArrangedSubview(scroll)
        let save = NSButton(title: "Save", target: self, action: #selector(save))
        save.bezelStyle = .rounded
        save.keyEquivalent = "s"
        let buttons = NSStackView()
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        buttons.addArrangedSubview(cancel)
        buttons.addArrangedSubview(save)
        errorLabel.textColor = .systemRed
        errorLabel.setAccessibilityLabel("Save error")
        errorLabel.isHidden = true
        stack.addArrangedSubview(errorLabel)
        stack.addArrangedSubview(buttons)
        NSLayoutConstraint.activate([
            titleField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            errorLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180)
        ])
        initialContent = NSAttributedString(attributedString: textView.attributedString())
        draftUndo.removeAllActions()
        window.initialFirstResponder = textView
    }

    static func open(item: ClipItem, model: AppModel, isNew: Bool = false, destinationBoardID: UUID? = nil) {
        model.perform {
            let editor = try EditorWindow(item: item, model: model, isNew: isNew, destinationBoardID: destinationBoardID)
            editors.append(editor)
            NSApp.activate(ignoringOtherApps: true)
            editor.window.center()
            editor.window.makeKeyAndOrderFront(nil)
        }
    }

    func undoManager(for view: NSTextView) -> UndoManager? { draftUndo }

    @objc func changeFormat() {
        guard formats.indices.contains(formatPopup.indexOfSelectedItem) else { return }
        let requested = formats[formatPopup.indexOfSelectedItem]
        let current = Format(kind: selectedKind, language: selectedLanguage)
        guard requested != current else { return }
        if selectedKind == .richText && !confirm(.removeFormatting) {
            formatPopup.selectItem(at: formats.firstIndex(of: current) ?? 0)
            return
        }
        let plain = NSAttributedString(string: textView.string, attributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.textColor])
        restoreContent(plain, format: requested)
    }

    private func restoreContent(_ content: NSAttributedString, format: Format) {
        let selection = textView.selectedRanges
        let previous = NSAttributedString(attributedString: textView.attributedString())
        let previousFormat = Format(kind: selectedKind, language: selectedLanguage)
        draftUndo.beginUndoGrouping()
        draftUndo.registerUndo(withTarget: self) { editor in editor.restoreContent(previous, format: previousFormat) }
        draftUndo.setActionName("Change item format")
        draftUndo.endUndoGrouping()
        selectedKind = format.kind
        selectedLanguage = format.language
        textView.isRichText = selectedKind == .richText
        configureTextEditing()
        textView.textStorage?.setAttributedString(content)
        refreshCodePresentation()
        textView.selectedRanges = selection
        formatPopup.selectItem(at: formats.firstIndex(of: format) ?? 0)
        window.isDocumentEdited = hasUnsavedChanges
    }

    private func configureTextEditing() {
        let code = selectedKind == .code
        textView.codeEditing = code
        textView.smartInsertDeleteEnabled = !code
        textView.isAutomaticQuoteSubstitutionEnabled = !code
        textView.isAutomaticDashSubstitutionEnabled = !code
        textView.isAutomaticTextReplacementEnabled = !code
        textView.isAutomaticSpellingCorrectionEnabled = !code
        if #available(macOS 26, *) { textView.writingToolsBehavior = code ? .none : .complete }
    }

    private func refreshCodePresentation() {
        textView.enclosingScrollView?.hasVerticalRuler = selectedKind == .code
        textView.enclosingScrollView?.rulersVisible = selectedKind == .code
        let codeFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        if selectedKind == .code && textView.font != codeFont { textView.font = codeFont }
        lineRuler?.refresh()
        CodePresentation.apply(to: textView, language: selectedLanguage, isCode: selectedKind == .code)
    }

    @objc func save() {
        guard !didSave else { return }
        do {
            var edited = item
            if !isNew {
                try store.reload()
                guard let current = store.items.first(where: { $0.id == item.id }) else { throw LibraryStore.StoreError.unavailable }
                edited = try store.materialized(current)
            }
            edited.title = titleField.stringValue.isEmpty ? nil : titleField.stringValue
            edited.text = textView.string
            edited.kind = selectedKind
            edited.codeLanguage = selectedKind == .code ? selectedLanguage : nil
            if selectedKind == .richText {
                guard let rich = textView.rtf(from: NSRange(location: 0, length: textView.string.utf16.count)) else { throw CocoaError(.fileWriteInapplicableStringEncoding) }
                edited.richData = rich
            } else { edited.richData = nil }
            if isNew, let destinationBoardID { try store.add(edited, to: destinationBoardID) }
            else if isNew { try store.add(edited) }
            else { try store.update(edited, replacingAssets: true) }
            didSave = true
            window.isDocumentEdited = false
            errorLabel.stringValue = ""
            errorLabel.isHidden = true
            window.close()
        } catch {
            store.context.rollback()
            errorLabel.stringValue = "Could not save this item: \(error.localizedDescription) Your draft is still available; try saving again."
            errorLabel.isHidden = false
        }
    }

    @objc func cancel() {
        if windowShouldClose(window) { window.close() }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { !hasUnsavedChanges || confirm(.discardChanges) }
    func windowWillClose(_ notification: Notification) { Self.editors.removeAll { $0 === self } }
    func textDidChange(_ notification: Notification) {
        refreshCodePresentation()
        window.isDocumentEdited = hasUnsavedChanges
    }
    func controlTextDidChange(_ notification: Notification) { window.isDocumentEdited = hasUnsavedChanges }

    private static func confirmChange(_ confirmation: Confirmation) -> Bool {
        let alert = NSAlert()
        switch confirmation {
        case .removeFormatting:
            alert.messageText = "Remove rich formatting?"
            alert.informativeText = "The text will be preserved. You can undo this change before saving."
            alert.addButton(withTitle: "Remove Formatting")
            alert.addButton(withTitle: "Cancel")
        case .discardChanges:
            alert.messageText = "Discard unsaved changes?"
            alert.informativeText = "Your changes will be lost. Choose Keep Editing to return to your draft."
            alert.addButton(withTitle: "Discard Changes")
            alert.addButton(withTitle: "Keep Editing")
        }
        return alert.runModal() == .alertFirstButtonReturn
    }
}
