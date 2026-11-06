import SwiftUI
import AppKit
import StashCore
import CloudKit

@main struct StashApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        Settings {
            if delegate.needsSetup {
                Button("Resume Setup") { delegate.showSetup() }
                    .padding(24)
                    .onAppear { delegate.showSetup() }
            } else if let model = delegate.model {
                SettingsView(model: model)
            } else {
                Text("Stash could not open its library.").padding()
            }
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    @Published private(set) var model: AppModel?
    private var startup: MacStartup?
    private var panel: PanelController?
    private var setupWindow: OnboardingWindowController?
    private var setupStatus: NSStatusItem?
    private var pendingShares: [CKShare.Metadata] = []

    var needsSetup: Bool { startup?.needsSetup == true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        do {
            let arguments = ProcessInfo.processInfo.arguments
            let demo = arguments.contains("--demo") || Bundle.main.object(forInfoDictionaryKey: "StashDemoMode") as? Bool == true
            if demo {
                let store = try LibraryStore(inMemory: true)
                try seedDemo(store)
                let model = AppModel(store: store)
                startApplication(model, captureEnabled: false)
                panel?.show()
                return
            }

            let startup = try MacStartup(directory: LibraryStore.defaultDirectory(),
                                         syncEnabled: AppModel.cloudKitAvailable && LibraryStore.syncRequested,
                                         dailyUseSystem: .system)
            self.startup = startup
            if startup.needsSetup {
                installSetupStatus()
                showSetup()
            } else {
                startup.startIfReady { startApplication($0) }
                if arguments.contains("--show-panel") { panel?.show() }
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Stash couldn't open your library"
            alert.informativeText = error.localizedDescription + "\nYour existing data has been preserved."
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    @objc func showSetup() {
        guard let startup else { return }
        guard startup.openWizard() else {
            startup.model.message(startup.errorMessage ?? "Stash couldn’t open setup.")
            return
        }
        if setupWindow == nil {
            setupWindow = OnboardingWindowController(startup: startup) { [weak self] in self?.finishedSetup() }
        }
        NSApp.activate(ignoringOtherApps: true)
        setupWindow?.showWindow(nil)
        setupWindow?.window?.makeKeyAndOrderFront(nil)
    }

    private func installSetupStatus() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(named: "StashStatus")
        image?.isTemplate = true
        image?.size = NSSize(width: 18, height: 18)
        item.button?.image = image
        item.button?.toolTip = "Stash Setup"
        item.button?.setAccessibilityLabel("Stash Setup")
        let menu = NSMenu()
        let resume = NSMenuItem(title: "Resume Setup", action: #selector(showSetup), keyEquivalent: "")
        resume.target = self
        menu.addItem(resume)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Stash", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        item.menu = menu
        setupStatus = item
    }

    private func finishedSetup() {
        guard let startup, !startup.needsSetup else { return }
        if let setupStatus { NSStatusBar.system.removeStatusItem(setupStatus) }
        setupStatus = nil
        startup.startIfReady { startApplication($0) }
        panel?.show()
        setupWindow?.close()
        setupWindow = nil
    }

    private func startApplication(_ model: AppModel, captureEnabled: Bool = true) {
        if startup != nil { model.openSetupWizard = { [weak self] in self?.showSetup() } }
        self.model = model
        let panel = PanelController(model: model)
        self.panel = panel
        model.panel = panel
        model.start(captureEnabled: captureEnabled)
        let shares = pendingShares
        pendingShares.removeAll()
        for metadata in shares { acceptShare(metadata, model: model) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard needsSetup else { return true }
        showSetup()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !needsSetup && !(model?.settings.runInBackground ?? true)
    }

    func application(_ application: NSApplication, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        if needsSetup {
            pendingShares.append(metadata)
            showSetup()
        } else if let model {
            acceptShare(metadata, model: model)
        }
    }

    private func acceptShare(_ metadata: CKShare.Metadata, model: AppModel) {
        guard AppModel.cloudKitAvailable else {
            model.message("iCloud sharing is unavailable in this development build.")
            return
        }
        Task {
            do { try await model.store.acceptShare(metadata) }
            catch { model.message(error.localizedDescription) }
        }
    }

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
