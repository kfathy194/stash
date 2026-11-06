import SwiftUI
import AppKit
import StashCore
import CloudKit

@main struct StashApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene { Settings { if let model = delegate.model { SettingsView(model: model) } else { Text("Stash could not open its library.").padding() } } }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    var panel: PanelController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        do {
            let sync = AppModel.cloudKitAvailable && LibraryStore.syncRequested
            let demo = (ProcessInfo.processInfo.arguments.contains("--demo") || Bundle.main.object(forInfoDictionaryKey:"StashDemoMode") as? Bool == true)
            let store = try LibraryStore(inMemory: demo, syncEnabled: demo ? false : sync)
            if demo { try seedDemo(store) }
            let model = AppModel(store: store); self.model = model
            let panel = PanelController(model: model); self.panel = panel; model.panel = panel; model.start(captureEnabled: !demo)
            if !store.settings.onboardingComplete { model.showSettings() }
            if demo || ProcessInfo.processInfo.arguments.contains("--show-panel") { panel.show() }
        } catch { let alert = NSAlert(); alert.messageText = "Stash couldn't open your library"; alert.informativeText = error.localizedDescription + "\nYour existing data has been preserved."; alert.runModal(); NSApp.terminate(nil) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !(model?.settings.runInBackground ?? true) }
    func application(_ application: NSApplication, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) { guard let model else { return }; guard AppModel.cloudKitAvailable else { model.message("iCloud sharing is unavailable in this development build."); return }; Task { do { try await model.store.acceptShare(metadata) } catch { model.message(error.localizedDescription) } } }
    private func seedDemo(_ store: LibraryStore) throws {
        let board = try store.createBoard(name:"Studio", colorHex:"7987EB")
        _ = try store.createBoard(name:"Everyday", colorHex:"F0A154")
        var note = ClipItem(kind:.text,text:"Good ideas deserve a second look.\n\nKeep your next draft, useful snippet or small discovery close."); note.sourceAppID = "com.apple.Notes"; note.sourceAppName = "Notes"; note.device = "Mac"; try store.add(note)
        var color = ClipItem(kind:.color,text:"#30B7A8",createdAt:.now.addingTimeInterval(-120)); color.sourceAppID = "com.apple.TextEdit"; color.sourceAppName = "TextEdit"; try store.add(color)
        var link = ClipItem(kind:.link,text:"https://developer.apple.com",createdAt:.now.addingTimeInterval(-240)); link.linkTitle = "Build something thoughtful"; link.linkDomain = "developer.apple.com"; link.sourceAppID = "com.apple.Safari"; link.sourceAppName = "Safari"; try store.add(link)
        var code = ClipItem(kind:.code,text:"struct Thought {\n    let text: String\n    let worthKeeping = true\n}",createdAt:.now.addingTimeInterval(-360)); code.sourceAppName = "Xcode"; code.sourceAppID = "com.apple.dt.Xcode"; try store.add(code); try store.pin([code.id],to:board.id)
        var settings = store.settings; settings.onboardingComplete = true; try store.updateSettings(settings)
    }

}
