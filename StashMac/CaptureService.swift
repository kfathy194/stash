import AppKit
import StashCore

@MainActor final class CaptureService {
    unowned let model: AppModel
    private var timer: Timer?
    private var lastChange: Int
    private var lastRetention = Date.distantPast
    init(model: AppModel) { self.model = model; lastChange = NSPasteboard.general.changeCount }
    func start() { timer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { [weak self] _ in Task { @MainActor in self?.poll() } } }
    func suppressCurrentChange() { lastChange = NSPasteboard.general.changeCount }
    func poll() {
        if Date().timeIntervalSince(lastRetention) > 3600 { lastRetention = .now; model.perform { try model.store.applyRetention() } }
        let board = NSPasteboard.general
        guard board.changeCount != lastChange else { return }; lastChange = board.changeCount
        let app = NSWorkspace.shared.frontmostApplication
        guard app?.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        let types = (board.types ?? []).map(\.rawValue)
        guard CapturePolicy.allows(types: types, app: app?.bundleIdentifier, settings: model.settings, now: .now) else { return }
        guard var item = read(board) else { return }
        item.sourceAppID = app?.bundleIdentifier ?? ""; item.sourceAppName = app?.localizedName ?? "Unknown app"; item.device = Host.current().localizedName ?? "Mac"
        model.captured(item)
    }
    func read(_ board: NSPasteboard) -> ClipItem? {
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            var item = ClipItem(kind: .file, text: urls.map(\.lastPathComponent).joined(separator: "\n")); item.fileURLs = urls.map(\.absoluteString)
            item.fileBookmarks = FileBookmarks.capture(urls: urls) { try? $0.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) }
            item.byteCount = urls.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }; return item
        }
        if let data = board.data(forType: .png) ?? board.data(forType: .tiff), let image = NSImage(data: data) {
            var item = ClipItem(kind: .image); item.data = data; item.byteCount = data.count; item.thumbnail = Self.thumbnail(image)
            if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) { item.imageWidth = cg.width; item.imageHeight = cg.height }; return item
        }
        if let text = board.string(forType: .string), !text.isEmpty {
            var item = ClipItem(kind: ContentClassifier.kind(for: text), text: text); item.byteCount = text.utf8.count
            if let rich = board.data(forType: .rtf), item.kind == .text { item.kind = .richText; item.richData = rich }; return item
        }
        if let rich = board.data(forType: .rtf), let attributed = try? NSAttributedString(data: rich, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) { var item = ClipItem(kind: .richText, text: attributed.string); item.richData = rich; return item }
        return nil
    }
    static func thumbnail(_ image: NSImage) -> Data? {
        let size = image.size; let ratio = min(1, 500 / max(size.width, size.height)); guard ratio.isFinite, ratio > 0 else { return nil }
        let target = NSImage(size: NSSize(width: max(1, size.width * ratio), height: max(1, size.height * ratio)))
        target.lockFocus(); image.draw(in: NSRect(origin: .zero, size: target.size)); target.unlockFocus()
        return target.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }
}
