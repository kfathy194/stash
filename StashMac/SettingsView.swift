import SwiftUI
import Carbon
import AppKit
import ServiceManagement
import StashCore
import UniformTypeIdentifiers

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var restartRequired = false
    @State private var importingPasteBar = false
    @State private var commerce = Commerce()
    private let sections = ["General", "Shortcuts", "Privacy", "Sync", "Intelligence", "Pinboards", "About"]
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                StashWordmark(size:24).padding(.bottom, 18)
                ForEach(sections, id: \.self) { name in Button { model.settingsSection = name } label: { Text(name).frame(maxWidth: .infinity, alignment: .leading).padding(9).background(model.settingsSection == name ? .teal.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 8)) }.buttonStyle(.plain) }
                Spacer()
            }.padding(20).frame(width: 160).background(.quaternary.opacity(0.3))
            ScrollView { VStack(alignment: .leading, spacing: 20) {
                Text(model.settingsSection).font(.title.bold())
                switch model.settingsSection {
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
    private var general: some View {
        VStack(alignment: .leading, spacing: 18) {
            Toggle("Launch at login", isOn: Binding(get: { SMAppService.mainApp.status == .enabled }, set: { enabled in model.perform { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } }))
            Toggle("Run in the background when windows close", isOn: binding(\.runInBackground))
            Toggle("Show menu bar icon", isOn: Binding(
                get: { model.settings.showMenuBarIcon || model.requiresMenuBarAccess },
                set: { value in
                    guard !model.requiresMenuBarAccess else { return }
                    model.saveSettings { $0.showMenuBarIcon = value }
                    if !value { model.message("Use your shortcut to open Stash.") }
                }
            ))
            .disabled(model.requiresMenuBarAccess)
            if model.requiresMenuBarAccess {
                Text("Stash stays in the menu bar when a shortcut to open Stash or start Paste Stack is unavailable.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HistoryRetentionSettings(store: model.store, saveSettings: model.saveSettings, reportError: model.message)
            if let openSetupWizard = model.openSetupWizard { Button("Setup Wizard…", action: openSetupWizard) }
            Divider(); HStack { Button("Export Library…", action: exportLibrary); Button("Import Library…", action: importLibrary) }
            Button(importingPasteBar ? "Importing PasteBar…" : "Migrate from PasteBar…", action: migrateFromPasteBar).disabled(importingPasteBar)
            Text("Choose a PasteBar backup ZIP. History starts from today; saved clips keep their dates and are organized on pinboards. Existing Stash items and preferences are preserved.").font(.caption).foregroundStyle(.secondary)
            Text("Exports contain clipboard content, images and file references. Store your backup somewhere private. File references do not back up the original files.").font(.caption).foregroundStyle(.secondary)
            Button("Erase History…", role: .destructive) { if confirm("Erase clipboard history?", message: "Pinboards are kept. This action cannot be undone.", button: "Erase History") { model.perform { try model.store.eraseHistory() } } }
        }
    }
    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Click a shortcut and press a new key combination.").foregroundStyle(.secondary)
            globalShortcut(.panel, key: \.panelShortcut, disabled: \.panelShortcutDisabled)
            globalShortcut(.stack, key: \.stackShortcut, disabled: \.stackShortcutDisabled)
            ShortcutRecorder(title: "Next pinboard", value: binding(\.nextBoardShortcut))
            ShortcutRecorder(title: "Previous pinboard", value: binding(\.previousBoardShortcut))
            Picker("Quick Paste modifier", selection: binding(\.quickPasteModifier)) { Text("⌘ Command").tag("command"); Text("⌥ Option").tag("option"); Text("⌃ Control").tag("control") }
            Picker("Plain text modifier", selection: binding(\.plainTextModifier)) { Text("⇧ Shift").tag("shift"); Text("⌥ Option").tag("option"); Text("⌃ Control").tag("control") }
            Button("Reset shortcuts") { let defaults = LibrarySettings(); model.saveSettings { $0.panelShortcut = defaults.panelShortcut; $0.stackShortcut = defaults.stackShortcut; $0.panelShortcutDisabled = nil; $0.stackShortcutDisabled = nil; $0.nextBoardShortcut = defaults.nextBoardShortcut; $0.previousBoardShortcut = defaults.previousBoardShortcut; $0.quickPasteModifier = defaults.quickPasteModifier; $0.plainTextModifier = defaults.plainTextModifier } }
            Text("Arrows navigate · ⇧Arrows extend selection · ⌘A selects all · Return pastes · Space previews · ⌘O opens · ⌘R renames · ⌘E edits · ⌘N creates text · Delete removes · ⌘Z undoes deletion or pinning · ⌘F searches · Tab switches search/results · ⌘G shows the item's location · ⌘T pauses capture.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func globalShortcut(
        _ slot: DailyUseShortcut,
        key: WritableKeyPath<LibrarySettings, KeyBinding>,
        disabled: WritableKeyPath<LibrarySettings, Bool?>
    ) -> some View {
        HStack {
            ShortcutRecorder(title: slot.name, value: Binding<KeyBinding?>(
                get: { model.settings[keyPath: disabled] == true ? nil : model.settings[keyPath: key] },
                set: { value in
                    model.saveSettings {
                        if let value { $0[keyPath: key] = value }
                        $0[keyPath: disabled] = value == nil ? true : nil
                    }
                }
            ))
            if model.settings[keyPath: disabled] != true {
                Button("Disable " + slot.name + " shortcut") {
                    model.saveSettings { $0[keyPath: disabled] = true }
                }
                if model.hotkeys?.isRegistered(slot) == false {
                    Text("Unavailable").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var privacy: some View {
        VStack(alignment: .leading, spacing: 15) {
            Toggle("Ignore confidential clipboard content", isOn: binding(\.ignoreConfidential))
            Toggle("Ignore transient and auto-generated content", isOn: binding(\.ignoreTransient))
            ExcludedApplicationsSettings(applications: binding(\.ignoredApplications))
            Divider()
            Button(model.paste?.hasAccessibility == true ? "Direct pasting is allowed" : "Allow Accessibility for direct pasting") {
                model.paste?.requestAccessibility()
            }
            Text("Stash has no analytics or custom server. Link previews contact the copied website. Clipboard data stays on your devices and, if enabled, in your private iCloud account.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private var sync: some View {
        VStack(alignment: .leading, spacing: 18) {
            if AppModel.cloudKitAvailable {
                Toggle("Sync with my iCloud account", isOn: Binding(get: { model.settings.syncEnabled }, set: { value in model.saveSettings { $0.syncEnabled = value }; restartRequired = true }))
                Label(model.store.syncStatus, systemImage: "icloud")
                Text("Use the same Apple Account on your Mac, iPhone and iPad. Stash uses private iCloud storage. A shared pinboard includes only items pinned to that board.").foregroundStyle(.secondary)
                if restartRequired { Text("Quit and reopen Stash to apply the sync setting.").foregroundStyle(.orange) }
            } else {
                Text("iCloud sync and sharing are unavailable in this development build. Your library stays on this Mac.").foregroundStyle(.secondary)
            }
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
        VStack(alignment: .leading, spacing: 14) { StashAppBadge(size:88); Text("Stash").font(.title2.bold()); Text(AppVersion.displayString(bundle: .main)).textSelection(.enabled).foregroundStyle(.secondary); Text("A home for the things you copy.").foregroundStyle(.secondary); Text("Built with Apple's native frameworks. Your library belongs to you.")
            if Commerce.enabled { ForEach(commerce.products, id: \.id) { product in Button(product.displayName + " · " + product.displayPrice) { Task { await commerce.purchase(product) } } }; Button("Restore Purchases") { Task { await commerce.restore() } }; Text(commerce.status) }
        }.task { await commerce.load() }
    }
    private func confirm(_ title: String, message: String, button: String) -> Bool { let alert = NSAlert(); alert.messageText = title; alert.informativeText = message; alert.addButton(withTitle: button); alert.addButton(withTitle: "Cancel"); return alert.runModal() == .alertFirstButtonReturn }
    private func exportLibrary() { let panel = NSSavePanel(); panel.nameFieldStringValue = "Stash-backup.stasharchive"; if panel.runModal() == .OK, let url = panel.url { model.perform { try model.store.archive().write(to: url, options: .atomic) } } }
    private func importLibrary() { let panel = NSOpenPanel(); if panel.runModal() == .OK, let url = panel.url { model.perform { let data = try Data(contentsOf: url); try model.store.importArchive(data); model.message("Library imported") } } }
    private func migrateFromPasteBar() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]; panel.allowsMultipleSelection = false
        panel.message = "Choose the ZIP created by PasteBar's Backup and Restore settings."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importingPasteBar = true
        Task {
            defer { importingPasteBar = false }
            do {
                let result = try await model.store.importPasteBarBackup(from: url)
                let alert = NSAlert()
                alert.messageText = "PasteBar migration complete"
                alert.informativeText = result.message
                alert.runModal()
            } catch { model.message(error.localizedDescription) }
        }
    }

}

struct ExcludedApplicationsSettings: View {
    @Binding var applications: [String]
    @State private var ignoredApp = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Ignore Applications").font(.headline)
            Text("Excluding an app blocks new copies. Existing items are kept.").font(.caption).foregroundStyle(.secondary)
            ForEach(applications, id: \.self) { id in
                let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)?.deletingPathExtension().lastPathComponent ?? id
                HStack {
                    Text(name).lineLimit(1)
                    Spacer()
                    Button { applications.removeAll { $0 == id } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Stop excluding \(name)")
                }
            }
            Button("Add Application…", action: chooseApplication)
            HStack {
                TextField("Bundle ID", text: $ignoredApp)
                Button("Add") {
                    add(ignoredApp.trimmingCharacters(in: .whitespacesAndNewlines))
                    ignoredApp = ""
                }
            }
        }
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        if panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier { add(id) }
    }

    private func add(_ id: String) {
        guard !id.isEmpty, !applications.contains(id) else { return }
        applications.append(id)
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    let title: String
    @Binding var value: KeyBinding?

    init(title: String, value: Binding<KeyBinding?>) {
        self.title = title
        self._value = value
    }

    init(title: String, value: Binding<KeyBinding>) {
        self.init(title: title, value: Binding<KeyBinding?>(
            get: { value.wrappedValue },
            set: { if let binding = $0 { value.wrappedValue = binding } }
        ))
    }

    func makeNSView(context: Context) -> ShortcutButton { ShortcutButton() }

    func updateNSView(_ button: ShortcutButton, context: Context) {
        button.onChange = { value = $0 }
        button.shortcutTitle = title + "    " + (value.map(shortcutLabel) ?? "No shortcut")
        button.setAccessibilityLabel(button.shortcutTitle)
    }
}

func shortcutLabel(_ value: KeyBinding) -> String {
    let flags = (value.modifiers & 4096 != 0 ? "⌃" : "") + (value.modifiers & 2048 != 0 ? "⌥" : "")
        + (value.modifiers & 512 != 0 ? "⇧" : "") + (value.modifiers & 256 != 0 ? "⌘" : "")
    let special: [UInt32: String] = [
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 123: "←", 124: "→", 125: "↓", 126: "↑"
    ]
    return flags + (special[value.keyCode] ?? keyboardLayoutLabel(value.keyCode) ?? "Key \(value.keyCode)")
}

private func keyboardLayoutLabel(_ code: UInt32) -> String? {
    guard let keyCode = UInt16(exactly: code),
          let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
          let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
    let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
    guard let bytes = CFDataGetBytePtr(data) else { return nil }
    var deadKeyState: UInt32 = 0
    var length = 0
    var characters = [UniChar](repeating: 0, count: 8)
    let status = withExtendedLifetime(data) {
        bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
            UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                           OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState, characters.count, &length, &characters)
        }
    }
    guard status == noErr, length > 0 else { return nil }
    let result = String(utf16CodeUnits: characters, count: length)
    guard result.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
    return result.uppercased()
}

final class ShortcutButton: NSButton {
    var onChange: ((KeyBinding) -> Void)?
    var shortcutTitle = "" {
        didSet { if !recording { title = shortcutTitle } }
    }
    private var recording = false

    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        target = self
        action = #selector(begin)
        bezelStyle = .rounded
    }

    required init?(coder: NSCoder) { nil }

    @objc func begin() {
        window?.makeFirstResponder(self)
        recording = true
        title = "Press a shortcut… (Esc to cancel)"
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        title = shortcutTitle
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { window?.makeFirstResponder(nil); return }
        let flags = event.modifierFlags
        guard !flags.intersection([.command, .option, .control]).isEmpty else { return }
        let modifiers: UInt32 = (flags.contains(.command) ? 256 : 0) | (flags.contains(.shift) ? 512 : 0)
            | (flags.contains(.option) ? 2048 : 0) | (flags.contains(.control) ? 4096 : 0)
        onChange?(KeyBinding(keyCode: UInt32(event.keyCode), modifiers: modifiers))
        window?.makeFirstResponder(nil)
    }
}
