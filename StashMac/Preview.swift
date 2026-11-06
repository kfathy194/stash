import SwiftUI
import AppKit
import WebKit
import Quartz
import StashCore

@MainActor enum PreviewWindow {
    static var windows: [NSWindow] = []
    static let closeWatcher = PreviewCloseWatcher()
    /// Per-window preview resources: security-scoped file access and link
    /// navigation feedback. Both are balanced when their window closes.
    static var resources: [NSWindow: PreviewResources] = [:]
    static func open(item: ClipItem, model: AppModel) {
        prune()
        var resolved = item
        let window = window(titled: resolved.displayTitle)
        do {
            resolved = try model.store.materialized(item)
            window.contentView = contentView(for: resolved, model: model, window: window)
        } catch {
            window.contentView = unavailableView(message: error.localizedDescription, hint: "Stash could not load the saved content of this item. It may be unavailable right now.")
            model.message("Preview unavailable: " + error.localizedDescription)
        }
        present(window)
        windows.append(window)
    }
    private static func prune() {
        for window in windows where !window.isVisible { resources.removeValue(forKey: window)?.release() }
        windows.removeAll { !$0.isVisible }
    }
    private static func window(titled name: String) -> NSWindow {
        let window = NSWindow(contentViewController: NSViewController())
        window.title = name; window.styleMask = [.titled, .closable, .resizable]; window.setContentSize(NSSize(width: 740, height: 530)); window.isReleasedWhenClosed = false; window.delegate = closeWatcher
        return window
    }
    private static func present(_ window: NSWindow) {
        window.center()
        // The Stash panel never activates Stash, so a preview requested from its
        // context menu or Space shortcut must bring the app forward itself;
        // otherwise the window opens behind the frontmost application and the
        // action looks broken. This mirrors EditorWindow.open.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
    private static func contentView(for full: ClipItem, model: AppModel, window: NSWindow) -> NSView {
        switch full.kind {
        case .link:
            if let url = URL(string: full.text.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme != nil {
                let web = WKWebView()
                let observer = LinkPreviewCoordinator(window: window, address: full.text)
                web.navigationDelegate = observer
                let entry = resources[window] ?? PreviewResources()
                entry.linkObserver = observer
                resources[window] = entry
                web.load(URLRequest(url: url))
                return web
            }
            return unavailableView(message: "This link does not contain a usable address.", hint: "The saved text was: \(full.text.prefix(200))")
        case .file:
            do {
                let url = try FileAssets.resolve(full, directory: LibraryStore.defaultDirectory())
                // FileAssets resolution balances its own inspection grant before
                // returning, so the preview owns a separate grant that stays
                // active for the whole window lifetime while Quick Look reads
                // the file asynchronously. It is balanced on close.
                let access = ScopedPreviewAccess(url: url)
                guard access.isReadable, let preview = QLPreviewView(frame: NSRect(x: 0, y: 0, width: 740, height: 530), style: .normal) else {
                    access.release()
                    throw CocoaError(.fileReadUnknown)
                }
                preview.previewItem = url as NSURL
                let entry = resources[window] ?? PreviewResources()
                entry.fileAccess = access
                resources[window] = entry
                return preview
            } catch {
                model.message("Preview unavailable: " + error.localizedDescription)
                return full.data != nil
                    ? unavailableView(message: "The saved copy of this file could not be prepared for preview.", hint: error.localizedDescription)
                    : unavailableView(message: "The original file this item references could not be opened.", hint: "It may have been moved, changed or deleted. " + error.localizedDescription)
            }
        case .image:
            if let data = full.data, let image = NSImage(data: data) { let view = NSImageView(); view.image = image; view.imageScaling = .scaleProportionallyUpOrDown; return view }
            model.message("Preview unavailable: image content could not be read.")
            return unavailableView(message: "The image content is unavailable.", hint: full.byteCount > 0 ? "Its saved image data exists but could not be read." : "No saved image data is stored for this item.")
        default: return textView(for: full)
        }
    }
    private static func textView(for full: ClipItem) -> NSView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true
        let text = NSTextView(); text.isEditable = false; text.isSelectable = true; text.textContainerInset = NSSize(width: 24, height: 24); text.autoresizingMask = [.width]; text.isVerticallyResizable = true
        text.font = full.kind == .code ? .monospacedSystemFont(ofSize: 14, weight: .regular) : .systemFont(ofSize: 16)
        if let rich = full.richData, let string = try? NSAttributedString(data: rich, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) { text.textStorage?.setAttributedString(string) } else { text.string = full.text }
        scroll.documentView = text
        return scroll
    }
    static func unavailableView(message: String, hint: String) -> NSView {
        let container = NSView(); container.identifier = NSUserInterfaceItemIdentifier("Stash.PreviewUnavailable")
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .centerX; stack.spacing = 10
        let icon = NSImageView(); icon.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Preview unavailable"); icon.contentTintColor = .secondaryLabelColor
        let title = NSTextField(labelWithString: "Preview unavailable"); title.font = .boldSystemFont(ofSize: 17)
        let body = NSTextField(wrappingLabelWithString: message); body.alignment = .center; body.preferredMaxLayoutWidth = 430
        let note = NSTextField(wrappingLabelWithString: hint); note.alignment = .center; note.preferredMaxLayoutWidth = 430; note.textColor = .secondaryLabelColor; note.font = .systemFont(ofSize: 12)
        stack.addArrangedSubview(icon); stack.addArrangedSubview(title); stack.addArrangedSubview(body); stack.addArrangedSubview(note)
        container.addSubview(stack); stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: container.centerXAnchor), stack.centerYAnchor.constraint(equalTo: container.centerYAnchor), stack.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24)])
        return container
    }
    static func rotate(item: ClipItem, model: AppModel) {
        model.perform {
            var full = try model.store.materialized(item)
            guard let data = full.data, let image = NSImage(data: data) else { model.message("Preview unavailable: image content could not be read."); return }
            let rotated = NSImage(size: NSSize(width: image.size.height, height: image.size.width)); rotated.lockFocus(); let transform = NSAffineTransform(); transform.translateX(by: rotated.size.width, yBy: 0); transform.rotate(byDegrees: 90); transform.concat(); image.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1); rotated.unlockFocus()
            full.data = rotated.tiffRepresentation; full.thumbnail = CaptureService.thumbnail(rotated); swap(&full.imageWidth, &full.imageHeight); full.byteCount = full.data?.count ?? 0; try model.store.update(full, replacingAssets: true)
        }
    }
}

/// Keeps `PreviewWindow.windows` exact: closed previews leave the list at once
/// instead of lingering as invisible retained windows until the next open.
@MainActor final class PreviewCloseWatcher: NSObject, NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        (window.contentView as? QLPreviewView)?.close()
        PreviewWindow.resources.removeValue(forKey: window)?.release()
        PreviewWindow.windows.removeAll { $0 == window }
    }
}

/// Resources owned by one open preview window, released together on close.
@MainActor final class PreviewResources {
    var fileAccess: ScopedPreviewAccess?
    var linkObserver: LinkPreviewCoordinator?
    func release() { fileAccess?.release(); fileAccess = nil; linkObserver = nil }
}

/// Holds security-scoped access to a previewed file for the preview window's
/// lifetime. `FileAssets` resolution balances its own inspection grant before
/// returning the URL, so an asynchronous reader like Quick Look would otherwise
/// run outside any granted scope. The preview owns this separate grant and
/// balances it when the window closes. Saved attachments materialize inside
/// Stash's own library directory and need no grant; external bookmark
/// references grant here. The preflight checks metadata without opening streams.
@MainActor final class ScopedPreviewAccess {
    /// Read-only readability preflight performed while the grant is active, so
    /// an unavailable file surfaces as preview feedback instead of a silent,
    /// later Quick Look failure.
    let isReadable: Bool
    private let url: URL
    private let held: Bool
    private var released = false
    init(url: URL) {
        self.url = url
        self.held = url.startAccessingSecurityScopedResource()
        var readable = FileManager.default.isReadableFile(atPath: url.path)
        if readable {
            do {
                // Opening a FIFO/device can block the main actor; folders are valid previews.
                let type = try url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                readable = type.isDirectory == true || type.isRegularFile == true
            } catch { readable = false }
        }
        self.isReadable = readable
    }
    func release() {
        guard held, !released else { return }
        url.stopAccessingSecurityScopedResource()
        released = true
    }
    deinit {
        if held, !released { url.stopAccessingSecurityScopedResource() }
    }
}

/// Owns link navigation feedback for one preview window. Unsupported schemes
/// and failed loads replace the web view with an understandable explanation in
/// the same window instead of leaving it inert. The coordinator is retained by
/// the window's PreviewResources until the window closes.
@MainActor final class LinkPreviewCoordinator: NSObject, WKNavigationDelegate {
    private weak var window: NSWindow?
    private let address: String
    init(window: NSWindow, address: String) { self.window = window; self.address = address; super.init() }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        if navigationAction.targetFrame?.isMainFrame == false { decisionHandler(.allow); return }
        let scheme = navigationAction.request.url?.scheme?.lowercased()
        guard scheme == "http" || scheme == "https" else {
            decisionHandler(.cancel)
            present(webView, message: "Stash previews web links (http or https) only.", hint: navigationAction.request.url?.absoluteString ?? address)
            return
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(webView, error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(webView, error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { present(webView, message: "This link's web content stopped.", hint: "Preview the link again to reload it.") }
    private func failed(_ webView: WKWebView, _ error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        present(webView, message: "This link could not be opened.", hint: error.localizedDescription)
    }
    private func present(_ webView: WKWebView, message: String, hint: String) {
        webView.stopLoading()
        guard let window, window.isVisible else { return }
        window.contentView = PreviewWindow.unavailableView(message: message, hint: hint)
    }
}

@MainActor final class EditorWindow: NSObject {
    static var editors: [EditorWindow] = []
    let window: NSWindow
    let textView = NSTextView()
    var item: ClipItem
    unowned let model: AppModel
    let isNew: Bool
    init(item: ClipItem, model: AppModel, isNew: Bool) {
        self.item = item; self.model = model; self.isNew = isNew
        window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 650,height: 450), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(); window.title = isNew ? "New text" : item.displayTitle; window.isReleasedWhenClosed = false
        let stack = NSStackView(); stack.orientation = .vertical; stack.spacing = 12; stack.edgeInsets = NSEdgeInsets(top: 16,left: 16,bottom: 16,right: 16)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = textView
        textView.isRichText = true; textView.allowsUndo = true; textView.isVerticallyResizable = true; textView.autoresizingMask = [.width]; textView.textContainer?.widthTracksTextView = true; textView.font = .systemFont(ofSize: 16)
        if #available(macOS 26, *) { textView.writingToolsBehavior = .complete }
        if let rich = try? model.store.materialized(item).richData, let attributed = try? NSAttributedString(data: rich, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) { textView.textStorage?.setAttributedString(attributed) } else { textView.string = item.text }
        let button = NSButton(title: "Save", target: self, action: #selector(save)); button.bezelStyle = .rounded; button.keyEquivalent = "s"
        stack.addArrangedSubview(scroll); stack.addArrangedSubview(button); window.contentView = stack; scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true; scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
    }
    static func open(item: ClipItem, model: AppModel, isNew: Bool = false) { editors.removeAll { !$0.window.isVisible }; let editor = EditorWindow(item: item, model: model, isNew: isNew); editors.append(editor); NSApp.activate(ignoringOtherApps: true); editor.window.center(); editor.window.makeKeyAndOrderFront(nil) }
    @objc func save() { item.text = textView.string; item.kind = .richText; item.richData = textView.rtf(from: NSRange(location: 0,length: textView.string.utf16.count)); model.perform { if isNew { try model.store.add(item) } else { try model.store.update(item, replacingAssets: true) }; window.close() } }
}
