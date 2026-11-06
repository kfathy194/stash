import AppKit
import Quartz
import WebKit
import Darwin

/// Native preview boundary, without app startup, capture, paste, hotkeys or permissions.
@MainActor @main struct PreviewSmoke {
    static var failures = 0
    static func check(_ condition: Bool, _ message: String) {
        print("\(condition ? "PASS" : "FAIL"): \(message)")
        if !condition { failures += 1 }
    }
    static func spin() { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    static func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    static func unavailable(_ window: NSWindow) -> Bool {
        views(window.contentView!).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Preview unavailable" }
    }
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        // Refuse to run if Foundation did not honor the disposable home.
        guard LibraryStore.defaultDirectory().standardizedFileURL.path.hasPrefix(root.path + "/") else {
            fatalError("Preview smoke requires an isolated application-support directory")
        }
        NSApplication.shared.setActivationPolicy(.accessory)
        let store = try LibraryStore(directory: root.appendingPathComponent("library"))
        let model = AppModel(store: store)
        let note = ClipItem(kind: .text, text: "generated preview note")
        try store.add(note)
        model.select(note)
        let snippet = ClipItem(kind: .code, text: "let preview = true")
        try store.add(snippet)
        let board = try store.createBoard(name: "Preview board", colorHex: "30B7A8")
        try store.pin([snippet.id], to: board.id)
        var rich = ClipItem(kind: .richText, text: "generated rich body")
        rich.richData = NSAttributedString(string: rich.text).rtf(from: NSRange(location: 0, length: rich.text.utf16.count))
        try store.add(rich)
        let folder = root.appendingPathComponent("Generated folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = folder.appendingPathComponent("original.txt")
        try Data("original bytes".utf8).write(to: original)
        let fifo = root.appendingPathComponent("Generated FIFO")
        guard mkfifo(fifo.path, 0o600) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var pipe = ClipItem(kind: .file, text: "Generated FIFO")
        pipe.fileURLs = [fifo.absoluteString]
        try store.add(pipe)
        let alias = root.appendingPathComponent("Generated symlink.txt")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: original)
        var symlink = ClipItem(kind: .file, text: "Generated symlink")
        symlink.fileURLs = [alias.absoluteString]
        try store.add(symlink)
        var directory = ClipItem(kind: .file, text: "Generated folder")
        directory.fileURLs = [folder.absoluteString]
        // A disposable bookmark exercises resolution without manufacturing consent.
        directory.fileBookmarks = [try folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)]
        try store.add(directory)
        var saved = ClipItem(kind: .file, text: "Saved attachment")
        saved.fileName = "saved.txt"; saved.fileURLs = [original.absoluteString]
        saved.data = Data("retained attachment".utf8); saved.byteCount = saved.data!.count
        try store.add(saved)
        var missing = ClipItem(kind: .file, text: "Missing original")
        missing.fileURLs = [root.appendingPathComponent("absent.txt").absoluteString]
        try store.add(missing)
        let emptyImage = ClipItem(kind: .image)
        try store.add(emptyImage)
        var image = ClipItem(kind: .image)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        image.data = bitmap.representation(using: .png, properties: [:]); image.byteCount = image.data!.count
        try store.add(image)
        let refused = ClipItem(kind: .link, text: "http://127.0.0.1:1/")
        let unsupported = ClipItem(kind: .link, text: "ftp://example.invalid/file")
        try store.add(refused); try store.add(unsupported)
        let before = try store.items.map { try store.materialized($0) }
        let selection = model.selection
        func open(_ item: ClipItem) -> NSWindow {
            let existing = Set(NSApplication.shared.windows)
            PreviewWindow.open(item: store.items.first { $0.id == item.id }!, model: model)
            spin()
            return NSApplication.shared.windows.first { !existing.contains($0) && $0.title == item.displayTitle && $0.isVisible }!
        }
        func text(_ window: NSWindow) -> NSTextView? { views(window.contentView!).compactMap { $0 as? NSTextView }.first }
        let noteWindow = open(note)
        check(noteWindow.isVisible && text(noteWindow)?.string == note.text, "History text is visible and readable")
        let noteText = text(noteWindow)!
        noteText.layoutManager?.ensureLayout(for: noteText.textContainer!)
        check(noteText.visibleRect.width > 0 && noteText.visibleRect.height > 0 && (noteText.layoutManager?.numberOfGlyphs ?? 0) > 0, "Text lays out within a visible scroll area")
        let codeWindow = open(snippet)
        check(text(codeWindow)?.string == snippet.text, "Unselected Pinboard item shows its own code")
        check(text(open(rich))?.string == rich.text, "Retained rich text is readable")
        check(unavailable(open(pipe)), "FIFO reference displays an explanation without waiting for a writer")
        check(open(symlink).contentView is QLPreviewView, "A symlink to a regular file still gets a native preview")
        let folderWindow = open(directory)
        check(folderWindow.contentView is QLPreviewView, "Readable folder gets a native Quick Look preview")
        let savedWindow = open(saved)
        let preview = savedWindow.contentView as? QLPreviewView
        let savedURL = preview?.previewItem as? NSURL
        check(savedURL.flatMap { try? Data(contentsOf: $0 as URL) } == saved.data, "Saved attachment serves retained bytes")
        check((try Data(contentsOf: original)) == Data("original bytes".utf8), "Preview preserves the external original")
        check(unavailable(open(missing)), "Missing reference displays an explanation")
        check(unavailable(open(emptyImage)), "Missing image bytes display an explanation")
        check((open(image).contentView as? NSImageView)?.image != nil, "Retained image bytes display an image")
        let refusedWindow = open(refused)
        for _ in 0..<80 { if unavailable(refusedWindow) { break }; spin() }
        check(unavailable(refusedWindow), "WebKit navigation failure displays an explanation")
        let unsupportedWindow = open(unsupported)
        for _ in 0..<80 { if unavailable(unsupportedWindow) { break }; spin() }
        check(unavailable(unsupportedWindow), "Unsupported link scheme displays an explanation")
        let visible = NSApplication.shared.windows.filter(\.isVisible).count
        var released = true
        for _ in 0..<5 {
            weak var closed: NSWindow?
            autoreleasepool { let window = open(directory); closed = window; window.performClose(nil) }
            spin()
            released = released && closed == nil
        }
        check(released && NSApplication.shared.windows.filter(\.isVisible).count == visible, "Close/reopen releases closed windows and keeps existing previews visible")
        for window in NSApplication.shared.windows where window.isVisible { window.performClose(nil) }
        spin()
        check(NSApplication.shared.windows.allSatisfy { !$0.isVisible }, "Closing all previews leaves no visible window")
        check(text(open(note))?.string == note.text, "Preview reopens after every window closes")
        check(model.selection == selection, "Preview leaves the previous selection intact")
        let after = try store.items.map { try store.materialized($0) }
        check(before == after, "Preview preserves generated library records and representations")
        for window in NSApplication.shared.windows where window.isVisible { window.performClose(nil) }
        print("Preview smoke: \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
