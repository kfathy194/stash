import AppKit
import SwiftUI
import StashCore

// This executable links the production retention view, never the application delegate or OS services.
@main enum RetentionSmoke {
    static func main() {
        let app = NSApplication.shared
        let delegate = RetentionSmokeDelegate()
        app.delegate = delegate
        app.run()
    }
}

@MainActor final class RetentionSmokeDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            guard let path = ProcessInfo.processInfo.environment["STASH_RETENTION_SMOKE_ROOT"] else { throw CocoaError(.fileNoSuchFile) }
            let root = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            guard root.deletingLastPathComponent() == URL(fileURLWithPath: "/private/tmp", isDirectory: true).resolvingSymlinksInPath(), root.lastPathComponent.hasPrefix("stash-retention-smoke."),
                  try String(contentsOf: root.appendingPathComponent("fixture-marker"), encoding: .utf8) == "generated-retention-fixture\n" else { throw CocoaError(.fileReadNoPermission) }
            let directory = root.appendingPathComponent("Library", isDirectory: true)
            let isNew = !FileManager.default.fileExists(atPath: directory.path)
            let store = try LibraryStore(directory: directory, syncEnabled: false)
            if isNew {
                var settings = store.settings; settings.retentionDays = nil; settings.onboardingComplete = true
                try store.updateSettings(settings)
                let now = Date()
                try store.add(ClipItem(kind: .text, text: "Generated History — 60 days old", createdAt: now.addingTimeInterval(-60 * 86_400)))
                try store.add(ClipItem(kind: .text, text: "Generated History — 10 days old", createdAt: now.addingTimeInterval(-10 * 86_400)))
                let board = try store.createBoard(name: "Generated Pinboard", colorHex: "30B7A8")
                let pinned = ClipItem(kind: .text, text: "Generated Pinboard — 90 days old", createdAt: now.addingTimeInterval(-90 * 86_400))
                try store.add(pinned); try store.pin([pinned.id], to: board.id)
                assert(store.items.count == 3 && store.items.filter { $0.pinboardID != nil }.count == 1 && store.settings.retentionDays == nil)
            }
            try store.applyRetention()
            let window = NSWindow(contentViewController: NSHostingController(rootView: RetentionSmokeView(store: store, directory: directory)))
            window.title = "Stash Retention — Disposable Fixture"
            window.setContentSize(NSSize(width: 620, height: 500)); window.isReleasedWhenClosed = false
            self.window = window
            NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
            window.center(); window.makeKeyAndOrderFront(nil)
        } catch {
            fputs("Retention smoke could not open its disposable fixture: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct RetentionSmokeView: View {
    @State var store: LibraryStore
    let directory: URL
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Disposable retention fixture").font(.title2.bold())
            HistoryRetentionSettings(store: store, saveSettings: saveSettings, reportError: { error = $0 })
            Divider()
            Text("Stored policy: " + (store.settings.retentionDays.map { "\($0) days" } ?? "Forever"))
            ForEach(store.items) { item in Text((item.pinboardID == nil ? "History: " : "Pinned: ") + item.text) }
            Button("Reopen disposable library") {
                do { let reopened = try LibraryStore(directory: directory, syncEnabled: false); try reopened.applyRetention(); store = reopened }
                catch { self.error = error.localizedDescription }
            }
            if let error { Text(error).foregroundStyle(.red) }
            Spacer()
        }.padding(24).frame(minWidth: 600, minHeight: 480)
    }
    private func saveSettings(_ edit: (inout LibrarySettings) -> Void) -> Bool {
        var settings = store.settings; edit(&settings)
        do { try store.updateSettings(settings); return true }
        catch { store.context.rollback(); self.error = error.localizedDescription; return false }
    }
}
