import SwiftUI
import AppKit
import ServiceManagement
import StashCore
import UniformTypeIdentifiers

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var section = "General"
    @State private var ignoredApp = ""
    @State private var restartRequired = false
    @State private var commerce = Commerce()
    private let sections = ["General", "Shortcuts", "Privacy", "Sync", "Intelligence", "Pinboards", "About"]
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                StashWordmark(size:24).padding(.bottom, 18)
                ForEach(sections, id: \.self) { name in Button { section = name } label: { Text(name).frame(maxWidth: .infinity, alignment: .leading).padding(9).background(section == name ? .teal.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 8)) }.buttonStyle(.plain) }
                Spacer()
            }.padding(20).frame(width: 160).background(.quaternary.opacity(0.3))
            ScrollView { VStack(alignment: .leading, spacing: 20) {
                Text(section).font(.title.bold())
                if !model.settings.onboardingComplete { onboarding }
                switch section {
                case "General": general
                case "Shortcuts": shortcuts
                case "Privacy": privacy
                case "Sync": sync
                case "Intelligence": intelligence
                case "Pinboards": boards
                default: about
                }
                if let toast = model.toast { Text(toast).font(.callout).foregroundStyle(.teal) }
            }.padding(28).frame(maxWidth: .infinity, alignment: .leading) }
        }.frame(minWidth: 750, minHeight: 540).tint(StashBrand.accent)
    }
    private func binding<T>(_ keyPath: WritableKeyPath<LibrarySettings,T>) -> Binding<T> { Binding(get: { model.settings[keyPath: keyPath] }, set: { value in model.saveSettings { $0[keyPath: keyPath] = value } }) }
    private var onboarding: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("Your clipboard, with a little more room.").font(.headline)
                Text("Open Stash with ⇧⌘V or the menu bar. Choose how long to keep your history below. Accessibility lets Stash paste into your previous app; without it, items are copied for you.").foregroundStyle(.secondary)
                HStack { Button("Allow Direct Pasting") { model.paste.requestAccessibility() }; Button("Start using Stash") { model.saveSettings { $0.onboardingComplete = true }; model.settingsWindow?.close(); model.panel?.show() }.buttonStyle(.borderedProminent) }
            }.padding(8)
        }
    }
    private var general: some View {
        VStack(alignment: .leading, spacing: 18) {
            Toggle("Launch at login", isOn: Binding(get: { SMAppService.mainApp.status == .enabled }, set: { enabled in model.perform { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } }))
            Toggle("Run in the background when windows close", isOn: binding(\.runInBackground))
            Toggle("Show menu bar icon", isOn: Binding(get: { model.settings.showMenuBarIcon }, set: { value in model.saveSettings { $0.showMenuBarIcon = value }; if !value { model.message("Use your shortcut to open Stash.") } }))
            Picker("Keep history", selection: Binding(get: { model.settings.retentionDays ?? 0 }, set: { days in changeRetention(days) })) { Text("1 Day").tag(1); Text("1 Week").tag(7); Text("1 Month").tag(30); Text("1 Year").tag(365); Text("Forever").tag(0) }.frame(maxWidth: 300)
            Text("Pinned items stay until you remove them. There is no item-count limit.").font(.caption).foregroundStyle(.secondary)
            Divider(); HStack { Button("Export Library…", action: exportLibrary); Button("Import Library…", action: importLibrary) }
            Text("Exports contain clipboard content, images and file references. Store your backup somewhere private. File references do not back up the original files.").font(.caption).foregroundStyle(.secondary)
            Button("Erase History…", role: .destructive) { if confirm("Erase clipboard history?", message: "Pinboards are kept. This action cannot be undone.", button: "Erase History") { model.perform { try model.store.eraseHistory() } } }
        }
    }
    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Click a shortcut and press a new key combination.").foregroundStyle(.secondary)
            ShortcutRecorder(title: "Show / hide", value: binding(\.panelShortcut))
            ShortcutRecorder(title: "Paste Stack", value: binding(\.stackShortcut))
            ShortcutRecorder(title: "Next pinboard", value: binding(\.nextBoardShortcut))
            ShortcutRecorder(title: "Previous pinboard", value: binding(\.previousBoardShortcut))
            Picker("Quick Paste modifier", selection: binding(\.quickPasteModifier)) { Text("⌘ Command").tag("command"); Text("⌥ Option").tag("option"); Text("⌃ Control").tag("control") }
            Picker("Plain text modifier", selection: binding(\.plainTextModifier)) { Text("⇧ Shift").tag("shift"); Text("⌥ Option").tag("option"); Text("⌃ Control").tag("control") }
            Button("Reset shortcuts") { let defaults = LibrarySettings(); model.saveSettings { $0.panelShortcut = defaults.panelShortcut; $0.stackShortcut = defaults.stackShortcut; $0.nextBoardShortcut = defaults.nextBoardShortcut; $0.previousBoardShortcut = defaults.previousBoardShortcut; $0.quickPasteModifier = defaults.quickPasteModifier; $0.plainTextModifier = defaults.plainTextModifier } }
            Text("Arrows navigate · ⇧Arrows extend selection · ⌘A selects all · Return pastes · Space previews · ⌘O opens · ⌘R renames · ⌘E edits · ⌘N creates text · Delete removes · ⌘Z undoes deletion or pinning · ⌘F searches · Tab switches search/results · ⌘G shows the item's location · ⌘T pauses capture.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var privacy: some View {
        VStack(alignment: .leading, spacing: 15) {
            Toggle("Ignore confidential clipboard content", isOn: binding(\.ignoreConfidential))
            Toggle("Ignore transient and auto-generated content", isOn: binding(\.ignoreTransient))
            Text("Ignore Applications").font(.headline)
            Text("Excluding an app blocks new copies. Existing items are kept.").font(.caption).foregroundStyle(.secondary)
            ForEach(model.settings.ignoredApplications, id: \.self) { id in HStack { Text(NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)?.deletingPathExtension().lastPathComponent ?? id).lineLimit(1); Spacer(); Button { model.saveSettings { $0.ignoredApplications.removeAll { $0 == id } } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain) } }
            Button("Add Application…") { let panel = NSOpenPanel(); panel.directoryURL = URL(fileURLWithPath: "/Applications"); panel.allowedContentTypes = [.application]; if panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier { model.saveSettings { if !$0.ignoredApplications.contains(id) { $0.ignoredApplications.append(id) } } } }
            HStack { TextField("Bundle ID", text: $ignoredApp); Button("Add") { let id = ignoredApp.trimmingCharacters(in: .whitespacesAndNewlines); if !id.isEmpty { model.saveSettings { if !$0.ignoredApplications.contains(id) { $0.ignoredApplications.append(id) } }; ignoredApp = "" } } }
            Divider(); Button(model.paste.hasAccessibility ? "Direct pasting is allowed" : "Allow Accessibility for direct pasting") { model.paste.requestAccessibility() }
            Text("Stash has no analytics or custom server. Link previews contact the copied website. Clipboard data stays on your devices and, if enabled, in your private iCloud account.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var sync: some View {
        VStack(alignment: .leading, spacing: 18) {
            Toggle("Sync with my iCloud account", isOn: Binding(get: { model.settings.syncEnabled }, set: { value in model.saveSettings { $0.syncEnabled = value }; restartRequired = true }))
            Label(model.store.syncStatus, systemImage: "icloud")
            Text("Use the same Apple Account on your Mac, iPhone and iPad. Stash uses private iCloud storage. A shared pinboard includes only items pinned to that board.").foregroundStyle(.secondary)
            if restartRequired { Text("Quit and reopen Stash to apply the sync setting.").foregroundStyle(.orange) }
            Button("Refresh local view") { model.perform { try model.store.reload() } }
        }
    }
    private var intelligence: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Enable on-device Suggestions", isOn: binding(\.suggestionsEnabled))
            Text("Requires macOS 26 and Apple Intelligence. Suggestions reads the active app's visible window only while the clipboard panel is open. Context is not saved. Ignored apps and detected password fields are excluded.").font(.callout).foregroundStyle(.secondary)
            Button("Allow Screen Recording…") { let alert = NSAlert(); alert.messageText = "Allow Stash to read your active window?"; alert.informativeText = "This is used only when you request Suggestions. Nothing from the screen is saved."; alert.addButton(withTitle: "Continue"); alert.addButton(withTitle: "Cancel"); if alert.runModal() == .alertFirstButtonReturn { _ = CGRequestScreenCaptureAccess() } }
            Divider(); Text("MCP & AI Tools").font(.headline)
            Toggle("Enable local MCP server", isOn: Binding(get: { model.settings.mcpEnabled }, set: { enabled in model.saveSettings { $0.mcpEnabled = enabled }; if enabled { model.startMCP() } else { model.mcp?.stop(); model.mcp = nil } }))
            Button("Connect AI Tool…") { MCPSetupWindow.open() }
            Text("Clients need your approval and a private token. You choose whether each client can read history, read pinboards or write items.").font(.caption).foregroundStyle(.secondary)
            if let server = model.mcp { ForEach(server.clients) { client in HStack { VStack(alignment: .leading) { Text(client.name); Text(client.scopes.map(\.rawValue).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("Remove access") { server.revoke(client.id) } } } }
        }
    }
    private var boards: some View { VStack(alignment: .leading, spacing: 14) { ForEach(model.store.pinboards) { board in HStack { Circle().fill(Color(hex: board.colorHex)).frame(width: 10,height: 10); Text(board.name); Spacer(); Button("Share…") { model.shareBoard(board.id) } } }; Button("New Pinboard…", action: model.newBoard) } }
    private var about: some View {
        VStack(alignment: .leading, spacing: 14) { StashAppBadge(size:88); Text("Stash 0.1").font(.title2.bold()); Text("A home for the things you copy.").foregroundStyle(.secondary); Text("Built with Apple's native frameworks. Your library belongs to you.")
            if Commerce.enabled { ForEach(commerce.products, id: \.id) { product in Button(product.displayName + " · " + product.displayPrice) { Task { await commerce.purchase(product) } } }; Button("Restore Purchases") { Task { await commerce.restore() } }; Text(commerce.status) }
        }.task { await commerce.load() }
    }
    private func changeRetention(_ days: Int) {
        let shorter = days != 0 && (model.settings.retentionDays == nil || days < model.settings.retentionDays!)
        let expired = model.store.items.contains { $0.pinboardID == nil && Retention.action(for: $0, days: days, now: .now) == .delete }
        if shorter && expired && !confirm("Delete older history?", message: "Items older than the new limit will be permanently deleted. Pinboards are kept.", button: "Delete Older Items") { return }
        model.saveSettings { $0.retentionDays = days == 0 ? nil : days }; model.perform { try model.store.applyRetention() }
    }
    private func confirm(_ title: String, message: String, button: String) -> Bool { let alert = NSAlert(); alert.messageText = title; alert.informativeText = message; alert.addButton(withTitle: button); alert.addButton(withTitle: "Cancel"); return alert.runModal() == .alertFirstButtonReturn }
    private func exportLibrary() { let panel = NSSavePanel(); panel.nameFieldStringValue = "Stash-backup.stasharchive"; if panel.runModal() == .OK, let url = panel.url { model.perform { try model.store.archive().write(to: url, options: .atomic) } } }
    private func importLibrary() { let panel = NSOpenPanel(); if panel.runModal() == .OK, let url = panel.url { model.perform { let data = try Data(contentsOf: url); try model.store.importArchive(data); model.message("Library imported") } } }
}

struct ShortcutRecorder: NSViewRepresentable {
    let title: String
    @Binding var value: KeyBinding
    func makeNSView(context: Context) -> ShortcutButton { let button = ShortcutButton(); button.onChange = { value = $0 }; return button }
    func updateNSView(_ button: ShortcutButton, context: Context) { button.onChange = { value = $0 }; button.title = title + "    " + button.label(for: value) }
}
final class ShortcutButton: NSButton {
    var onChange: ((KeyBinding) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override init(frame: NSRect) { super.init(frame: frame); target = self; action = #selector(begin); bezelStyle = .rounded }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc func begin() { window?.makeFirstResponder(self); title = "Press a shortcut… (Esc to cancel)" }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { window?.makeFirstResponder(nil); return }
        let flags = event.modifierFlags; guard !flags.intersection([.command,.option,.control]).isEmpty else { return }
        let modifiers: UInt32 = (flags.contains(.command) ? 256 : 0) | (flags.contains(.shift) ? 512 : 0) | (flags.contains(.option) ? 2048 : 0) | (flags.contains(.control) ? 4096 : 0)
        onChange?(KeyBinding(keyCode: UInt32(event.keyCode), modifiers: modifiers)); window?.makeFirstResponder(nil)
    }
    func label(for value: KeyBinding) -> String { let flags = (value.modifiers & 4096 != 0 ? "⌃" : "") + (value.modifiers & 2048 != 0 ? "⌥" : "") + (value.modifiers & 512 != 0 ? "⇧" : "") + (value.modifiers & 256 != 0 ? "⌘" : ""); let keys: [UInt32:String] = [9:"V",8:"C",123:"←",124:"→",49:"Space",36:"Return"]; return flags + (keys[value.keyCode] ?? "Key \(value.keyCode)") }
}
