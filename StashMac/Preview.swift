import SwiftUI
import AppKit
import WebKit
import Quartz
import StashCore

@MainActor enum PreviewWindow {
    static var windows: [NSWindow] = []
    static func open(item: ClipItem, model: AppModel) {
        do {
            let full = try model.store.materialized(item)
            let controller = NSViewController(); let window = NSWindow(contentViewController: controller); window.title = item.displayTitle; window.styleMask = [.titled, .closable, .resizable]; window.setContentSize(NSSize(width: 740, height: 530)); window.isReleasedWhenClosed = false
            if item.kind == .link, let url = URL(string: item.text) { let web = WKWebView(); web.load(URLRequest(url: url)); controller.view = web }
            else if item.kind == .file, let url = try? FileAssets.resolve(full, directory: LibraryStore.defaultDirectory()) { let preview = QLPreviewView(frame: NSRect(x: 0,y: 0,width: 740,height: 530), style: .normal)!; preview.previewItem = url as NSURL; controller.view = preview }
            else if item.kind == .image, let data = full.data, let image = NSImage(data: data) { let view = NSImageView(); view.image = image; view.imageScaling = .scaleProportionallyUpOrDown; controller.view = view }
            else { let scroll = NSScrollView(); scroll.hasVerticalScroller = true; let text = NSTextView(); text.isEditable = false; text.isSelectable = true; text.textContainerInset = NSSize(width: 24,height: 24); text.autoresizingMask = [.width]; text.isVerticallyResizable = true; text.font = .systemFont(ofSize: 16); if let rich = full.richData, let string = try? NSAttributedString(data: rich, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) { text.textStorage?.setAttributedString(string) } else { text.string = full.text }; scroll.documentView = text; controller.view = scroll }
            window.center(); window.makeKeyAndOrderFront(nil); windows.removeAll { !$0.isVisible }; windows.append(window)
        } catch { model.message(error.localizedDescription) }
    }
    static func rotate(item: ClipItem, model: AppModel) {
        model.perform {
            var full = try model.store.materialized(item); guard let data = full.data, let image = NSImage(data: data) else { return }
            let rotated = NSImage(size: NSSize(width: image.size.height, height: image.size.width)); rotated.lockFocus(); let transform = NSAffineTransform(); transform.translateX(by: rotated.size.width, yBy: 0); transform.rotate(byDegrees: 90); transform.concat(); image.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1); rotated.unlockFocus()
            full.data = rotated.tiffRepresentation; full.thumbnail = CaptureService.thumbnail(rotated); swap(&full.imageWidth, &full.imageHeight); full.byteCount = full.data?.count ?? 0; try model.store.update(full, replacingAssets: true)
        }
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
