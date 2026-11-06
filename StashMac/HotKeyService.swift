import AppKit
import Carbon
import ServiceManagement
import StashCore

enum DailyUseShortcut: CaseIterable {
    case panel, stack

    var name: String {
        switch self {
        case .panel: "Open Stash"
        case .stack: "Paste Stack"
        }
    }
}

struct DailyUseShortcuts: Equatable {
    var panel: KeyBinding?
    var stack: KeyBinding?

    init(_ settings: LibrarySettings) {
        panel = settings.panelShortcutDisabled == true ? nil : settings.panelShortcut
        stack = settings.stackShortcutDisabled == true ? nil : settings.stackShortcut
    }

    subscript(_ slot: DailyUseShortcut) -> KeyBinding? {
        get { slot == .panel ? panel : stack }
        set {
            switch slot {
            case .panel: panel = newValue
            case .stack: stack = newValue
            }
        }
    }

    func validate() throws {
        for slot in DailyUseShortcut.allCases {
            guard let binding = self[slot] else { continue }
            guard binding.keyCode < 128, binding.keyCode != 53,
                  binding.modifiers & ~UInt32(256 | 512 | 2_048 | 4_096) == 0,
                  binding.modifiers & (256 | 2_048 | 4_096) != 0 else {
                throw DailyUseIssue.invalid(slot)
            }
        }
        if let panel, panel == stack { throw DailyUseIssue.duplicate }
    }
}

enum DailyUseIssue: LocalizedError, Equatable {
    case invalid(DailyUseShortcut)
    case duplicate
    case unavailable(DailyUseShortcut)
    case login(String)

    var shortcut: DailyUseShortcut? {
        switch self {
        case .invalid(let slot), .unavailable(let slot): slot
        case .duplicate: .stack
        case .login: nil
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalid(let slot): "Choose a valid shortcut for \(slot.name)."
        case .duplicate: "Open Stash and Paste Stack must use different shortcuts."
        case .unavailable(let slot): "macOS couldn’t register the \(slot.name) shortcut. It may be in use."
        case .login(let reason): reason
        }
    }
}

@MainActor struct ShortcutChange {
    var commit: () -> Void = {}
    var cancel: () -> Void = {}
}

@MainActor struct DailyUseSystem {
    enum LoginStatus: Equatable {
        case manual, enabled, requiresApproval, unavailable

        var isRegistered: Bool { self == .enabled || self == .requiresApproval }

        var description: String {
            switch self {
            case .manual: "Manual startup"
            case .enabled: "Launch at login is on"
            case .requiresApproval: "Waiting for approval in macOS Login Items"
            case .unavailable: "Login status is unavailable"
            }
        }
    }

    let prepareShortcuts: (AppModel, DailyUseShortcuts) throws -> ShortcutChange
    let loginStatus: () -> LoginStatus
    let setLoginEnabled: (Bool) throws -> Void
    var openLoginSettings: () -> Void = {}

    static let isolated = Self(
        prepareShortcuts: { _, _ in ShortcutChange() },
        loginStatus: { .manual },
        setLoginEnabled: { _ in }
    )

    static let system = Self(
        prepareShortcuts: { model, shortcuts in
            if model.hotkeys == nil { model.hotkeys = HotKeyService(model: model) }
            return try model.hotkeys.prepare(shortcuts)
        },
        loginStatus: {
            switch SMAppService.mainApp.status {
            case .enabled: .enabled
            case .requiresApproval: .requiresApproval
            case .notRegistered, .notFound: .manual
            @unknown default: .unavailable
            }
        },
        setLoginEnabled: { enabled in
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        },
        openLoginSettings: { SMAppService.openSystemSettingsLoginItems() }
    )
}

@MainActor final class HotKeyService {
    private struct Registration {
        let id: UInt32
        let reference: EventHotKeyRef
    }

    private unowned let model: AppModel
    private var registrations: [KeyBinding: Registration] = [:]
    private var actions: [UInt32: DailyUseShortcut] = [:]
    private var nextID: UInt32 = 1
    private var handler: EventHandlerRef?

    func isRegistered(_ slot: DailyUseShortcut) -> Bool { actions.values.contains(slot) }

    init(model: AppModel) {
        self.model = model
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, info in
            guard let info, let event else { return OSStatus(eventNotHandledErr) }
            var key = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &key)
            guard status == noErr, key.signature == 0x53545348 else { return OSStatus(eventNotHandledErr) }
            let service = Unmanaged<HotKeyService>.fromOpaque(info).takeUnretainedValue()
            let identifier = key.id
            MainActor.assumeIsolated { service.perform(identifier) }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    private func perform(_ id: UInt32) {
        guard let panel = model.panel, model.paste != nil else { return }
        switch actions[id] {
        case .panel: panel.toggle()
        case .stack: model.toggleStack()
        case nil: break
        }
    }

    /// Reserve new keys while keeping the current bindings active. A failed setup
    /// releases only the new reservations. A saved setup promotes them together.
    func prepare(_ shortcuts: DailyUseShortcuts) throws -> ShortcutChange {
        try shortcuts.validate()
        var candidate: [KeyBinding: Registration] = [:]
        var newReferences: [EventHotKeyRef] = []
        var newActions: [UInt32: DailyUseShortcut] = [:]
        do {
            for slot in DailyUseShortcut.allCases {
                guard let binding = shortcuts[slot] else { continue }
                let registration: Registration
                if let current = registrations[binding] {
                    registration = current
                } else {
                    guard handler != nil else { throw DailyUseIssue.unavailable(slot) }
                    let id = nextID
                    nextID += 1
                    var ref: EventHotKeyRef?
                    let status = RegisterEventHotKey(binding.keyCode, binding.modifiers,
                        EventHotKeyID(signature: 0x53545348, id: id), GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &ref)
                    guard status == noErr, let ref else { throw DailyUseIssue.unavailable(slot) }
                    registration = Registration(id: id, reference: ref)
                    newReferences.append(ref)
                }
                candidate[binding] = registration
                newActions[registration.id] = slot
            }
        } catch {
            for ref in newReferences { UnregisterEventHotKey(ref) }
            throw error
        }
        return ShortcutChange(commit: {
            for (binding, registration) in self.registrations where candidate[binding] == nil {
                UnregisterEventHotKey(registration.reference)
            }
            self.registrations = candidate
            self.actions = newActions
        }, cancel: {
            for ref in newReferences { UnregisterEventHotKey(ref) }
        })
    }

    func register() {
        var desired = DailyUseShortcuts(model.settings)
        while true {
            do {
                try prepare(desired).commit()
                return
            } catch let issue as DailyUseIssue {
                model.message(issue.localizedDescription)
                guard let slot = issue.shortcut else { return }
                desired[slot] = nil
            } catch {
                model.message(error.localizedDescription)
                return
            }
        }
    }
}
