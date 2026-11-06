import AppKit
import SwiftUI

/// Displays the production setup window with a generated library and no normal services.
@main @MainActor struct OnboardingSmoke {
    static func main() throws {
        guard CommandLine.arguments.count >= 2 else {
            fatalError("Launch this fixture through Scripts/onboarding_smoke.sh.")
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
        guard root.deletingLastPathComponent() == URL(fileURLWithPath: "/private/tmp", isDirectory: true).resolvingSymlinksInPath(),
              root.lastPathComponent.hasPrefix("stash-onboarding-smoke."),
              try String(contentsOf: root.appendingPathComponent("fixture-marker"), encoding: .utf8) == "generated-onboarding-fixture\n",
              LibraryStore.defaultDirectory().resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else {
            fatalError("The onboarding fixture requires its generated root and isolated home.")
        }

        let library = root.appendingPathComponent("Library").resolvingSymlinksInPath()
        guard library.deletingLastPathComponent() == root else {
            fatalError("The generated library must stay within the fixture root.")
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let fixture = OnboardingFixture(
            root: root,
            library: library,
            writeSnapshots: CommandLine.arguments.contains("--snapshots"),
            writePrivacySnapshots: CommandLine.arguments.contains("--privacy-snapshots"),
            writeDailyUseSnapshots: CommandLine.arguments.contains("--daily-use-snapshots"),
            verifyJourney: CommandLine.arguments.contains("--journey-snapshots")
        )
        app.delegate = fixture
        withExtendedLifetime(fixture) { app.run() }
    }
}

@MainActor private final class OnboardingFixture: NSObject, NSApplicationDelegate {
    let root: URL
    let library: URL
    let writeSnapshots: Bool
    let writePrivacySnapshots: Bool
    let writeDailyUseSnapshots: Bool
    let verifyJourney: Bool
    var controller: OnboardingWindowController?
    private var simulatedAccess = DirectPastePermission.Status.notGranted
    private var simulatedLogin = DailyUseSystem.LoginStatus.manual

    init(root: URL, library: URL, writeSnapshots: Bool, writePrivacySnapshots: Bool, writeDailyUseSnapshots: Bool, verifyJourney: Bool) {
        self.root = root
        self.library = library
        self.writeSnapshots = writeSnapshots
        self.writePrivacySnapshots = writePrivacySnapshots
        self.writeDailyUseSnapshots = writeDailyUseSnapshots
        self.verifyJourney = verifyJourney
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let permission = DirectPastePermission(
                status: { [weak self] in self?.simulatedAccess ?? .unavailable },
                request: { [weak self] in self?.simulatedAccess = .granted }
            )
            let dailyUse = DailyUseSystem(
                prepareShortcuts: { _, shortcuts in
                    if shortcuts.stack != nil { throw DailyUseIssue.unavailable(.stack) }
                    return ShortcutChange()
                },
                loginStatus: { self.simulatedLogin },
                setLoginEnabled: { self.simulatedLogin = $0 ? .requiresApproval : .manual }
            )
            let startup = try writePrivacySnapshots
                ? resumedPrivacyDraft(permission: permission)
                : MacStartup(directory: library, syncEnabled: false, directPastePermission: permission,
                             dailyUseSystem: writeDailyUseSnapshots ? dailyUse : .isolated)
            precondition(startup.model.capture == nil && startup.model.paste == nil && startup.model.hotkeys == nil && startup.model.mcp == nil)
            let controller = OnboardingWindowController(startup: startup) { [verifyJourney] in
                if !verifyJourney { NSApp.terminate(nil) }
            }
            self.controller = controller
            controller.showWindow(nil)
            if verifyJourney {
                NSApp.activate(ignoringOtherApps: true)
                controller.window?.makeKeyAndOrderFront(nil)
            }
            if writeSnapshots || writePrivacySnapshots || writeDailyUseSnapshots || verifyJourney {
                Task { @MainActor in
                    do {
                        try await Task.sleep(for: .milliseconds(250))
                        if verifyJourney {
                            try await journeySnapshots(startup)
                            NSApp.terminate(nil)
                            return
                        }
                        if writeDailyUseSnapshots {
                            try await dailyUseSnapshots(startup)
                            NSApp.terminate(nil)
                            return
                        }
                        if writePrivacySnapshots {
                            try snapshot("privacy-resumed")
                            startup.go(to: .ready)
                            precondition(!startup.finish() && startup.confirmsHistoryDeletion)
                            try await Task.sleep(for: .milliseconds(150))
                            try snapshot("privacy-delete-confirmation")
                            guard let window = controller.window else { throw CocoaError(.fileWriteUnknown) }
                            try pressCommandReturn(in: window)
                            precondition(startup.confirmsHistoryDeletion, "The primary shortcut must not confirm deletion")
                            startup.cancelHistoryDeletion()
                            precondition(startup.model.settings.retentionDays == nil)
                            NSApp.terminate(nil)
                            return
                        }
                        try snapshot("welcome")
                        startup.go(to: .directPaste)
                        try await Task.sleep(for: .milliseconds(150))
                        try snapshot("direct-paste-manual")
                        simulatedAccess = .granted
                        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
                        try await Task.sleep(for: .milliseconds(150))
                        precondition(startup.directPasteStatus == .granted, "Returning to Stash should refresh Accessibility")
                        try snapshot("direct-paste-granted")
                        startup.go(to: .ready)
                        try await Task.sleep(for: .milliseconds(150))
                        try snapshot("ready")
                        NSApp.terminate(nil)
                    } catch {
                        fatalError("Could not render generated setup: \(error.localizedDescription)")
                    }
                }
            } else {
                NSApp.activate(ignoringOtherApps: true)
            }
        } catch {
            fatalError("Could not open generated setup fixture: \(error.localizedDescription)")
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func journeySnapshots(_ startup: MacStartup) async throws {
        guard let window = controller?.window else { throw CocoaError(.fileWriteUnknown) }
        window.appearance = NSAppearance(named: .aqua)
        for step in [OnboardingStep.privacy, .dailyUse, .directPaste, .ready] {
            try pressCommandReturn(in: window)
            try await Task.sleep(for: .milliseconds(120))
            precondition(startup.step == step, "Command–Return should advance to \(step)")
            if step == .dailyUse {
                guard let content = window.contentView, let recorder = openStashRecorder(in: content) else {
                    throw CocoaError(.featureUnsupported)
                }
                recorder.performClick(nil)
                try pressCommandReturn(in: window)
                precondition(startup.step == .dailyUse && startup.draft?.panelShortcut?.keyCode == 36
                             && startup.draft?.panelShortcut?.modifiers == 256,
                             "A shortcut recording must receive Command–Return before wizard navigation")
                startup.editDraft { $0.panelShortcut = LibrarySettings().panelShortcut }
                try await Task.sleep(for: .milliseconds(120))
            }
        }
        try snapshot("journey-ready-light")
        window.appearance = NSAppearance(named: .darkAqua)
        try await Task.sleep(for: .milliseconds(120))
        try snapshot("journey-ready-dark")
        try pressCommandReturn(in: window)
        try await Task.sleep(for: .milliseconds(120))
        precondition(startup.step == nil && !startup.needsSetup && startup.model.showsSetupGuide)
        precondition(startup.model.capture == nil && startup.model.paste == nil && startup.model.hotkeys == nil)
        let panel = NSHostingView(rootView: PanelView(model: startup.model)
            .frame(width: 920, height: 350)
            .background(Color(nsColor: .windowBackgroundColor)))
        panel.frame.size = NSSize(width: 920, height: 350)
        panel.appearance = NSAppearance(named: .aqua)
        try snapshot("journey-history-guide", contentView: panel)
    }

    private func openStashRecorder(in view: NSView) -> ShortcutButton? {
        if let button = view as? ShortcutButton, button.shortcutTitle.hasPrefix("Open Stash") { return button }
        return view.subviews.lazy.compactMap { self.openStashRecorder(in: $0) }.first
    }

    private func pressCommandReturn(in window: NSWindow) throws {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)
        else { throw CocoaError(.featureUnsupported) }
        window.sendEvent(event)
    }

    private func dailyUseSnapshots(_ startup: MacStartup) async throws {
        startup.go(to: .dailyUse)
        try await Task.sleep(for: .milliseconds(150))
        try snapshot("daily-use")
        startup.editDraft { $0.launchAtLogin = true }
        startup.go(to: .ready)
        precondition(!startup.finish() && startup.dailyUseIssue == .unavailable(.stack))
        try await Task.sleep(for: .milliseconds(150))
        try snapshot("daily-use-shortcut-fallback")
        startup.continueWithoutShortcut(.stack)
        precondition(!startup.finish())
        guard case .login = startup.dailyUseIssue else {
            throw CocoaError(.featureUnsupported)
        }
        try await Task.sleep(for: .milliseconds(150))
        try snapshot("daily-use-login-fallback")
        startup.continueWithManualStartup()
        precondition(startup.finish() && startup.model.settings.stackShortcutDisabled == true)
    }

    private func resumedPrivacyDraft(permission: DirectPastePermission) throws -> MacStartup {
        let store = try LibraryStore(directory: library)
        var settings = store.settings
        settings.retentionDays = nil
        settings.ignoredApplications = ["example.invalid.Notebook"]
        try store.updateSettings(settings)
        let older = Date.now.addingTimeInterval(-20 * 86_400)
        try store.add(ClipItem(kind: .text, text: "Generated older History", createdAt: older))
        let board = try store.createBoard(name: "Generated Pinboard")
        try store.add(ClipItem(kind: .text, text: "Generated pinned item", createdAt: older), to: board.id)

        let first = try MacStartup(directory: library, directPastePermission: permission)
        precondition(first.openWizard())
        first.go(to: .privacy)
        first.editDraft {
            $0.retentionDays = 7
            $0.ignoredApplications.append("example.invalid.PrivateNotes")
        }
        let resumed = try MacStartup(directory: library, directPastePermission: permission)
        precondition(!resumed.needsSetup && resumed.openWizard() && resumed.step == .privacy)
        precondition(resumed.draft?.retentionDays == 7 && resumed.model.settings.retentionDays == nil)
        return resumed
    }

    private func snapshot(_ name: String, contentView: NSView? = nil) throws {
        guard let view = contentView ?? controller?.window?.contentView else { throw CocoaError(.fileWriteUnknown) }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let destination = root.appendingPathComponent(name).appendingPathExtension("png")
        try data.write(to: destination, options: .atomic)
        print(destination.path)
    }
}
