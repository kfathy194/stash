import AppKit
import ApplicationServices
import StashCore

@MainActor final class PasteService {
    unowned let model: AppModel
    var previousApp: NSRunningApplication?
    private var eventTap: CFMachPort?
    private var eventSource: CFRunLoopSource?
    private var fallbackExplained = UserDefaults.standard.bool(forKey: "pasteFallbackExplained")
    init(model: AppModel) { self.model = model }
    var hasAccessibility: Bool { AXIsProcessTrusted() }
    func requestAccessibility() { _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) }
    @discardableResult func copy(_ items: [ClipItem], plain: Bool = false) -> Bool {
        do {
            let values = try items.map { try model.store.materialized($0) }; guard !values.isEmpty else { return false }
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
                        let writer = NSPasteboardItem(); writer.setString(item.text, forType: .string)
                        if let rich = item.richData { writer.setData(rich, forType: .rtf) }
                        if item.kind == .image, let data = item.data, let image = NSImage(data: data), let tiff = image.tiffRepresentation { writer.setData(tiff, forType: .tiff) }
                        if item.kind == .link { writer.setString(item.text, forType: .URL) }; writers.append(writer)
                    }
                }
            }
            guard !writers.isEmpty else { return false }; board.clearContents(); let success = board.writeObjects(writers); model.capture.suppressCurrentChange(); return success
        } catch { model.message(error.localizedDescription); return false }
    }
    func paste(_ items: [ClipItem]? = nil, plain: Bool = false) {
        let values = items ?? model.selected
        guard copy(values, plain: plain) else { return }
        model.panel?.hide()
        guard hasAccessibility, let app = previousApp, !app.isTerminated else {
            if !fallbackExplained { fallbackExplained = true; UserDefaults.standard.set(true, forKey: "pasteFallbackExplained"); let alert = NSAlert(); alert.messageText = "Ready on your clipboard"; alert.informativeText = "Press ⌘V in your app. Allow Accessibility in Stash Settings to paste directly next time."; alert.runModal() }; return
        }
        app.activate(options: [])
        Task { try? await Task.sleep(for: .milliseconds(140)); guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { model.message("Copied. Switch to your app and press ⌘V."); return }
            guard let source = CGEventSource(stateID: .combinedSessionState), let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true), let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return }
            down.flags = .maskCommand; up.flags = .maskCommand; down.setIntegerValueField(.eventSourceUserData, value: 0x53544153); up.setIntegerValueField(.eventSourceUserData, value: 0x53544153)
            down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        }
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
