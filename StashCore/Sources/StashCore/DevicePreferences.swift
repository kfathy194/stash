import Foundation

/// Consent, window state, and disabled global shortcuts stay on this device.
struct DevicePreferences: Codable {
    var syncEnabled = false
    var mcpEnabled = false
    var suggestionsEnabled = false
    var onboardingComplete = false
    var showMenuBarIcon = true
    var panelHeight: Double = 350
    var panelShortcutDisabled: Bool?
    var stackShortcutDisabled: Bool?

    init() {}

    init(_ settings: LibrarySettings) {
        syncEnabled = settings.syncEnabled
        mcpEnabled = settings.mcpEnabled
        suggestionsEnabled = settings.suggestionsEnabled
        onboardingComplete = settings.onboardingComplete
        showMenuBarIcon = settings.showMenuBarIcon
        panelHeight = settings.panelHeight
        panelShortcutDisabled = settings.panelShortcutDisabled
        stackShortcutDisabled = settings.stackShortcutDisabled
    }

    func apply(to settings: inout LibrarySettings) {
        settings.syncEnabled = syncEnabled
        settings.mcpEnabled = mcpEnabled
        settings.suggestionsEnabled = suggestionsEnabled
        settings.onboardingComplete = onboardingComplete
        settings.showMenuBarIcon = showMenuBarIcon
        settings.panelHeight = panelHeight
        settings.panelShortcutDisabled = panelShortcutDisabled
        settings.stackShortcutDisabled = stackShortcutDisabled
    }
}
