import AppKit
import SwiftUI
import StashCore

final class StashPanel: NSPanel { override var canBecomeKey: Bool { true }; override var canBecomeMain: Bool { false } }

@MainActor final class PanelController: NSObject, NSMenuDelegate {
    unowned let model: AppModel
    let window: StashPanel
    private var statusItem: NSStatusItem?
    private var keyMonitor: Any?
    private var outsideMonitor: Any?
    private var savedResizeHeight: Double?
    var isVisible: Bool { window.isVisible }
    init(model: AppModel) {
        self.model = model
        window = StashPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        window.level = .floating; window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = true; window.hidesOnDeactivate = false; window.isFloatingPanel = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; window.animationBehavior = .none; window.isReleasedWhenClosed = false
        let effect = NSVisualEffectView(); effect.material = .hudWindow; effect.blendingMode = .behindWindow; effect.state = .active
        let hosting = NSHostingView(rootView: PanelView(model: model)); hosting.translatesAutoresizingMaskIntoConstraints = false; effect.addSubview(hosting)
        NSLayoutConstraint.activate([hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor), hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor), hosting.topAnchor.constraint(equalTo: effect.topAnchor), hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor)])
        window.contentView = effect
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in let handled = MainActor.assumeIsolated { self?.handle(event) == nil }; return handled ? nil : event }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in Task { @MainActor in self?.hide() } }
        updateMenu()
    }
    func updateMenu() {
        if !model.settings.showMenuBarIcon { if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }; statusItem = nil; return }
        if statusItem == nil { statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength) }
        let icon = model.settings.isPaused() ? NSImage(systemSymbolName:"pause.rectangle",accessibilityDescription:"Stash paused") : NSImage(named:"StashStatus")
        icon?.isTemplate = true; icon?.size = NSSize(width:18,height:18); statusItem?.button?.image = icon
        statusItem?.button?.toolTip = "Stash — A home for the things you copy."
        let menu = NSMenu(); menu.delegate = self
        func add(_ title: String, _ selector: Selector, key: String = "") { let item = NSMenuItem(title: title, action: selector, keyEquivalent: key); item.target = self; menu.addItem(item) }
        add("Open Stash", #selector(openPanel)); menu.addItem(.separator())
        add(model.settings.isPaused() ? "Resume Capture" : "Pause Until Resumed", #selector(togglePause))
        for (title, minutes) in [("Pause for 15 minutes", 15), ("Pause for 1 hour", 60), ("Pause for 8 hours", 480)] { let item = NSMenuItem(title: title, action: #selector(timedPause(_:)), keyEquivalent: ""); item.tag = minutes; item.target = self; menu.addItem(item) }
        add(model.stack.isActive ? "Stop Paste Stack" : "Start Paste Stack", #selector(toggleStack)); menu.addItem(.separator()); add("Settings…", #selector(settings), key: ","); add("Quit Stash", #selector(quit), key: "q")
        statusItem?.menu = menu
    }
    func menuWillOpen(_ menu: NSMenu) { model.paste.captureMenuDestination() }
    @objc private func openPanel() { show(fromStatusMenu: true) }
    @objc private func togglePause() { model.togglePause() }
    @objc private func timedPause(_ item: NSMenuItem) { model.pause(minutes: item.tag) }
    @objc private func toggleStack() { model.toggleStack(); updateMenu() }
    @objc private func settings() { model.showSettings() }
    @objc private func quit() { NSApp.terminate(nil) }
    func toggle() { if isVisible { hide() } else { show() } }
    func show(fromStatusMenu: Bool = false) {
        model.dismissSuggestions()
        if let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier != Bundle.main.bundleIdentifier { model.paste.previousApp = app }
        model.paste.captureDestinationFromFrontmost(useMenuDestination: fromStatusMenu)
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!
        let bounds = screen.visibleFrame; let height = min(CGFloat(model.settings.panelHeight), bounds.height * 0.8)
        let target = NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: height)
        window.setFrame(target.offsetBy(dx: 0, dy: -height), display: false); window.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.23; context.timingFunction = CAMediaTimingFunction(name: .easeOut); window.animator().setFrame(target, display: true) }
        model.selectFirstIfNeeded()
    }
    func hide() { guard isVisible else { return }; window.orderOut(nil); model.paste.clearDestination(); model.panelDidHide() }
    func resize(translation: CGFloat, ended: Bool) {
        if savedResizeHeight == nil { savedResizeHeight = window.frame.height }
        let maximum = (window.screen?.visibleFrame.height ?? 900) * 0.8
        let height = min(maximum, max(190, (savedResizeHeight ?? 350) + translation))
        var frame = window.frame; frame.size.height = height; window.setFrame(frame, display: true)
        if ended { model.saveSettings { $0.panelHeight = height }; savedResizeHeight = nil }
    }
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard window.isVisible, window.isKeyWindow, NSApp.modalWindow == nil else { return event }
        if Self.handleNewTextShortcut(event, model: model) { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask); let command = flags.contains(.command), shift = flags.contains(.shift)
        let editing = window.firstResponder is NSTextView
        if event.keyCode == 53 { if !model.query.isEmpty || model.searchFocused { model.query = ""; model.searchFocused = false; window.makeFirstResponder(nil) } else { hide() }; return nil }
        if editing {
            if event.keyCode == 36 { model.searchFocused = false; window.makeFirstResponder(nil); model.selectFirstIfNeeded(); return nil }
            if event.keyCode == 48 { model.searchFocused = false; window.makeFirstResponder(nil); return nil }
            if command && event.charactersIgnoringModifiers?.lowercased() == "f" { model.showFilters.toggle(); return nil }
            return event
        }
        if event.keyCode == model.settings.nextBoardShortcut.keyCode && carbonModifiers(flags) == model.settings.nextBoardShortcut.modifiers { model.switchBoard(1); return nil }
        if event.keyCode == model.settings.previousBoardShortcut.keyCode && carbonModifiers(flags) == model.settings.previousBoardShortcut.modifiers { model.switchBoard(-1); return nil }
        let quick: Bool = model.settings.quickPasteModifier == "option" ? flags.contains(.option) : model.settings.quickPasteModifier == "control" ? flags.contains(.control) : command
        if quick, let number = Int(event.charactersIgnoringModifiers ?? ""), number >= 1, number <= min(9, model.visible.count) { model.paste.paste([model.visible[number - 1]], plain: plainModifier(flags)); return nil }
        if command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "a": model.selection = Set(model.visible.map(\.id))
            case "c": if shift { model.toggleStack() } else { _ = model.paste.copy(model.selected); model.message("Copied") }
            case "f": if model.searchFocused { model.showFilters.toggle() }; model.searchFocused = true
            case "g": model.revealSelected()
            case "o": model.openSelected()
            case "r": model.rename()
            case "e": model.edit()
            case "n": if shift { model.newBoard() } else { model.newText() }
            case "z": model.perform { try model.store.undo() }
            case "t": model.togglePause()
            case ",": model.showSettings()
            case "q": NSApp.terminate(nil)
            default: if event.keyCode == 126, let first = model.visible.first { model.selection = [first.id]; model.anchor = first.id } else if event.keyCode == 125, let last = model.visible.last { model.selection = [last.id]; model.anchor = last.id } else { return event }
            }; return nil
        }
        switch event.keyCode {
        case 123: model.move(-1, extending: shift)
        case 124: model.move(1, extending: shift)
        case 36, 76: model.paste.paste(plain: plainModifier(flags))
        case 49: if let item = model.selected.first { PreviewWindow.open(item: item, model: model) }
        case 51, 117: model.deleteSelection()
        case 48: model.searchFocused = true
        default: if let chars = event.characters, chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }), !flags.contains(.control), !flags.contains(.option) { model.query += chars; model.searchFocused = true } else { return event }
        }
        return nil
    }
    static func handleNewTextShortcut(_ event: NSEvent, model: AppModel) -> Bool {
        let intent = event.modifierFlags.intersection([.command, .shift, .control, .option])
        guard intent == .command, event.charactersIgnoringModifiers?.lowercased() == "n" else { return false }
        model.newText()
        return true
    }
    private func plainModifier(_ flags: NSEvent.ModifierFlags) -> Bool { switch model.settings.plainTextModifier { case "option": flags.contains(.option); case "control": flags.contains(.control); default: flags.contains(.shift) } }
    private func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 { (flags.contains(.command) ? 256 : 0) | (flags.contains(.shift) ? 512 : 0) | (flags.contains(.option) ? 2048 : 0) | (flags.contains(.control) ? 4096 : 0) }
}
import QuartzCore
