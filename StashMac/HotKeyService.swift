import AppKit
import Carbon
import StashCore

@MainActor final class HotKeyService {
    unowned let model: AppModel
    private var references: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    init(model: AppModel) { self.model = model
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, info in
            guard let info, let event else { return noErr }; var key = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &key)
            let service = Unmanaged<HotKeyService>.fromOpaque(info).takeUnretainedValue(); let identifier = key.id
            MainActor.assumeIsolated { if identifier == 1 { service.model.panel?.toggle() } else if identifier == 2 { service.model.toggleStack() } }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    func register() {
        for ref in references { UnregisterEventHotKey(ref) }; references.removeAll()
        for (id, binding) in [(UInt32(1), model.settings.panelShortcut), (2, model.settings.stackShortcut)] {
            var ref: EventHotKeyRef?; let status = RegisterEventHotKey(binding.keyCode, binding.modifiers, EventHotKeyID(signature: 0x53545348, id: id), GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { references.append(ref) } else { model.message("Shortcut is already in use. Choose another in Settings.") }
        }
    }
}
