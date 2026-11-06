import Foundation
import StashCore
import XCTest
@testable import StashMac

@MainActor final class OnboardingStartupTests: XCTestCase {

    func testResumedJourneyOpensUnfilteredHistoryAfterPermissionAndShortcutFallback() throws {
        try withTemporaryLibrary { directory in
            var permission = DirectPastePermission.Status.notGranted
            let access = DirectPastePermission(status: { permission }, request: { permission = .granted })
            let system = DailyUseSystem(
                prepareShortcuts: { _, shortcuts in
                    if shortcuts.panel != nil { throw DailyUseIssue.unavailable(.panel) }
                    return ShortcutChange()
                },
                loginStatus: { .manual },
                setLoginEnabled: { _ in XCTFail("Setup changed an untouched login setting") }
            )
            do {
                let first = try MacStartup(directory: directory, directPastePermission: access, dailyUseSystem: system)
                first.go(to: .dailyUse)
                first.editDraft { $0.stackShortcut = KeyBinding(keyCode: 11, modifiers: 768) }
            }

            let resumed = try MacStartup(directory: directory, directPastePermission: access, dailyUseSystem: system)
            XCTAssertEqual(resumed.step, .dailyUse)
            XCTAssertEqual(resumed.draft?.stackShortcut, KeyBinding(keyCode: 11, modifiers: 768))
            resumed.go(to: .directPaste)
            resumed.requestDirectPastePermission()
            resumed.refreshDirectPastePermission()
            XCTAssertEqual(resumed.directPasteStatus, .granted)
            XCTAssertFalse(resumed.startIfReady { _ in XCTFail("Permission switch bypassed setup") })

            let model = resumed.model
            model.currentBoard = try model.store.createBoard(name: "Generated Pinboard").id
            model.query = "old query"
            model.filter.kind = .image
            model.showFilters = true
            model.searchFocused = true
            resumed.go(to: .ready)
            XCTAssertFalse(resumed.finish())
            XCTAssertEqual(resumed.dailyUseIssue, .unavailable(.panel))
            XCTAssertFalse(resumed.startIfReady { _ in XCTFail("Shortcut failure bypassed setup") })

            resumed.continueWithoutShortcut(.panel)
            XCTAssertTrue(resumed.finish())
            XCTAssertTrue(resumed.startIfReady { ready in
                XCTAssertNil(ready.currentBoard)
                XCTAssertTrue(ready.query.isEmpty)
                XCTAssertTrue(ready.filter.isEmpty)
                XCTAssertFalse(ready.showFilters)
                XCTAssertFalse(ready.searchFocused)
            })
            XCTAssertFalse(resumed.startIfReady { _ in XCTFail("Resumed setup started twice") })
            XCTAssertTrue(model.settings.panelShortcutDisabled == true)
            XCTAssertTrue(model.showsSetupGuide)
            XCTAssertEqual(model.openStashGuidance, "Open Stash from the menu bar.")
            XCTAssertFalse(model.settings.syncEnabled || model.settings.suggestionsEnabled || model.settings.mcpEnabled)
        }
    }

    func testConflictingShortcutKeepsSetupPendingUntilExplicitFallback() throws {
        try withTemporaryLibrary { directory in
            let defaultPanel = KeyBinding(keyCode: 9, modifiers: 768)
            var applied: DailyUseShortcuts?
            let system = DailyUseSystem(
                prepareShortcuts: { _, shortcuts in
                    if shortcuts.panel == defaultPanel { throw DailyUseIssue.unavailable(.panel) }
                    return ShortcutChange(commit: { applied = shortcuts })
                },
                loginStatus: { .manual },
                setLoginEnabled: { _ in XCTFail("Unchanged login must not be registered") }
            )
            let startup = try MacStartup(directory: directory, dailyUseSystem: system)
            XCTAssertEqual(startup.draft?.panelShortcut, defaultPanel)
            XCTAssertFalse(startup.draft?.launchAtLogin ?? true)
            startup.go(to: .ready)

            XCTAssertFalse(startup.finish())
            XCTAssertEqual(startup.dailyUseIssue, .unavailable(.panel))
            XCTAssertFalse(startup.startIfReady { _ in XCTFail("Capture started with unresolved setup") })
            XCTAssertNil(applied)

            startup.continueWithoutShortcut(.panel)
            XCTAssertTrue(startup.finish())
            XCTAssertNil(applied?.panel)
            XCTAssertEqual(applied?.stack, KeyBinding(keyCode: 8, modifiers: 768))
            let reopened = try MacStartup(directory: directory, dailyUseSystem: system)
            XCTAssertFalse(reopened.needsSetup)
            XCTAssertTrue(reopened.model.settings.panelShortcutDisabled == true)
            XCTAssertTrue(reopened.openWizard())
            XCTAssertNil(reopened.draft?.panelShortcut)
        }
    }

    func testStackShortcutFallbackKeepsMenuAccessWithHiddenIconPreference() throws {
        try withTemporaryLibrary { directory in
            let panelShortcut = KeyBinding(keyCode: 9, modifiers: 768)
            do {
                let store = try LibraryStore(directory: directory)
                var settings = store.settings
                settings.showMenuBarIcon = false
                try store.updateSettings(settings)
            }
            var effectiveShortcuts: DailyUseShortcuts?
            let system = DailyUseSystem(
                prepareShortcuts: { _, shortcuts in
                    if shortcuts.stack != nil { throw DailyUseIssue.unavailable(.stack) }
                    return ShortcutChange(commit: { effectiveShortcuts = shortcuts })
                },
                loginStatus: { .manual },
                setLoginEnabled: { _ in XCTFail("Unchanged login must not be registered") }
            )
            let startup = try MacStartup(directory: directory, dailyUseSystem: system)
            XCTAssertFalse(startup.needsSetup)
            XCTAssertFalse(startup.model.requiresMenuBarAccess)
            XCTAssertTrue(startup.openWizard())
            startup.go(to: .ready)
            XCTAssertFalse(startup.finish())
            XCTAssertEqual(startup.dailyUseIssue, .unavailable(.stack))

            startup.continueWithoutShortcut(.stack)
            XCTAssertTrue(startup.finish())
            XCTAssertEqual(effectiveShortcuts?.panel, panelShortcut)
            XCTAssertNil(effectiveShortcuts?.stack)
            XCTAssertFalse(startup.model.settings.showMenuBarIcon)
            XCTAssertTrue(startup.model.requiresMenuBarAccess)
            XCTAssertTrue(startup.model.openStashGuidance.hasPrefix("Open Stash with "))

            let reopened = try MacStartup(directory: directory, dailyUseSystem: system)
            XCTAssertFalse(reopened.model.settings.showMenuBarIcon)
            XCTAssertTrue(reopened.model.requiresMenuBarAccess)
        }
    }

    func testDailyUseResumesDraftAndRetriesUnconfirmedLoginRegistration() throws {
        try withTemporaryLibrary { directory in
            var login = DailyUseSystem.LoginStatus.manual
            var loginChanges: [Bool] = []
            var systemAllowsLogin = false
            var effectiveShortcuts: DailyUseShortcuts?
            let system = DailyUseSystem(
                prepareShortcuts: { _, shortcuts in ShortcutChange(commit: { effectiveShortcuts = shortcuts }) },
                loginStatus: { login },
                setLoginEnabled: { enabled in
                    loginChanges.append(enabled)
                    login = enabled ? (systemAllowsLogin ? .enabled : .requiresApproval) : .manual
                }
            )
            let chosen = KeyBinding(keyCode: 11, modifiers: 768)
            do {
                let startup = try MacStartup(directory: directory, dailyUseSystem: system)
                startup.go(to: .dailyUse)
                startup.editDraft { $0.panelShortcut = chosen; $0.launchAtLogin = true }
            }
            XCTAssertTrue(loginChanges.isEmpty)
            let resumed = try MacStartup(directory: directory, dailyUseSystem: system)
            XCTAssertEqual(resumed.step, .dailyUse)
            XCTAssertEqual(resumed.draft?.panelShortcut, chosen)
            XCTAssertEqual(resumed.draft?.launchAtLogin, true)
            XCTAssertNotEqual(resumed.model.settings.panelShortcut, chosen)
            resumed.go(to: .ready)
            XCTAssertFalse(resumed.finish())
            guard case .login = resumed.dailyUseIssue else { return XCTFail("Expected a login-registration error") }
            XCTAssertEqual(login, .requiresApproval)
            XCTAssertEqual(loginChanges, [true])
            XCTAssertNil(effectiveShortcuts)
            XCTAssertTrue(resumed.needsSetup)

            systemAllowsLogin = true
            login = .enabled // Simulate explicit approval in macOS Login Items.
            XCTAssertTrue(resumed.finish())
            XCTAssertEqual(login, .enabled)
            XCTAssertEqual(effectiveShortcuts?.panel, chosen)
            let reopened = try MacStartup(directory: directory, dailyUseSystem: system)
            XCTAssertTrue(reopened.openWizard())
            XCTAssertEqual(reopened.draft?.launchAtLogin, true)
            XCTAssertEqual(reopened.draft?.panelShortcut, chosen)
            XCTAssertEqual(loginChanges, [true])
        }
    }

    func testDuplicateShortcutAndLoginFailureAllowExplicitFallbacks() throws {
        try withTemporaryLibrary { directory in
            var loginRequests: [Bool] = []
            var effectiveShortcuts: DailyUseShortcuts?
            let system = DailyUseSystem(
                prepareShortcuts: { _, shortcuts in ShortcutChange(commit: { effectiveShortcuts = shortcuts }) },
                loginStatus: { .manual },
                setLoginEnabled: { enabled in
                    loginRequests.append(enabled)
                    throw CocoaError(.featureUnsupported)
                }
            )
            let startup = try MacStartup(directory: directory, dailyUseSystem: system)
            startup.editDraft { $0.stackShortcut = $0.panelShortcut; $0.launchAtLogin = true }
            startup.go(to: .ready)
            XCTAssertFalse(startup.finish())
            XCTAssertEqual(startup.dailyUseIssue, .duplicate)
            XCTAssertTrue(loginRequests.isEmpty)
            startup.continueWithoutShortcut(.stack)

            XCTAssertFalse(startup.finish())
            guard case .login = startup.dailyUseIssue else { return XCTFail("Expected a login-registration error") }
            XCTAssertEqual(loginRequests, [true])
            XCTAssertNil(effectiveShortcuts)
            startup.continueWithManualStartup()
            XCTAssertTrue(startup.finish())
            XCTAssertEqual(loginRequests, [true])
            XCTAssertEqual(effectiveShortcuts?.panel, KeyBinding(keyCode: 9, modifiers: 768))
            XCTAssertNil(effectiveShortcuts?.stack)
            let reopened = try MacStartup(directory: directory, dailyUseSystem: system)
            XCTAssertTrue(reopened.openWizard())
            XCTAssertEqual(reopened.draft?.launchAtLogin, false)
            XCTAssertNil(reopened.draft?.stackShortcut)
        }
    }

    func testCoreSaveFailureRollsBackDailyUseAndKeepsDraftPending() throws {
        try withTemporaryLibrary { directory in
            var login = DailyUseSystem.LoginStatus.manual
            var provisionalShortcuts: DailyUseShortcuts?
            var effectiveShortcuts: DailyUseShortcuts?
            let system = DailyUseSystem(
                prepareShortcuts: { _, shortcuts in
                    provisionalShortcuts = shortcuts
                    return ShortcutChange(commit: {
                        effectiveShortcuts = provisionalShortcuts
                        provisionalShortcuts = nil
                    }, cancel: {
                        provisionalShortcuts = nil
                    })
                },
                loginStatus: { login },
                setLoginEnabled: { login = $0 ? .enabled : .manual }
            )
            let startup = try MacStartup(directory: directory, dailyUseSystem: system, beforeSavingSettings: {
                throw CocoaError(.fileWriteOutOfSpace)
            })
            let chosen = KeyBinding(keyCode: 11, modifiers: 768)
            startup.editDraft { $0.panelShortcut = chosen; $0.launchAtLogin = true }
            startup.go(to: .ready)
            XCTAssertFalse(startup.finish())
            XCTAssertEqual(login, .manual)
            XCTAssertNil(effectiveShortcuts)
            XCTAssertNil(provisionalShortcuts)
            XCTAssertFalse(startup.startIfReady { _ in XCTFail("Capture started after the save failed") })
            let reopened = try MacStartup(directory: directory, dailyUseSystem: system)
            XCTAssertNotEqual(reopened.model.settings.panelShortcut, chosen)
            XCTAssertEqual(reopened.draft?.panelShortcut, chosen)
            XCTAssertTrue(reopened.finish())
            XCTAssertEqual(login, .enabled)
            XCTAssertEqual(effectiveShortcuts?.panel, chosen)
        }
    }

    func testManualFallbackCompletesWhenLoginStatusIsUnavailable() throws {
        try withTemporaryLibrary { directory in
            let system = DailyUseSystem(prepareShortcuts: { _, _ in ShortcutChange() },
                loginStatus: { .unavailable }, setLoginEnabled: { _ in XCTFail("Unavailable login state was changed") })
            let startup = try MacStartup(directory: directory, dailyUseSystem: system)
            startup.editDraft { $0.launchAtLogin = true }
            startup.go(to: .ready)
            XCTAssertFalse(startup.finish())
            startup.continueWithManualStartup()
            XCTAssertTrue(startup.finish())
            XCTAssertEqual(startup.loginStatus, .unavailable)
            XCTAssertFalse(startup.needsSetup)
        }
    }

    func testFinishingAnUntouchedExistingDraftLeavesLoginApprovalPending() throws {
        try withTemporaryLibrary { directory in
            _ = try LibraryStore(directory: directory)
            var login = DailyUseSystem.LoginStatus.requiresApproval
            let system = DailyUseSystem(prepareShortcuts: { _, _ in ShortcutChange() },
                loginStatus: { login }, setLoginEnabled: { login = $0 ? .enabled : .manual })
            let startup = try MacStartup(directory: directory, dailyUseSystem: system)
            XCTAssertTrue(startup.openWizard())
            startup.go(to: .ready)
            XCTAssertTrue(startup.finish())
            XCTAssertEqual(login, .requiresApproval)
        }
    }

    func testDiscardingResumedDraftCancelsItsOwnPendingLoginRequest() throws {
        try withTemporaryLibrary { directory in
            var login = DailyUseSystem.LoginStatus.manual
            let system = DailyUseSystem(prepareShortcuts: { _, _ in ShortcutChange() },
                loginStatus: { login }, setLoginEnabled: { login = $0 ? .requiresApproval : .manual })
            do {
                let startup = try MacStartup(directory: directory, dailyUseSystem: system)
                startup.editDraft { $0.launchAtLogin = true }
                startup.go(to: .ready)
                XCTAssertFalse(startup.finish())
                XCTAssertEqual(login, .requiresApproval)
            }
            let resumed = try MacStartup(directory: directory, dailyUseSystem: system)
            XCTAssertTrue(resumed.discardDraft())
            XCTAssertEqual(login, .manual)
            XCTAssertTrue(resumed.needsSetup)
        }
    }

    func testDiscardCancelsDraftOwnedLoginWhenSettingsSaveFailed() throws {
        try withTemporaryLibrary { directory in
            var login = DailyUseSystem.LoginStatus.manual
            let system = DailyUseSystem(prepareShortcuts: { _, _ in ShortcutChange() },
                loginStatus: { login }, setLoginEnabled: { login = $0 ? .requiresApproval : .manual })
            let startup = try MacStartup(directory: directory, dailyUseSystem: system, beforeSavingSettings: {
                throw CocoaError(.fileWriteOutOfSpace)
            })
            startup.editDraft {
                $0.retentionDays = 7
                $0.launchAtLogin = true
            }
            startup.go(to: .ready)
            XCTAssertFalse(startup.finish())
            XCTAssertEqual(login, .requiresApproval)
            login = .enabled
            XCTAssertFalse(startup.finish())
            XCTAssertEqual(startup.model.settings.retentionDays, 30)

            let resumed = try MacStartup(directory: directory, dailyUseSystem: system)
            XCTAssertTrue(resumed.discardDraft())
            XCTAssertEqual(login, .manual)
            XCTAssertEqual(resumed.model.settings.retentionDays, 30)
            XCTAssertTrue(resumed.needsSetup)
        }
    }

    func testDiscardPreservesOwnedLoginRequestWhileStatusIsUnavailable() throws {
        try withTemporaryLibrary { directory in
            var login = DailyUseSystem.LoginStatus.manual
            let system = DailyUseSystem(prepareShortcuts: { _, _ in ShortcutChange() },
                loginStatus: { login }, setLoginEnabled: { login = $0 ? .requiresApproval : .manual })
            let startup = try MacStartup(directory: directory, dailyUseSystem: system)
            startup.editDraft { $0.launchAtLogin = true }
            startup.go(to: .ready)
            XCTAssertFalse(startup.finish())
            XCTAssertEqual(login, .requiresApproval)
            login = .unavailable

            let resumed = try MacStartup(directory: directory, dailyUseSystem: system)
            XCTAssertFalse(resumed.discardDraft())
            XCTAssertEqual(login, .unavailable)
            XCTAssertEqual(resumed.step, .ready)
            XCTAssertNotNil(resumed.errorMessage)
            login = .requiresApproval
            XCTAssertTrue(resumed.discardDraft())
            XCTAssertEqual(login, .manual)
            XCTAssertTrue(resumed.needsSetup)
        }
    }

    func testVoluntaryPrivacyDraftResumesWithoutChangingActiveSettings() throws {
        try withTemporaryLibrary { directory in
            do {
                let store = try LibraryStore(directory: directory)
                var settings = store.settings
                settings.retentionDays = nil
                settings.ignoredApplications = ["example.current"]
                try store.updateSettings(settings)
            }
            let startup = try MacStartup(directory: directory)
            XCTAssertTrue(startup.startIfReady { _ in })
            startup.openWizard()
            XCTAssertEqual(startup.draft?.ignoredApplications, ["example.current"])
            startup.go(to: .privacy)
            startup.editDraft {
                $0.retentionDays = 7
                $0.ignoredApplications.append("example.draft")
            }
            startup.go(to: .ready)

            let reopened = try MacStartup(directory: directory)
            XCTAssertTrue(reopened.startIfReady { model in
                XCTAssertNil(model.settings.retentionDays)
                XCTAssertEqual(model.settings.ignoredApplications, ["example.current"])
            })
            XCTAssertNil(reopened.step)
            reopened.openWizard()
            XCTAssertEqual(reopened.step, .ready)
            XCTAssertEqual(reopened.draft?.retentionDays, 7)
            XCTAssertEqual(reopened.draft?.ignoredApplications, ["example.current", "example.draft"])
        }
    }

    func testInvalidRetentionAndDiscardKeepFirstSetupPending() throws {
        try withTemporaryLibrary { directory in
            let startup = try MacStartup(directory: directory)
            startup.go(to: .privacy)
            startup.editDraft { $0.retentionDays = -1 }
            XCTAssertNotNil(startup.errorMessage)
            XCTAssertEqual(startup.draft?.retentionDays, 30)
            startup.editDraft { $0.retentionDays = nil }
            XCTAssertNil(startup.draft?.retentionDays)
            XCTAssertTrue(startup.discardDraft())
            XCTAssertEqual(startup.step, .welcome)
            XCTAssertEqual(startup.draft?.retentionDays, 30)
            XCTAssertFalse(startup.startIfReady { _ in XCTFail("Discard started capture") })
            let reopened = try MacStartup(directory: directory)
            XCTAssertTrue(reopened.needsSetup)
            XCTAssertEqual(reopened.step, .welcome)
            XCTAssertEqual(reopened.model.settings.retentionDays, 30)
        }
    }

    func testShorterRetentionChecksCurrentHistoryAndConfirmsBeforeApplyingChanges() throws {
        try withTemporaryLibrary { directory in
            let original = try LibraryStore(directory: directory)
            var settings = original.settings
            settings.retentionDays = nil
            settings.ignoredApplications = ["example.original"]
            try original.updateSettings(settings)

            let startup = try MacStartup(directory: directory)
            XCTAssertTrue(startup.openWizard())
            startup.go(to: .privacy)
            startup.editDraft {
                $0.retentionDays = 7
                $0.ignoredApplications = ["example.changed"]
            }
            startup.go(to: .ready)

            // Insert items after the draft opened. Finish must inspect the current library.
            let aged = Date.now.addingTimeInterval(-20 * 86_400)
            let old = ClipItem(kind: .text, text: "Older History", createdAt: aged)
            let pinned = ClipItem(kind: .text, text: "Older Pinboard item", createdAt: aged)
            let current = ClipItem(kind: .text, text: "Current History")
            let board = try original.createBoard(name: "Generated pinboard")
            try original.add(old)
            try original.add(current)
            try original.add(pinned)
            try original.pin([pinned.id], to: board.id)

            XCTAssertFalse(startup.finish { _ in XCTFail("Optional settings ran before confirmation") })
            XCTAssertTrue(startup.confirmsHistoryDeletion)
            startup.cancelHistoryDeletion()
            let declined = try MacStartup(directory: directory)
            XCTAssertNil(declined.model.settings.retentionDays)
            XCTAssertEqual(declined.model.settings.ignoredApplications, ["example.original"])
            XCTAssertTrue(declined.model.store.items.contains { $0.id == old.id })
            XCTAssertTrue(declined.openWizard())
            XCTAssertEqual(declined.draft?.retentionDays, 7)

            XCTAssertFalse(declined.finish())
            XCTAssertTrue(declined.finish(confirmDeletion: true))
            let finished = try MacStartup(directory: directory)
            XCTAssertEqual(finished.model.settings.retentionDays, 7)
            XCTAssertEqual(finished.model.settings.ignoredApplications, ["example.changed"])
            XCTAssertFalse(finished.model.store.items.contains { $0.id == old.id })
            XCTAssertTrue(finished.model.store.items.contains { $0.id == current.id })
            XCTAssertTrue(finished.model.store.items.contains { $0.id == pinned.id && $0.pinboardID == board.id })
        }
    }

    func testFailedSettingsSaveKeepsFirstSetupDraftRetryable() throws {
        try withTemporaryLibrary { directory in
            let startup = try MacStartup(directory: directory, beforeSavingSettings: {
                throw CocoaError(.fileWriteOutOfSpace)
            })
            startup.go(to: .privacy)
            startup.editDraft { $0.retentionDays = 7 }
            startup.go(to: .ready)
            XCTAssertFalse(startup.finish())
            XCTAssertNotNil(startup.errorMessage)
            XCTAssertFalse(startup.startIfReady { _ in XCTFail("Started after settings save failed") })

            let reopened = try MacStartup(directory: directory)
            XCTAssertEqual(reopened.model.settings.retentionDays, 30)
            XCTAssertEqual(reopened.draft?.retentionDays, 7)
            XCTAssertEqual(reopened.step, .ready)
            XCTAssertTrue(reopened.finish())
            XCTAssertTrue(reopened.startIfReady { _ in })
            XCTAssertEqual(try MacStartup(directory: directory).model.settings.retentionDays, 7)
        }
    }

    func testFailedCompletionMarkerReportsSavedSettingsAndKeepsCaptureGated() throws {
        try withTemporaryLibrary { directory in
            var failProgressWrite = false
            let startup = try MacStartup(directory: directory, writeProgress: { data, url in
                if failProgressWrite { throw CocoaError(.fileWriteOutOfSpace) }
                try data.write(to: url, options: .atomic)
            })
            startup.editDraft { $0.retentionDays = 7 }
            startup.go(to: .ready)
            failProgressWrite = true
            XCTAssertFalse(startup.finish())
            XCTAssertTrue(startup.errorMessage?.contains("choices were saved") == true)
            let reopened = try MacStartup(directory: directory)
            XCTAssertEqual(reopened.model.settings.retentionDays, 7)
            XCTAssertEqual(reopened.draft?.retentionDays, 7)
            XCTAssertFalse(reopened.startIfReady { _ in XCTFail("Started without a completed setup marker") })
        }
    }

    func testDiscardAfterSavedChoicesAndRelaunchPreservesEnabledLogin() throws {
        for (requiresApproval, retentionDays) in [(false, 7), (true, 7), (true, 30)] {
            try withTemporaryLibrary { directory in
                var login = DailyUseSystem.LoginStatus.manual
                var failProgressWrite = false
                let system = DailyUseSystem(prepareShortcuts: { _, _ in ShortcutChange() },
                    loginStatus: { login }, setLoginEnabled: { enabled in
                        login = enabled ? (requiresApproval ? .requiresApproval : .enabled) : .manual
                    })
                do {
                    let startup = try MacStartup(directory: directory, dailyUseSystem: system, writeProgress: { data, url in
                        if failProgressWrite && login == .enabled { throw CocoaError(.fileWriteOutOfSpace) }
                        try data.write(to: url, options: .atomic)
                    })
                    startup.editDraft {
                        $0.retentionDays = retentionDays
                        $0.launchAtLogin = true
                    }
                    startup.go(to: .ready)
                    if requiresApproval {
                        XCTAssertFalse(startup.finish())
                        XCTAssertEqual(login, .requiresApproval)
                        login = .enabled
                    }
                    failProgressWrite = true
                    XCTAssertFalse(startup.finish())
                    XCTAssertEqual(login, .enabled)
                    XCTAssertTrue(startup.errorMessage?.contains("choices were saved") == true)
                }

                let resumed = try MacStartup(directory: directory, dailyUseSystem: system)
                XCTAssertEqual(resumed.model.settings.retentionDays, retentionDays)
                XCTAssertEqual(resumed.step, .ready)
                XCTAssertTrue(resumed.errorMessage?.contains("choices were saved") == true)
                XCTAssertTrue(resumed.discardDraft())
                XCTAssertEqual(login, .enabled, "Discard changed active login after requiresApproval=\(requiresApproval)")
                XCTAssertEqual(resumed.model.settings.retentionDays, retentionDays)
                XCTAssertFalse(resumed.startIfReady { _ in XCTFail("Discard started capture") })
            }
        }
    }

    func testRetryCompletesSavedDraftWithoutRepeatingItsEffects() throws {
        try withTemporaryLibrary { directory in
            var login = DailyUseSystem.LoginStatus.manual
            var failProgressWrite = false
            let system = DailyUseSystem(prepareShortcuts: { _, _ in ShortcutChange() },
                loginStatus: { login }, setLoginEnabled: { login = $0 ? .enabled : .manual })
            let startup = try MacStartup(directory: directory, dailyUseSystem: system, writeProgress: { data, url in
                if failProgressWrite && login == .enabled { throw CocoaError(.fileWriteOutOfSpace) }
                try data.write(to: url, options: .atomic)
            })
            startup.editDraft {
                $0.retentionDays = 7
                $0.launchAtLogin = true
            }
            startup.go(to: .ready)
            failProgressWrite = true
            XCTAssertFalse(startup.finish())
            XCTAssertEqual(login, .enabled)

            let resumed = try MacStartup(directory: directory, dailyUseSystem: system)
            login = .manual // The user independently turns off login in macOS.
            var active = resumed.model.settings
            active.retentionDays = 21
            try resumed.model.store.updateSettings(active)
            resumed.go(to: .privacy)
            resumed.go(to: .ready)
            XCTAssertTrue(resumed.errorMessage?.contains("choices were saved") == true)
            XCTAssertTrue(resumed.finish())
            XCTAssertEqual(login, .manual)
            XCTAssertEqual(resumed.model.settings.retentionDays, 21)
            XCTAssertTrue(resumed.startIfReady { _ in })
        }
    }

    func testEditingSavedDraftMakesNewLoginApprovalDiscardable() throws {
        try withTemporaryLibrary { directory in
            var login = DailyUseSystem.LoginStatus.manual
            var failProgressWrite = false
            let system = DailyUseSystem(prepareShortcuts: { _, _ in ShortcutChange() },
                loginStatus: { login }, setLoginEnabled: { login = $0 ? .requiresApproval : .manual })
            let startup = try MacStartup(directory: directory, dailyUseSystem: system, writeProgress: { data, url in
                if failProgressWrite && login == .enabled { throw CocoaError(.fileWriteOutOfSpace) }
                try data.write(to: url, options: .atomic)
            })
            startup.editDraft {
                $0.retentionDays = 7
                $0.launchAtLogin = true
            }
            startup.go(to: .ready)
            XCTAssertFalse(startup.finish())
            XCTAssertEqual(login, .requiresApproval)
            login = .enabled
            failProgressWrite = true
            XCTAssertFalse(startup.finish())

            login = .manual
            let resumed = try MacStartup(directory: directory, dailyUseSystem: system)
            resumed.editDraft { $0.retentionDays = 8 }
            XCTAssertEqual(resumed.draft?.launchAtLogin, false)
            resumed.editDraft { $0.launchAtLogin = true }
            XCTAssertFalse(resumed.finish())
            XCTAssertEqual(login, .requiresApproval)
            XCTAssertTrue(resumed.discardDraft())
            XCTAssertEqual(login, .manual)
            XCTAssertEqual(resumed.model.settings.retentionDays, 7)
        }
    }

    func testRetryRechecksCurrentShortcutAndOffersFallbackWithoutRepeatingLogin() throws {
        try withTemporaryLibrary { directory in
            var login = DailyUseSystem.LoginStatus.manual
            var failProgressWrite = false
            let currentShortcut = KeyBinding(keyCode: 12, modifiers: 256)
            let system = DailyUseSystem(prepareShortcuts: { _, shortcuts in
                if shortcuts.panel == currentShortcut { throw DailyUseIssue.unavailable(.panel) }
                return ShortcutChange()
            }, loginStatus: { login }, setLoginEnabled: { login = $0 ? .enabled : .manual })
            let startup = try MacStartup(directory: directory, dailyUseSystem: system, writeProgress: { data, url in
                if failProgressWrite && login == .enabled { throw CocoaError(.fileWriteOutOfSpace) }
                try data.write(to: url, options: .atomic)
            })
            startup.editDraft { $0.launchAtLogin = true }
            startup.go(to: .ready)
            failProgressWrite = true
            XCTAssertFalse(startup.finish())
            XCTAssertEqual(login, .enabled)

            login = .manual
            let resumed = try MacStartup(directory: directory, dailyUseSystem: system)
            var active = resumed.model.settings
            active.panelShortcut = currentShortcut
            active.retentionDays = 21
            try resumed.model.store.updateSettings(active)
            guard !resumed.finish() else { return XCTFail("Finish skipped the current shortcut conflict") }
            XCTAssertEqual(resumed.dailyUseIssue, .unavailable(.panel))
            XCTAssertTrue(resumed.needsSetup)
            resumed.continueWithoutShortcut(.panel)
            XCTAssertTrue(resumed.finish())
            XCTAssertEqual(resumed.model.settings.panelShortcutDisabled, true)
            XCTAssertEqual(resumed.model.settings.retentionDays, 21)
            XCTAssertEqual(login, .manual)
        }
    }

    func testFreshStartupShowsWelcomeAndRelaunchKeepsPendingSetup() throws {
        try withTemporaryLibrary { directory in
            let startup = try MacStartup(directory: directory)
            XCTAssertEqual(startup.step, .welcome)
            let reopened = try MacStartup(directory: directory)
            XCTAssertEqual(reopened.step, .welcome)
        }
    }

    func testReadyStepSurvivesRelaunchAndOnlySuccessfulFinishOpensApplication() throws {
        try withTemporaryLibrary { directory in
            let startup = try MacStartup(directory: directory)
            XCTAssertFalse(startup.startIfReady { _ in XCTFail("Started before setup finished") })
            startup.go(to: .ready)

            var simulateWriteFailure = true
            let reopened = try MacStartup(directory: directory, writeProgress: { data, url in
                if simulateWriteFailure { throw CocoaError(.fileWriteNoPermission) }
                try data.write(to: url, options: .atomic)
            })
            XCTAssertEqual(reopened.step, .ready)
            XCTAssertFalse(reopened.finish())
            XCTAssertNotNil(reopened.errorMessage)
            XCTAssertEqual(try MacStartup(directory: directory).step, .ready)
            XCTAssertFalse(reopened.startIfReady { _ in XCTFail("Started after failed completion") })

            simulateWriteFailure = false
            XCTAssertTrue(reopened.finish())
            XCTAssertTrue(reopened.startIfReady { _ in })
            XCTAssertFalse(reopened.startIfReady { _ in XCTFail("Started a second time") })
            XCTAssertFalse(try MacStartup(directory: directory).needsSetup)
        }
    }

    func testFinderMetadataDoesNotMakeANewLibraryEstablished() throws {
        try withTemporaryLibrary { directory in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            try Data("generated Finder metadata".utf8).write(to: directory.appendingPathComponent(".DS_Store"))
            let startup = try MacStartup(directory: directory)
            XCTAssertEqual(startup.step, .welcome)
            XCTAssertFalse(startup.startIfReady { _ in XCTFail("Started before setup finished") })
        }
    }

    func testExistingEmptyHistoryKeepsItsCurrentPreferences() throws {
        try withTemporaryLibrary { directory in
            do {
                let store = try LibraryStore(directory: directory)
                var settings = store.settings
                settings.ignoredApplications = ["example.excluded"]
                try store.updateSettings(settings)
            }
            let startup = try MacStartup(directory: directory)
            XCTAssertFalse(startup.needsSetup)
            XCTAssertTrue(startup.startIfReady { model in
                XCTAssertTrue(model.store.items.isEmpty)
                XCTAssertEqual(model.settings.ignoredApplications, ["example.excluded"])
                XCTAssertFalse(model.settings.onboardingComplete)
            })
        }
    }

    func testOnlyClipboardChangesAfterSuccessfulSetupEnterHistory() throws {
        try withTemporaryLibrary { directory in
            let startup = try MacStartup(directory: directory)
            var change = 1
            var text = "An item already on the clipboard"
            var capture: CaptureService?
            let source = CaptureService.Source(changeCount: { change }, readAllowedItem: { _ in
                ClipItem(kind: .text, text: text)
            })
            let activate: (AppModel) -> Void = { model in
                capture = CaptureService(model: model, source: source)
            }

            XCTAssertFalse(startup.startIfReady(activate))
            change += 1
            text = "Copied while setup is pending"
            capture?.poll()
            XCTAssertTrue(startup.model.store.items.isEmpty)

            startup.go(to: .ready)
            XCTAssertTrue(startup.finish())
            XCTAssertTrue(startup.startIfReady(activate))
            capture?.poll()
            XCTAssertTrue(startup.model.store.items.isEmpty)

            change += 1
            text = "Copied after setup finished"
            XCTAssertFalse(startup.finish())
            XCTAssertFalse(startup.startIfReady(activate))
            capture?.poll()
            XCTAssertEqual(startup.model.store.items.map(\.text), ["Copied after setup finished"])
        }
    }

    func testMalformedSetupCannotBeTreatedAsExistingLibrary() throws {
        try withTemporaryLibrary { directory in
            _ = try MacStartup(directory: directory, writeProgress: { _, url in
                try Data("unfinished or malformed write".utf8).write(to: url)
            })
            XCTAssertThrowsError(try MacStartup(directory: directory))
            XCTAssertThrowsError(try MacStartup(directory: directory))
        }
    }

    private func withTemporaryLibrary(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stash-setup-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root.appendingPathComponent("Library", isDirectory: true))
    }
}
