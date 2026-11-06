import Foundation

/// Consent and window state stay on the current device, outside CloudKit stores.
struct DevicePreferences:Codable {
    var syncEnabled=false
    var mcpEnabled=false
    var suggestionsEnabled=false
    var onboardingComplete=false
    var showMenuBarIcon=true
    var panelHeight:Double=350
    init() {}
    init(_ settings:LibrarySettings) {syncEnabled=settings.syncEnabled;mcpEnabled=settings.mcpEnabled;suggestionsEnabled=settings.suggestionsEnabled;onboardingComplete=settings.onboardingComplete;showMenuBarIcon=settings.showMenuBarIcon;panelHeight=settings.panelHeight}
    func apply(to settings:inout LibrarySettings) {settings.syncEnabled=syncEnabled;settings.mcpEnabled=mcpEnabled;settings.suggestionsEnabled=suggestionsEnabled;settings.onboardingComplete=onboardingComplete;settings.showMenuBarIcon=showMenuBarIcon;settings.panelHeight=panelHeight}
}
