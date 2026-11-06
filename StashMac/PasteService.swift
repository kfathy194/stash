import AppKit
import ApplicationServices
import StashCore

/// Transient paste target: the destination app plus its focused window and element, captured
/// while that app still owns focus. Never persisted, logged or synced. Delivery re-verifies this
/// exact target immediately before ⌘V is sent, so paste never injects on app identity alone.
@MainActor struct PasteDestination {
    let app: NSRunningApplication
    let window: AXUIElement?
    let element: AXUIElement
}

@MainActor final class PasteService {
    struct NativeAccess {
        var activationCenter = NSWorkspace.shared.notificationCenter
        var runningApplication: @MainActor (pid_t) -> NSRunningApplication? = { NSRunningApplication(processIdentifier: $0) }
        var frontmostApplication: @MainActor () -> NSRunningApplication? = { NSWorkspace.shared.frontmostApplication }
        var ownBundleID = Bundle.main.bundleIdentifier
        var capture: @MainActor (NSRunningApplication) -> PasteDestination? = captureDestination
    }
    unowned let model: AppModel
    var previousApp: NSRunningApplication? {
        didSet { if previousApp?.processIdentifier != oldValue?.processIdentifier { model.dismissSuggestions() } }
    }
    private(set) var destination: PasteDestination?
    private var eventTap: CFMachPort?
    private var eventSource: CFRunLoopSource?
    private var lastClickActivation: (ids: [UUID], date: Date)?
    private let delivery = PasteDelivery()
    private var menuDestination: PasteDestination?
    private var activationObserver: PasteActivationObservation?
    private let native: NativeAccess
    init(model: AppModel, native: NativeAccess = NativeAccess()) {
        self.model = model
        self.native = native
        // Suggestions retains the previous app identity; paste destinations are captured
        // only at their shortcut/menu entry point, never by unrelated app switches.
        let token = native.activationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier else { return }
            MainActor.assumeIsolated {
                guard let self, let app = self.native.runningApplication(pid), app.bundleIdentifier != self.native.ownBundleID,
                      self.native.frontmostApplication()?.processIdentifier == pid else { return }
                // Refocusing the same app can select a different window or field.
                self.model.dismissSuggestions()
                self.previousApp = app
            }
        }
        activationObserver = PasteActivationObservation(center: native.activationCenter, token: token)
    }
    var hasAccessibility: Bool { AXIsProcessTrusted() }
    func requestAccessibility() { _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) }
    /// Status-menu tracking begins before showing the panel. A Stash-owned current
    /// workflow has no external destination; never reuse an older app's field.
    func captureMenuDestination() { menuDestination = frontmostDestination() }
    func captureDestinationFromFrontmost(useMenuDestination: Bool = false) {
        delivery.cancel()
        destination = useMenuDestination ? menuDestination : frontmostDestination()
        menuDestination = nil
    }
    private func frontmostDestination() -> PasteDestination? {
        guard let app = native.frontmostApplication(), app.bundleIdentifier != native.ownBundleID else { return nil }
        previousApp = app
        return native.capture(app)
    }
    func clearDestination() { destination = nil; menuDestination = nil; delivery.cancel() }
    @discardableResult func copy(_ items: [ClipItem], plain: Bool = false) -> Bool { prepareCopy(items, plain: plain) != nil }
    private func prepareCopy(_ items: [ClipItem], plain: Bool) -> Int? {
        delivery.cancel()
        do {
            let values = try items.map { try model.store.materialized($0) }; guard !values.isEmpty else { return nil }
            let board = NSPasteboard.general
            var writers: [NSPasteboardWriting] = []
            if plain || (values.count > 1 && values.allSatisfy { [.text, .richText, .code, .color, .link].contains($0.kind) }) {
                let combined = NSPasteboardItem(); combined.setString(values.map(\.text).joined(separator: "\n"), forType: .string); writers = [combined]
            } else {
                for item in values {
                    if item.kind == .file {
                        for writer in try FileAssets.pasteboardWriters(for: item, directory: LibraryStore.defaultDirectory()) {
                            let url = writer as URL
                            let accessed = url.startAccessingSecurityScopedResource()
                            if accessed { Task { try? await Task.sleep(for: .seconds(15)); url.stopAccessingSecurityScopedResource() } }
                            writers.append(writer)
                        }
                    } else {
                        let writer = Self.textPasteboardItem(for: item)
                        if item.kind == .image, let data = item.data, let image = NSImage(data: data), let tiff = image.tiffRepresentation { writer.setData(tiff, forType: .tiff) }
                        writers.append(writer)
                    }
                }
            }
            guard !writers.isEmpty else { return nil }
            // clearContents returns the ownership revision; later writers must never become ours.
            let revision = board.clearContents()
            let written = board.writeObjects(writers)
            model.capture.suppressCurrentChange()
            guard written, board.changeCount == revision else { model.message("Clipboard changed or could not be prepared. Choose the item again."); return nil }
            return revision
        } catch { model.message(error.localizedDescription); return nil }
    }
    static func textPasteboardItem(for item: ClipItem) -> NSPasteboardItem {
        let writer = NSPasteboardItem()
        writer.setString(item.text, forType: .string)
        if item.kind != .code, let rich = item.richData { writer.setData(rich, forType: .rtf) }
        if item.kind == .link { writer.setString(item.text, forType: .URL) }
        return writer
    }

    func paste(_ items: [ClipItem]? = nil, plain: Bool = false, clickActivation: Bool = false) {
        let values = items ?? model.selected
        if clickActivation, isDoubleClickRepeat(values) { return }
        guard let preparedCount = prepareCopy(values, plain: plain) else { return }
        guard hasAccessibility, let target = destination, !target.app.isTerminated else { manualPasteFallback(preparedCount: preparedCount); return }
        model.panel?.hide()
        let request = delivery.prepare()
        Task {
            await delivery.deliver(generation: request, activate: { target.app.activate(options: []) },
                isFrontmost: { NSWorkspace.shared.frontmostApplication?.processIdentifier == target.app.processIdentifier },
                isFocused: { self.hasAccessibility && !target.app.isTerminated && Self.isSameTarget(target) },
                restoreFocus: { AXUIElementSetAttributeValue(target.element, kAXFocusedAttribute as CFString, kCFBooleanTrue) },
                clipboardIsCurrent: { NSPasteboard.general.changeCount == preparedCount },
                post: {
                    guard let source = CGEventSource(stateID: .combinedSessionState),
                          let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
                          let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return false }
                    down.flags = .maskCommand; up.flags = .maskCommand
                    down.setIntegerValueField(.eventSourceUserData, value: 0x53544153); up.setIntegerValueField(.eventSourceUserData, value: 0x53544153)
                    // No await separates these final checks from posting. Never type based on PID alone.
                    guard self.hasAccessibility, Self.isSameTarget(target), NSPasteboard.general.changeCount == preparedCount,
                          NSWorkspace.shared.frontmostApplication?.processIdentifier == target.app.processIdentifier else { return false }
                    down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
                    return true
                }, feedback: { failure in
                    self.deliveryFeedback(target.app, clipboardIsCurrent: failure != .clipboardChanged && NSPasteboard.general.changeCount == preparedCount)
                })
        }
    }
    /// A second click on the same item within the system double-click interval is a multi-click,
    /// not a new activation, so it must not insert again.
    private func isDoubleClickRepeat(_ values: [ClipItem]) -> Bool {
        let ids = values.map(\.id); let now = Date()
        defer { lastClickActivation = (ids, now) }
        guard let last = lastClickActivation else { return false }
        return last.ids == ids && now.timeIntervalSince(last.date) < NSEvent.doubleClickInterval
    }
    /// Alerts stay visible after the panel closes and explain every fallback, including repeats.
    private func manualPasteFallback(preparedCount: Int) {
        guard NSPasteboard.general.changeCount == preparedCount else { deliveryFeedback(previousApp, clipboardIsCurrent: false); return }
        let alert = NSAlert(); alert.messageText = "Ready on your clipboard"
        alert.informativeText = hasAccessibility ? "Stash could not confirm your previous editable field, so nothing was typed. Switch to your app and press ⌘V." : "Press ⌘V in your app to paste it. Allow Accessibility in Stash Settings to paste directly next time."
        alert.runModal()
    }
    private func deliveryFeedback(_ app: NSRunningApplication?, clipboardIsCurrent: Bool) {
        let alert = NSAlert()
        alert.messageText = clipboardIsCurrent ? "Copied — paste it with ⌘V" : "Clipboard changed — paste cancelled"
        alert.informativeText = clipboardIsCurrent ? "Stash could not restore where you were working in \(app?.localizedName ?? "your previous app"), so nothing was inserted automatically. Switch to your app and press ⌘V." : "Another copy replaced the item before Stash could paste it. Nothing was inserted automatically. Open Stash and choose the item again."
        alert.runModal()
    }
    private static func captureDestination(of app: NSRunningApplication) -> PasteDestination? {
        guard AXIsProcessTrusted(), !app.isTerminated, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let remote = AXUIElementCreateApplication(app.processIdentifier)
        let window = focusedElement(remote, attribute: kAXFocusedWindowAttribute)
        guard let element = focusedElement(remote, attribute: kAXFocusedUIElementAttribute), isEditable(element, bundleID: app.bundleIdentifier, hasFocusedWindow: window != nil) else { return nil }
        return PasteDestination(app: app, window: window, element: element)
    }
    struct DestinationAccess {
        var settable: (AXUIElement, CFString, UnsafeMutablePointer<DarwinBoolean>) -> AXError = AXUIElementIsAttributeSettable
        var copyValue: (AXUIElement, CFString, UnsafeMutablePointer<CFTypeRef?>) -> AXError = AXUIElementCopyAttributeValue
    }
    static func isEditable(_ element: AXUIElement, bundleID: String?, hasFocusedWindow: Bool, native: DestinationAccess = DestinationAccess()) -> Bool {
        var settable = DarwinBoolean(false)
        if native.settable(element, kAXSelectedTextAttribute as CFString, &settable) == .success, settable.boolValue { return true }
        var role: CFTypeRef?
        guard native.copyValue(element, kAXRoleAttribute as CFString, &role) == .success,
              let name = role as? String, [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(name) else { return false }
        if native.settable(element, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue { return true }
        // Terminal accepts keyboard paste in its session without exposing writable text/value attributes.
        guard bundleID == "com.apple.Terminal", hasFocusedWindow, name == kAXTextAreaRole,
              native.settable(element, kAXSelectedTextRangeAttribute as CFString, &settable) == .success, settable.boolValue else { return false }
        return native.settable(element, kAXFocusedAttribute as CFString, &settable) == .success && settable.boolValue
    }
    /// Reads only element identity for comparison, never element content.
    private static func focusedElement(_ remote: AXUIElement, attribute name: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(remote, name as CFString, &value) == .success, let found = value, CFGetTypeID(found) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(found, to: AXUIElement.self)
    }
    private static func currentlyFocused(of app: NSRunningApplication) -> (window: AXUIElement?, element: AXUIElement?) {
        let remote = AXUIElementCreateApplication(app.processIdentifier)
        return (focusedElement(remote, attribute: kAXFocusedWindowAttribute), focusedElement(remote, attribute: kAXFocusedUIElementAttribute))
    }
    private static func isSameTarget(_ target: PasteDestination) -> Bool {
        let current = currentlyFocused(of: target.app)
        if let window = target.window { guard let now = current.window, CFEqual(window, now) else { return false } }
        guard let now = current.element, CFEqual(target.element, now) else { return false }
        return isEditable(now, bundleID: target.app.bundleIdentifier, hasFocusedWindow: current.window != nil)
    }
    func startStack() {
        guard hasAccessibility else { model.message("Allow Accessibility in Settings to paste the stack with ⌘V."); return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        eventTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let service = Unmanaged<PasteService>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated {
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { if let tap = service.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }; return }
                guard event.getIntegerValueField(.eventSourceUserData) != 0x53544153, event.getIntegerValueField(.keyboardEventKeycode) == 9, event.flags.intersection([.maskCommand, .maskControl, .maskAlternate]) == .maskCommand, event.getIntegerValueField(.keyboardEventAutorepeat) == 0, let id = service.model.stack.next, let item = service.model.store.items.first(where: { $0.id == id }) else { return }
                if service.copy([item], plain: event.flags.contains(.maskShift)) { _ = service.model.stack.consume() }
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        if let eventTap { eventSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0); CFRunLoopAddSource(CFRunLoopGetMain(), eventSource, .commonModes) }
        else { model.message("Unable to listen for Stack paste. Check Accessibility permission.") }
    }
    func stopStack() { if let eventTap { CFMachPortInvalidate(eventTap) }; if let eventSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), eventSource, .commonModes) }; eventTap = nil; eventSource = nil }
    enum PasteError: LocalizedError { case missingFile; var errorDescription: String? { "This file is no longer available on this device." } }
}

private final class PasteActivationObservation {
    let center: NotificationCenter
    let token: NSObjectProtocol
    init(center: NotificationCenter, token: NSObjectProtocol) { self.center = center; self.token = token }
    deinit { center.removeObserver(token) }
}
