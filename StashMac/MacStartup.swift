import Foundation
import Observation
import StashCore

enum OnboardingStep: String, Codable, CaseIterable {
    case welcome
    case privacy
    case dailyUse
    case directPaste
    case ready
}

struct OnboardingDraft: Codable, Equatable {
    private enum LoginChoice: Codable, Equatable {
        case keepCurrent(Bool)
        case request(Bool)

        var enabled: Bool {
            switch self {
            case .keepCurrent(let enabled), .request(let enabled): enabled
            }
        }
    }

    private struct DailyUse: Codable, Equatable {
        var panelShortcut: KeyBinding?
        var stackShortcut: KeyBinding?
        var login: LoginChoice
        var ownsLoginApproval: Bool?
    }

    var retentionDays: Int?
    var ignoredApplications: [String]
    var settingsReceiptID: UUID? = UUID()
    var unverifiedLegacyLoginOwnership: Bool?
    private var dailyUse: DailyUse?

    var panelShortcut: KeyBinding? {
        get { dailyUse?.panelShortcut }
        set { dailyUse?.panelShortcut = newValue }
    }
    var stackShortcut: KeyBinding? {
        get { dailyUse?.stackShortcut }
        set { dailyUse?.stackShortcut = newValue }
    }
    var launchAtLogin: Bool {
        get { dailyUse?.login.enabled ?? false }
        set { dailyUse?.login = .request(newValue) }
    }

    var ownsLoginApproval: Bool {
        get { dailyUse?.ownsLoginApproval == true }
        set { dailyUse?.ownsLoginApproval = newValue ? true : nil }
    }

    var requestsLoginChange: Bool {
        if case .request = dailyUse?.login { return true }
        return false
    }

    mutating func keepCurrentLogin(_ enabled: Bool) {
        dailyUse?.login = .keepCurrent(enabled)
    }

    init(settings: LibrarySettings, currentLogin: DailyUseSystem.LoginStatus? = nil) {
        retentionDays = settings.retentionDays
        ignoredApplications = settings.ignoredApplications
        restoreDailyUseDefaults(settings: settings, currentLogin: currentLogin)
    }

    mutating func restoreDailyUseDefaults(settings: LibrarySettings, currentLogin: DailyUseSystem.LoginStatus?) {
        guard dailyUse == nil else { return }
        let shortcuts = DailyUseShortcuts(settings)
        dailyUse = DailyUse(panelShortcut: shortcuts.panel, stackShortcut: shortcuts.stack,
                            login: currentLogin.map { .keepCurrent($0.isRegistered) } ?? .request(false))
    }

    func apply(to settings: inout LibrarySettings) {
        settings.retentionDays = retentionDays
        settings.ignoredApplications = ignoredApplications
        if let panelShortcut { settings.panelShortcut = panelShortcut }
        if let stackShortcut { settings.stackShortcut = stackShortcut }
        settings.panelShortcutDisabled = panelShortcut == nil ? true : nil
        settings.stackShortcutDisabled = stackShortcut == nil ? true : nil
    }
}

private enum OnboardingProgress: Codable {
    case pending(OnboardingStep, OnboardingDraft? = nil)
    case voluntary(OnboardingStep, OnboardingDraft)
    case complete
}

/// Owns the startup decision before opening a library.
@MainActor @Observable final class MacStartup {
    // These artifacts identify an established LibraryStore even when History is empty.
    private static let libraryArtifacts: Set<String> = [
        "History.sqlite", "History.sqlite-wal", "History.sqlite-shm",
        "Boards.sqlite", "Boards.sqlite-wal", "Boards.sqlite-shm",
        "Shared.sqlite", "Shared.sqlite-wal", "Shared.sqlite-shm",
        "DeviceSettings.json", "PasteBarImport.pending.json", ".attachment-lock", "Files"
    ]
    private static let savedChoicesNotice = "Your choices were saved. Finish uses your active settings, including changes made since that save. Discard clears the draft and keeps active settings."

    let model: AppModel
    private(set) var step: OnboardingStep?
    private(set) var draft: OnboardingDraft?
    private(set) var confirmsHistoryDeletion = false
    private(set) var directPasteStatus: DirectPastePermission.Status = .notGranted
    private(set) var errorMessage: String?
    private(set) var dailyUseIssue: DailyUseIssue?
    private var progress = OnboardingProgress.complete
    private let progressURL: URL
    private let directPastePermission: DirectPastePermission
    private let dailyUseSystem: DailyUseSystem
    private(set) var loginStatus: DailyUseSystem.LoginStatus = .manual

    func refreshLoginStatus() {
        loginStatus = dailyUseSystem.loginStatus()
    }
    private let beforeSavingSettings: () throws -> Void
    private let writeProgress: (Data, URL) throws -> Void
    private var servicesStarted = false
    var needsSetup: Bool {
        if case .pending = progress { return true }
        return false
    }

    init(directory: URL, syncEnabled: Bool = false, directPastePermission: DirectPastePermission = .system,
         dailyUseSystem: DailyUseSystem = .isolated,
         beforeSavingSettings: @escaping () throws -> Void = {},
         writeProgress: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) throws {
        let progressURL = directory.appendingPathComponent("MacOnboarding.json")
        self.progressURL = progressURL
        self.directPastePermission = directPastePermission
        self.dailyUseSystem = dailyUseSystem
        self.beforeSavingSettings = beforeSavingSettings
        self.writeProgress = writeProgress
        let files: [String]
        do {
            files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            files = []
        }
        if files.contains(progressURL.lastPathComponent) {
            progress = try JSONDecoder().decode(OnboardingProgress.self, from: Data(contentsOf: progressURL))
        } else if Self.libraryArtifacts.isDisjoint(with: files) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let initial = OnboardingProgress.pending(.welcome, OnboardingDraft(settings: LibrarySettings()))
            let data = try JSONEncoder().encode(initial)
            try writeProgress(data, progressURL)
            progress = initial
        }
        model = AppModel(store: try LibraryStore(directory: directory, syncEnabled: syncEnabled))
        if case .pending(let step, let draft) = progress {
            self.step = step
            var restored = draft ?? OnboardingDraft(settings: model.settings)
            // Legacy progress without a draft has no durable receipt identity yet.
            if draft == nil { restored.settingsReceiptID = nil }
            restored.restoreDailyUseDefaults(settings: model.settings, currentLogin: nil)
            self.draft = restored
        }
        restoreSavedChoicesNotice()
        refreshDirectPastePermission()
        refreshLoginStatus()
    }

    @discardableResult func openWizard() -> Bool {
        refreshLoginStatus()
        guard step == nil else {
            refreshDirectPastePermission()
            return true
        }
        if case .voluntary(let step, var draft) = progress {
            draft.restoreDailyUseDefaults(settings: model.settings, currentLogin: loginStatus)
            self.step = step
            self.draft = draft
            restoreSavedChoicesNotice()
            refreshDirectPastePermission()
            return true
        }
        return persist(.voluntary(.welcome, OnboardingDraft(settings: model.settings, currentLogin: loginStatus)))
    }

    func go(to step: OnboardingStep) {
        guard let draft else { return }
        if persist(session(step: step, draft: draft)) {
            restoreSavedChoicesNotice()
            refreshDirectPastePermission()
        }
    }

    func refreshDirectPastePermission() {
        guard step == .directPaste || step == .ready else { return }
        directPasteStatus = directPastePermission.status()
    }

    func requestDirectPastePermission() {
        guard step == .directPaste, directPasteStatus == .notGranted else { return }
        directPastePermission.request()
        refreshDirectPastePermission()
    }

    func editDraft(_ edit: (inout OnboardingDraft) -> Void) {
        guard let step, let draft else { return }
        do {
            var original = draft
            if try choicesWereSaved(draft) {
                refreshLoginStatus()
                original = OnboardingDraft(settings: model.settings, currentLogin: loginStatus)
            }
            var updated = original
            edit(&updated)
            guard updated.retentionDays.map({ $0 > 0 }) ?? true else {
                errorMessage = "Days must be at least 1."
                return
            }
            guard updated != original else { return }
            persist(session(step: step, draft: updated))
        } catch { reportReceiptFailure(error) }
    }

    @discardableResult func discardDraft() -> Bool {
        guard step != nil, let draft else { return false }
        let choicesSaved: Bool
        do { choicesSaved = try choicesWereSaved(draft) }
        catch { reportReceiptFailure(error); return false }
        refreshLoginStatus()
        if !choicesSaved && draft.ownsLoginApproval && loginStatus != .manual {
            if (draft.settingsReceiptID == nil || draft.unverifiedLegacyLoginOwnership == true) && loginStatus == .enabled {
                errorMessage = "Stash couldn’t confirm whether this draft’s enabled login item was saved. Retry Finish to reconcile the draft."
                return false
            }
            guard loginStatus != .unavailable else {
                errorMessage = "Stash couldn’t check this draft’s login request. Try discarding again after macOS Login Items is available."
                return false
            }
            do { try updateLogin(false) }
            catch {
                errorMessage = "Stash couldn’t cancel this draft’s login request. " + error.localizedDescription
                return false
            }
            guard loginStatus == .manual else {
                errorMessage = "Stash couldn’t confirm that the login request was removed. " + loginStatus.description + "."
                return false
            }
        }
        if needsSetup {
            return persist(.pending(.welcome, OnboardingDraft(settings: LibrarySettings())))
        }
        return persist(.complete)
    }

    func cancelHistoryDeletion() { confirmsHistoryDeletion = false }

    func continueWithoutShortcut(_ slot: DailyUseShortcut) {
        guard dailyUseIssue?.shortcut == slot else { return }
        editDraft {
            switch slot {
            case .panel: $0.panelShortcut = nil
            case .stack: $0.stackShortcut = nil
            }
        }
    }

    var offersManualLoginFallback: Bool {
        loginStatus == .manual || (loginStatus.isRegistered && draft?.launchAtLogin == true)
    }

    func continueWithManualStartup() {
        guard case .login = dailyUseIssue else { return }
        refreshLoginStatus()
        let status = loginStatus
        editDraft {
            if status.isRegistered && $0.launchAtLogin {
                $0.launchAtLogin = false
            } else {
                $0.keepCurrentLogin(status.isRegistered)
            }
        }
    }

    func openLoginItems() {
        refreshLoginStatus()
        guard loginStatus == .requiresApproval else { return }
        dailyUseSystem.openLoginSettings()
    }

    @discardableResult func finish(
        confirmDeletion: Bool = false,
        prepareSettings: (inout LibrarySettings) throws -> Void = { _ in }
    ) -> Bool {
        guard step == .ready, var draft else { return false }
        let confirmed = confirmDeletion && confirmsHistoryDeletion
        confirmsHistoryDeletion = false
        dailyUseIssue = nil
        do {
            if try choicesWereSaved(draft) { return retrySavedSetup() }
        } catch { reportReceiptFailure(error); return false }
        let receiptID = draft.settingsReceiptID ?? UUID()
        if draft.settingsReceiptID == nil {
            if draft.ownsLoginApproval { draft.unverifiedLegacyLoginOwnership = true }
            draft.settingsReceiptID = receiptID
            guard persist(session(step: .ready, draft: draft)) else { return false }
        }
        var shortcutChange: ShortcutChange?
        var previousLoginStatus: DailyUseSystem.LoginStatus?
        var approvalCreated = false
        do {
            let store = model.store
            let previousExclusions = model.settings.ignoredApplications
            let applied = try store.updateSettingsApplyingRetention(
                confirmHistoryDeletion: confirmed,
                onboardingReceiptID: receiptID,
                edit: { draft.apply(to: &$0) },
                prepare: { updated in
                    try prepareSettings(&updated)
                    let shortcuts = DailyUseShortcuts(updated)
                    try shortcuts.validate()
                    shortcutChange = try dailyUseSystem.prepareShortcuts(model, shortcuts)
                    try prepareLoginChange(draft, previousStatus: &previousLoginStatus, approvalCreated: &approvalCreated)
                    try beforeSavingSettings()
                }
            )
            guard applied else {
                confirmsHistoryDeletion = true
                return false
            }
            shortcutChange?.commit()
            model.panel?.updateMenu()
            if model.settings.ignoredApplications != previousExclusions { model.dismissSuggestions() }
            return completeSavedSetup()
        } catch let cleanup as LibraryStore.ManagedFileCleanupError {
            shortcutChange?.commit()
            model.panel?.updateMenu()
            errorMessage = "Your choices were saved. \(cleanup.localizedDescription) Try Finish again."
            return false
        } catch let refresh as LibraryStore.SettingsRefreshError {
            shortcutChange?.commit()
            model.panel?.updateMenu()
            errorMessage = refresh.localizedDescription + " Try Finish again."
            return false
        } catch {
            shortcutChange?.cancel()
            var approvalSaveError: String?
            if approvalCreated {
                var updatedDraft = draft
                updatedDraft.ownsLoginApproval = true
                updatedDraft.unverifiedLegacyLoginOwnership = nil
                if persist(session(step: .ready, draft: updatedDraft)) {
                    previousLoginStatus = nil
                } else {
                    approvalSaveError = "Stash couldn’t save the pending login request in this draft."
                }
            }
            let restoreError = restoreLogin(previousLoginStatus)
            dailyUseIssue = error as? DailyUseIssue
            errorMessage = [error.localizedDescription, approvalSaveError, restoreError].compactMap { $0 }.joined(separator: " ")
            if dailyUseIssue == nil { errorMessage = "Stash couldn’t save setup. " + (errorMessage ?? "") }
            return false
        }
    }

    private func choicesWereSaved(_ draft: OnboardingDraft) throws -> Bool {
        guard let receiptID = draft.settingsReceiptID else { return false }
        return try model.store.hasOnboardingSettingsReceipt(receiptID)
    }

    private func restoreSavedChoicesNotice() {
        guard let draft else { return }
        do {
            if try choicesWereSaved(draft) { errorMessage = Self.savedChoicesNotice }
        } catch { reportReceiptFailure(error) }
    }

    private func reportReceiptFailure(_ error: Error) {
        errorMessage = "Stash couldn’t check whether this draft was saved. " + error.localizedDescription
    }

    private func retrySavedSetup() -> Bool {
        do { try model.store.retryManagedFileCleanup() }
        catch {
            errorMessage = "Your choices were saved. Stash couldn’t finish library recovery. " + error.localizedDescription
            return false
        }
        do {
            // A relaunch releases the former process's reservations. Check the
            // active settings so a recovered Finish still offers shortcut fallback.
            let shortcuts = DailyUseShortcuts(model.settings)
            try shortcuts.validate()
            try dailyUseSystem.prepareShortcuts(model, shortcuts).commit()
            model.panel?.updateMenu()
        } catch {
            dailyUseIssue = error as? DailyUseIssue
            errorMessage = "Your choices were saved. " + error.localizedDescription
            return false
        }
        return completeSavedSetup()
    }

    private func completeSavedSetup() -> Bool {
        guard persist(.complete, errorPrefix: "Your choices were saved, but Stash couldn’t mark setup finished. Try Finish again.") else { return false }
        model.prepareHistoryAfterSetup()
        return true
    }

    private func prepareLoginChange(
        _ draft: OnboardingDraft,
        previousStatus: inout DailyUseSystem.LoginStatus?,
        approvalCreated: inout Bool
    ) throws {
        refreshLoginStatus()
        let currentLogin = loginStatus
        let desiredLogin: DailyUseSystem.LoginStatus = draft.launchAtLogin ? .enabled : .manual
        guard draft.requestsLoginChange, currentLogin != desiredLogin else { return }
        guard currentLogin != .unavailable else {
            throw DailyUseIssue.login("macOS couldn’t check launch at login. Try again.")
        }
        if currentLogin == .requiresApproval && draft.launchAtLogin {
            throw DailyUseIssue.login("Approve Stash in macOS Login Items, then retry.")
        }

        previousStatus = currentLogin
        var loginError: Error?
        do { try updateLogin(draft.launchAtLogin) }
        catch { loginError = error }
        if loginStatus == .requiresApproval && draft.launchAtLogin {
            approvalCreated = currentLogin == .manual
            throw DailyUseIssue.login("Approve Stash in macOS Login Items, then retry.")
        }
        if let loginError {
            throw DailyUseIssue.login("macOS couldn’t change launch at login. " + loginError.localizedDescription)
        }
        guard loginStatus == desiredLogin else {
            throw DailyUseIssue.login("macOS hasn’t applied the requested login setting.")
        }
    }

    private func updateLogin(_ enabled: Bool) throws {
        defer { refreshLoginStatus() }
        try dailyUseSystem.setLoginEnabled(enabled)
    }

    private func restoreLogin(_ previous: DailyUseSystem.LoginStatus?) -> String? {
        guard let previous, loginStatus != previous else { return nil }
        guard previous != .requiresApproval else {
            return "Stash couldn’t restore the previous approval state. " + loginStatus.description + "."
        }
        do { try updateLogin(previous == .enabled) }
        catch { return "Stash couldn’t restore the previous login setting. " + loginStatus.description + "." }
        return loginStatus == previous
            ? nil
            : "Stash couldn’t restore the previous login setting. " + loginStatus.description + "."
    }

    @discardableResult func startIfReady(_ start: (AppModel) -> Void) -> Bool {
        guard !needsSetup, !servicesStarted else { return false }
        servicesStarted = true
        start(model)
        return true
    }

    private func session(step: OnboardingStep, draft: OnboardingDraft) -> OnboardingProgress {
        needsSetup ? .pending(step, draft) : .voluntary(step, draft)
    }

    @discardableResult private func persist(
        _ progress: OnboardingProgress,
        errorPrefix: String = "Stash couldn’t save setup."
    ) -> Bool {
        do {
            let data = try JSONEncoder().encode(progress)
            try writeProgress(data, progressURL)
            self.progress = progress
            switch progress {
            case .pending(let step, let draft):
                self.step = step
                self.draft = draft
            case .voluntary(let step, let draft):
                self.step = step
                self.draft = draft
            case .complete:
                step = nil
                draft = nil
            }
            confirmsHistoryDeletion = false
            dailyUseIssue = nil
            errorMessage = nil
            return true
        } catch {
            errorMessage = errorPrefix + " " + error.localizedDescription
            return false
        }
    }
}
