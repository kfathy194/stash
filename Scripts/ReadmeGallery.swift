import AppKit
import SwiftUI

/// Render production content views without starting Stash or reading a screen.
@main @MainActor struct ReadmeGallery {
    private enum GalleryError: Error { case invalidRoot, bitmapUnavailable(String) }

    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw GalleryError.invalidRoot }
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
        let temporaryDirectory = URL(fileURLWithPath: "/private/tmp", isDirectory: true).resolvingSymlinksInPath()
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath()
        let images = root.appendingPathComponent("images", isDirectory: true)
        guard root.deletingLastPathComponent().path == temporaryDirectory.path,
              root.lastPathComponent.hasPrefix("stash-readme-gallery."),
              try String(contentsOf: root.appendingPathComponent("fixture-marker"), encoding: .utf8) == "generated-readme-gallery\n",
              home.path == root.appendingPathComponent("home").path,
              LibraryStore.defaultDirectory().resolvingSymlinksInPath().path.hasPrefix(home.path + "/"),
              images.resolvingSymlinksInPath().path == images.path else { throw GalleryError.invalidRoot }

        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.appearance = NSAppearance(named: .aqua)
        let store = try LibraryStore(directory: root.appendingPathComponent("Library"), inMemory: true, syncEnabled: false)
        let (board, code) = try populate(store)
        let model = AppModel(store: store)
        precondition(model.capture == nil && model.paste == nil && model.hotkeys == nil && model.mcp == nil && model.panel == nil)
        model.selectFirstIfNeeded()
        try capture(PanelView(model: model), height: 330, named: "history", in: images)

        model.query = "release"
        model.filter.kind = .text
        model.showFilters = true
        model.selectFirstIfNeeded()
        try capture(PanelView(model: model), height: 375, named: "search", in: images)

        model.query = ""
        model.filter = .init()
        model.showFilters = false
        model.currentBoard = board.id
        model.selectFirstIfNeeded()
        try capture(PanelView(model: model), height: 330, named: "pinboards", in: images)

        let editor = try EditorWindow(item: code, model: model, isNew: false)
        // Clip the native ruler's separator when AppKit draws the detached scroll view.
        editor.textView.enclosingScrollView?.clipsToBounds = true
        editor.window.setContentSize(NSSize(width: 920, height: 450))
        try save(editor.window, named: "code-editor", in: images)

        model.settingsSection = "Privacy"
        try capture(SettingsView(model: model), height: 540, named: "privacy", in: images)

        let setupLibrary = root.appendingPathComponent("Onboarding", isDirectory: true)
        guard setupLibrary.resolvingSymlinksInPath().path == setupLibrary.path else { throw GalleryError.invalidRoot }
        let startup = try MacStartup(
            directory: setupLibrary,
            syncEnabled: false,
            directPastePermission: DirectPastePermission(status: { .notGranted }, request: {}),
            dailyUseSystem: .isolated
        )
        precondition(startup.needsSetup && startup.model.capture == nil && startup.model.paste == nil
                     && startup.model.hotkeys == nil && startup.model.mcp == nil)
        precondition(startup.step == .welcome)
        try capture(OnboardingView(startup: startup, onFinished: {}), height: 390, named: "onboarding", in: images)
    }

    private static func populate(_ store: LibraryStore) throws -> (Pinboard, ClipItem) {
        var settings = store.settings
        settings.onboardingComplete = true
        settings.ignoredApplications = ["example.invalid.Vault", "example.invalid.PrivateNotes"]
        try store.updateSettings(settings)

        let board = try store.createBoard(name: "Northstar Studio", colorHex: "22B6A5")
        _ = try store.createBoard(name: "Reading list", colorHex: "7987EB")

        let now = Date.now
        func clip(_ kind: ClipKind, _ title: String, _ text: String, minutesAgo: Double) -> ClipItem {
            var item = ClipItem(kind: kind, text: text, createdAt: now.addingTimeInterval(-60 * minutesAgo))
            item.title = title
            item.sourceAppID = "example.invalid.NorthstarStudio"
            item.sourceAppName = "Northstar Studio"
            item.device = "Studio Mac"
            return item
        }

        try store.add(clip(.text, "Release checklist", "Release checklist\n\n• Review the landing page\n• Check keyboard navigation\n• Confirm the launch copy", minutesAgo: 2))
        var link = clip(.link, "Northstar field notes", "https://northstar.example/field-notes", minutesAgo: 8)
        link.linkTitle = "Northstar field notes"
        link.linkDomain = "northstar.example"
        try store.add(link)
        try store.add(clip(.text, "Release note draft", "Release notes\n\nThe studio library has a new home for references, color swatches and reusable snippets.", minutesAgo: 16))

        var code = clip(.code, "Build a release label", """
        struct ReleaseLabel {
            let project: String
            let version: String

            var title: String {
                "\\(project) · v\\(version)"
            }
        }

        // Preview label for the studio checklist.
        let label = ReleaseLabel(project: "Northstar", version: "1.4")
        print(label.title)
        """, minutesAgo: 12)
        code.codeLanguage = "swift"
        try store.add(code, to: board.id)
        try store.add(clip(.color, "Studio jade", "#22B6A5", minutesAgo: 18), to: board.id)
        try store.add(clip(.text, "Project direction", "Keep the launch page simple.\n\nOne clear headline, a calm palette and space for the examples to breathe.", minutesAgo: 25), to: board.id)
        return (board, code)
    }

    private static func capture(_ view: some View, height: CGFloat, named name: String, in images: URL) throws {
        let bounds = NSRect(x: 0, y: 0, width: 920, height: height)
        let window = NSWindow(contentRect: bounds, styleMask: .titled, backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        window.setContentSize(bounds.size)
        try save(window, named: name, in: images)
    }

    private static func save(_ window: NSWindow, named name: String, in images: URL) throws {
        guard let view = window.contentView else { throw GalleryError.bitmapUnavailable(name) }
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(bounds.width * 2),
            pixelsHigh: Int(bounds.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { throw GalleryError.bitmapUnavailable(name) }
        bitmap.size = bounds.size
        view.cacheDisplay(in: bounds, to: bitmap)
        // Native editor controls draw into the view's transparent content layer.
        // Composite it over the window color without capturing the desktop.
        guard let viewImage = bitmap.cgImage,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let canvas = CGContext(
                data: nil, width: bitmap.pixelsWide, height: bitmap.pixelsHigh,
                bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else { throw GalleryError.bitmapUnavailable(name) }
        let pixels = CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
        canvas.setFillColor(NSColor.windowBackgroundColor.cgColor)
        canvas.fill(pixels)
        canvas.draw(viewImage, in: pixels)
        guard let image = canvas.makeImage(),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw GalleryError.bitmapUnavailable(name)
        }
        try data.write(to: images.appendingPathComponent(name + ".png"), options: .atomic)
        print("Rendered \(name) at \(bitmap.pixelsWide) × \(bitmap.pixelsHigh)")
    }
}
