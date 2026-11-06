import AppKit
import SwiftUI
import StashCore

private extension OnboardingStep {
    var title: String {
        switch self {
        case .welcome: "Welcome"
        case .privacy: "Privacy"
        case .dailyUse: "Daily use"
        case .directPaste: "Direct paste"
        case .ready: "Ready"
        }
    }
}

struct OnboardingView: View {
    let startup: MacStartup
    let onFinished: () -> Void
    var onDiscarded: () -> Void = {}
    @FocusState private var focusedStep: OnboardingStep?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let step = startup.step, let draft = startup.draft {
            VStack(alignment: .leading, spacing: 20) {
                header(step)
                Divider()
                if startup.confirmsHistoryDeletion {
                    historyDeletionConfirmation
                } else {
                    ScrollView {
                        page(step, draft: draft)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(step)
                    }
                    if let errorMessage = startup.errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let issue = startup.dailyUseIssue { integrationRecovery(issue) }
                    navigation(step)
                }
            }
            .padding(30)
            .frame(minWidth: 580, minHeight: 390)
            .background(Color(nsColor: .windowBackgroundColor))
            .tint(StashBrand.accent)
            .transaction { if reduceMotion { $0.disablesAnimations = true } }
            .defaultFocus($focusedStep, step)
            .task(id: step) { focusedStep = step }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                startup.refreshLoginStatus()
                startup.refreshDirectPastePermission()
            }
        }
    }

    private func header(_ step: OnboardingStep) -> some View {
        let number = (OnboardingStep.allCases.firstIndex(of: step) ?? 0) + 1
        return HStack {
            StashGlyph().fill(StashBrand.jade).frame(width: 25, height: 25)
                .accessibilityHidden(true)
            Text(StashBrand.name).font(.system(size: 21, weight: .semibold, design: .rounded))
            Spacer()
            Text("Step \(number) of \(OnboardingStep.allCases.count) · \(step.title)")
                .font(.callout).foregroundStyle(.secondary)
                .accessibilityLabel("Setup progress")
                .accessibilityValue("Step \(number) of \(OnboardingStep.allCases.count), \(step.title)")
        }
    }

    @ViewBuilder private func page(_ step: OnboardingStep, draft: OnboardingDraft) -> some View {
        switch step {
        case .welcome:
            VStack(alignment: .leading, spacing: 15) {
                heading("A home for the things you copy.")
                Text("Stash keeps a searchable History so you can find and reuse what you copy. Save the things you need again in Pinboards.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                detail("lock.shield", startup.needsSetup
                       ? "Clipboard collection starts after you finish setup."
                       : "Your current settings stay in effect until you finish.")
            }
        case .privacy:
            VStack(alignment: .leading, spacing: 14) {
                heading("Privacy")
                Text("Choose how long Stash keeps History and which apps to exclude.")
                    .foregroundStyle(.secondary)
                HistoryRetentionPicker(retentionDays: Binding(
                    get: { startup.draft?.retentionDays },
                    set: { days in startup.editDraft { $0.retentionDays = days } }
                ))
                Divider()
                ExcludedApplicationsSettings(applications: Binding(
                    get: { startup.draft?.ignoredApplications ?? [] },
                    set: { applications in startup.editDraft { $0.ignoredApplications = applications } }
                ))
            }
        case .dailyUse:
            VStack(alignment: .leading, spacing: 14) {
                heading("Daily use")
                Text("Choose how to open Stash and start Paste Stack.")
                    .foregroundStyle(.secondary)
                ShortcutRecorder(title: "Open Stash", value: Binding(
                    get: { startup.draft?.panelShortcut },
                    set: { binding in startup.editDraft { $0.panelShortcut = binding } }
                ))
                ShortcutRecorder(title: "Paste Stack", value: Binding(
                    get: { startup.draft?.stackShortcut },
                    set: { binding in startup.editDraft { $0.stackShortcut = binding } }
                ))
                Divider()
                Toggle("Launch at login", isOn: Binding(
                    get: { startup.draft?.launchAtLogin ?? false },
                    set: { enabled in startup.editDraft { $0.launchAtLogin = enabled } }
                ))
                Text("Current login setting: " + startup.loginStatus.description)
                    .font(.callout).foregroundStyle(.secondary)
            }
        case .directPaste:
            OnboardingDirectPasteView(startup: startup)
        case .ready:
            VStack(alignment: .leading, spacing: 13) {
                heading("Ready to start")
                Text("Review your choices. You can change them in Stash Settings at any time.")
                    .foregroundStyle(.secondary)
                detail("clock", draft.retentionDays.map { "History stays for \($0) \($0 == 1 ? "day" : "days")" }
                       ?? "History stays until you remove it")
                if draft.ignoredApplications.isEmpty {
                    detail("lock.shield", "No excluded apps")
                } else {
                    DisclosureGroup("Excluded apps (\(draft.ignoredApplications.count))") {
                        ForEach(draft.ignoredApplications, id: \.self) { Text($0).textSelection(.enabled) }
                    }
                }
                detail("hand.raised", startup.directPasteStatus == .granted
                       ? "Accessibility allows direct paste in compatible apps"
                       : "Manual paste is available with Command–V")
                detail("command", draft.panelShortcut.map { "Open Stash: " + shortcutLabel($0) } ?? "Open Stash from the menu bar")
                detail("list.clipboard", draft.stackShortcut.map { "Paste Stack: " + shortcutLabel($0) } ?? "Open Paste Stack from the menu bar")
                if draft.requestsLoginChange {
                    detail("power", draft.launchAtLogin ? "Requested: launch at login" : "Requested: start Stash manually")
                } else {
                    detail("power", startup.loginStatus.description)
                }
                Text("After Finish, use the optional guide in History to try a copy or open Settings for iCloud, Suggestions, MCP, and imports.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func navigation(_ step: OnboardingStep) -> some View {
        let steps = OnboardingStep.allCases
        let index = steps.firstIndex(of: step) ?? 0
        return HStack {
            if index > 0 {
                Button("Back") { startup.go(to: steps[index - 1]) }
            }
            Button("Discard changes") {
                if startup.discardDraft(), startup.step == nil { onDiscarded() }
            }
            .help("Discard the draft and cancel its uncommitted login request. Saved settings stay active.")
            .accessibilityHint("Saved settings stay active when you discard this draft.")
            Spacer()
            if index == steps.count - 1 {
                Button(startup.dailyUseIssue == nil ? "Finish" : "Retry", action: performPrimaryAction)
                    .buttonStyle(.borderedProminent)
                    .focusable()
                    .focused($focusedStep, equals: step)
                    .help("Command–Return")
            } else {
                Button(step == .directPaste && startup.directPasteStatus != .granted ? "Continue without direct paste" : "Continue",
                       action: performPrimaryAction)
                    .buttonStyle(.borderedProminent)
                    .focusable()
                    .focused($focusedStep, equals: step)
                    .help("Command–Return")
            }
        }
    }

    private func integrationRecovery(_ issue: DailyUseIssue) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let shortcut = issue.shortcut {
                HStack {
                    Button("Choose another shortcut") { startup.go(to: .dailyUse) }
                    Button("Continue without " + shortcut.name + " shortcut") {
                        startup.continueWithoutShortcut(shortcut)
                    }
                }
            } else {
                Text("Current login setting: " + startup.loginStatus.description)
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    if startup.loginStatus == .requiresApproval {
                        Button("Open Login Items", action: startup.openLoginItems)
                    }
                    Button(startup.offersManualLoginFallback ? "Continue with manual startup" : "Continue without changing login") {
                        startup.continueWithManualStartup()
                    }
                }
            }
        }
    }

    private var historyDeletionConfirmation: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading("Delete older History?")
            Text("Items older than the new limit will be permanently deleted. Pinboards are kept. Cancel to keep your current settings and review your draft.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            HStack {
                Button("Cancel", action: startup.cancelHistoryDeletion)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Delete Older Items", role: .destructive) { complete(confirmDeletion: true) }
            }
        }
    }

    func performPrimaryAction() {
        guard let step = startup.step, !startup.confirmsHistoryDeletion else { return }
        if step == .ready {
            complete()
        } else if let index = OnboardingStep.allCases.firstIndex(of: step) {
            startup.go(to: OnboardingStep.allCases[index + 1])
        }
    }

    private func complete(confirmDeletion: Bool = false) {
        if startup.finish(confirmDeletion: confirmDeletion) { onFinished() }
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
    }

    private func detail(_ icon: String, _ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 11) {
            Image(systemName: icon).foregroundStyle(.secondary)
                .frame(width: 20).accessibilityHidden(true)
            Text(message).fixedSize(horizontal: false, vertical: true)
        }
    }
}

@MainActor private final class OnboardingWindow: NSWindow {
    var performPrimaryAction: (() -> Void)?

    override func sendEvent(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if event.type == .keyDown, [36, 76].contains(event.keyCode), modifiers == .command,
           !(firstResponder is ShortcutButton), !(firstResponder is NSTextView) {
            if !event.isARepeat { performPrimaryAction?() }
        } else {
            super.sendEvent(event)
        }
    }
}

@MainActor final class OnboardingWindowController: NSWindowController {
    init(startup: MacStartup, onFinished: @escaping () -> Void) {
        let window = OnboardingWindow()
        let view = OnboardingView(
            startup: startup,
            onFinished: onFinished,
            onDiscarded: { [weak window] in window?.close() }
        )
        window.performPrimaryAction = { view.performPrimaryAction() }
        window.contentViewController = NSHostingController(rootView: view)
        window.title = "Stash Setup"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 620, height: 560))
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) { nil }
}
