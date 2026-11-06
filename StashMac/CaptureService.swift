import AppKit
import StashCore

@MainActor final class CaptureService {
    struct Source {
        let changeCount: () -> Int
        let readAllowedItem: (LibrarySettings) -> ClipItem?
    }

    unowned let model: AppModel
    private let source: Source
    private var timer: Timer?
    private var lastChange: Int
    private var lastRetention = Date.distantPast

    init(model: AppModel, source: Source? = nil) {
        self.model = model
        let source = source ?? Source(
            changeCount: { NSPasteboard.general.changeCount },
            readAllowedItem: Self.readSystemClipboard
        )
        self.source = source
        lastChange = source.changeCount()
    }

    func start() {
        guard timer == nil else { return }
        suppressCurrentChange()
        timer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func suppressCurrentChange() { lastChange = source.changeCount() }

    func poll() {
        if Date().timeIntervalSince(lastRetention) > 3600 {
            lastRetention = .now
            model.perform { try model.store.applyRetention() }
        }
        let change = source.changeCount()
        guard change != lastChange else { return }
        lastChange = change
        if let item = source.readAllowedItem(model.settings) { model.captured(item) }
    }

    private static func readSystemClipboard(settings: LibrarySettings) -> ClipItem? {
        let board = NSPasteboard.general
        let app = NSWorkspace.shared.frontmostApplication
        guard app?.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        let types = (board.types ?? []).map(\.rawValue)
        guard CapturePolicy.allows(types: types, app: app?.bundleIdentifier, settings: settings, now: .now),
              var item = read(board) else { return nil }
        item.sourceAppID = app?.bundleIdentifier ?? ""
        item.sourceAppName = app?.localizedName ?? "Unknown app"
        item.device = Host.current().localizedName ?? "Mac"
        return item
    }

    private static func read(_ board: NSPasteboard) -> ClipItem? {
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
