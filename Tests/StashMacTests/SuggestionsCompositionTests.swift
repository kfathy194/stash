import AppKit
import ApplicationServices
import XCTest
import StashCore
@testable import StashMac

/// These hostless checks never construct the app delegate, panel or capture service.
@MainActor final class SuggestionsCompositionTests: XCTestCase {
    private var ready: SuggestionsReadiness {
        .init(optIn: true, systemAvailable: true, modelAvailability: .available,
              accessibilityGranted: true, screenRecordingGranted: true,
              previousAppBundleID: "com.example.editor", ignoredBundleIDs: [])
    }

    func testUnavailableModelNoticeDoesNotAssumeAppleIntelligenceIsDisabledOrOfferStashSettings() throws {
        let store = try LibraryStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), inMemory: true)
        let coordinator = SuggestionsCoordinator()
        let model = AppModel(store: store, suggestionCoordinator: coordinator)
        var unavailable = ready
        unavailable.modelAvailability = .unavailable
        XCTAssertEqual(coordinator.begin(readiness: unavailable, candidateIDs: []), .blocked(.modelUnavailable))
        let notice = try XCTUnwrap(model.suggestionNotice)
        XCTAssertFalse(notice.text.contains("Enable Apple Intelligence"), "An unavailable model does not establish disabled Apple Intelligence")
        XCTAssertFalse(notice.text.contains("finish downloading"), "An unavailable model does not establish a download in progress")
        XCTAssertFalse(notice.offersSettings, "Stash Settings cannot fix an unavailable system model")
    }

    func testLocalSettingsRemediesOpenIntelligenceAndSystemPermissionDoesNotOfferThem() throws {
        let store = try LibraryStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), inMemory: true)
        let coordinator = SuggestionsCoordinator()
        var presentedSection: String?
        let model = AppModel(store: store, suggestionCoordinator: coordinator, settingsPresenter: { model in
            presentedSection = model.settingsSection
        })
        for blocker in [SuggestionsBlocker.suggestionsDisabled, .screenRecordingRequired, .accessibilityRequired] {
            guard case let .started(token) = coordinator.begin(readiness: ready, candidateIDs: []) else { return XCTFail("Expected ranking") }
            coordinator.block(token: token, blocker: blocker)
            XCTAssertEqual(model.suggestionNotice?.offersSettings, blocker != .accessibilityRequired)
            if model.suggestionNotice?.offersSettings == true {
                model.showSettings(section: "Intelligence")
                XCTAssertEqual(presentedSection, "Intelligence")
                XCTAssertEqual(model.suggestionsState, .idle)
            }
            coordinator.cancel()
        }
    }

    func testVisibleTabBindingCancelsRankingAndLateResults() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try LibraryStore(directory: directory, inMemory: true)
        let coordinator = SuggestionsCoordinator()
        let model = AppModel(store: store, suggestionCoordinator: coordinator)
        let item = ClipItem(kind: .text, text: "Generated candidate")
        try store.add(item)
        guard case let .started(token) = coordinator.begin(readiness: ready, candidateIDs: [item.id]) else { return XCTFail("Expected ranking") }
        XCTAssertTrue(model.isRanking)
        model.currentBoard = UUID()
        XCTAssertEqual(model.suggestionsState, .idle)
        coordinator.finish(token: token, ranked: [item.id])
        XCTAssertNil(model.suggestions)
        XCTAssertEqual(model.suggestionsState, .idle)
    }

    func testChangingIgnoredAppsDuringNativeAwaitDiscardsLateResults() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try LibraryStore(directory: directory, inMemory: true)
        let coordinator = SuggestionsCoordinator()
        let model = AppModel(store: store, suggestionCoordinator: coordinator)
        let identifier = UUID()
        guard case let .started(token) = coordinator.begin(readiness: ready, candidateIDs: [identifier]) else { return XCTFail("Expected ranking") }
        let pending = Task { @MainActor in
            await Task.yield()
            coordinator.finish(token: token, ranked: [identifier])
        }
        model.saveSettings { $0.ignoredApplications.append("com.example.editor") }
        await pending.value
        XCTAssertEqual(model.suggestionsState, .idle)
        XCTAssertNil(model.suggestions)
        XCTAssertTrue(model.settings.ignoredApplications.contains("com.example.editor"))
    }

    func testQueryAndFilterBindingsCancelVisibleSuggestions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try LibraryStore(directory: directory, inMemory: true)
        let coordinator = SuggestionsCoordinator()
        let model = AppModel(store: store, suggestionCoordinator: coordinator)
        let identifier = UUID()
        guard case let .started(queryToken) = coordinator.begin(readiness: ready, candidateIDs: [identifier]) else { return XCTFail("Expected ranking") }
        coordinator.finish(token: queryToken, ranked: [identifier])
        model.query = "Generated search"
        XCTAssertEqual(model.suggestionsState, .idle)
        guard case let .started(filterToken) = coordinator.begin(readiness: ready, candidateIDs: [identifier]) else { return XCTFail("Expected ranking") }
        coordinator.finish(token: filterToken, ranked: [identifier])
        model.filter.kind = .text
        XCTAssertEqual(model.suggestionsState, .idle)
    }

    func testExternalActivationDiscardsCompletedSuggestionsWithoutReplacingPasteDestination() throws {
        let store = try LibraryStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), inMemory: true)
        let coordinator = SuggestionsCoordinator()
        let model = AppModel(store: store, suggestionCoordinator: coordinator)
        let center = NotificationCenter()
        let target = PasteDestination(app: .current, window: nil, element: AXUIElementCreateApplication(NSRunningApplication.current.processIdentifier))
        let paste = PasteService(model: model, native: .init(activationCenter: center, runningApplication: { _ in .current }, frontmostApplication: { .current }, ownBundleID: "com.example.stash", capture: { _ in target }))
        model.paste = paste
        paste.captureDestinationFromFrontmost()
        let item = ClipItem(kind: .text, text: "Generated candidate")
        try store.add(item)
        guard case let .started(token) = coordinator.begin(readiness: ready, candidateIDs: [item.id]) else { return XCTFail("Expected ranking") }
        coordinator.finish(token: token, ranked: [item.id])
        paste.previousApp = .current
        XCTAssertEqual(model.suggestions, [item.id], "Assigning the same context is not an app switch")

        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil, userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current])

        XCTAssertEqual(model.suggestionsState, .idle, "Refocusing even the same app changes the panel's active context")
        XCTAssertNil(model.suggestions)
        XCTAssertTrue(paste.destination.map { CFEqual($0.element, target.element) } == true)
        XCTAssertEqual(store.items.map(\.id), [item.id])
    }

    func testChangingPreviousAppDiscardsRankingAndRejectsLateResults() throws {
        let store = try LibraryStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), inMemory: true)
        let coordinator = SuggestionsCoordinator()
        let model = AppModel(store: store, suggestionCoordinator: coordinator)
        let paste = PasteService(model: model, native: .init(activationCenter: NotificationCenter()))
        model.paste = paste
        paste.previousApp = .current
        let identifier = UUID()
        guard case let .started(token) = coordinator.begin(readiness: ready, candidateIDs: [identifier]) else { return XCTFail("Expected ranking") }

        paste.previousApp = nil
        coordinator.finish(token: token, ranked: [identifier])

        XCTAssertEqual(model.suggestionsState, .idle)
        XCTAssertNil(model.suggestions)
    }

    func testExternalActivationCancelsNativeWorkAndRejectsLateResults() async throws {
        guard #available(macOS 26, *) else { throw XCTSkip("Suggestions requires macOS 26") }
        let store = try LibraryStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), inMemory: true)
        let coordinator = SuggestionsCoordinator()
        let model = AppModel(store: store, suggestionCoordinator: coordinator)
        let center = NotificationCenter()
        model.paste = PasteService(model: model, native: .init(activationCenter: center, runningApplication: { _ in .current }, frontmostApplication: { .current }, ownBundleID: "com.example.stash"))
        model.paste.previousApp = .current
        model.intelligence = IntelligenceService(native: .init(modelAvailability: { .available }, focus: { _ in
            .init(frame: CGRect(x: 10, y: 20, width: 400, height: 200), title: "Generated window")
        }, windows: {
            await Task.yield()
            center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil, userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current])
            return []
        }))
        let identifier = UUID()
        guard case let .started(token) = coordinator.begin(readiness: ready, candidateIDs: [identifier]) else { return XCTFail("Expected ranking") }

        do {
            try await model.intelligence.rank(items: [], app: .current, validateRequest: {}) { _ in XCTFail("Stale work must not publish") }
            XCTFail("Expected cancellation before native capture")
        } catch is CancellationError {
            // An app activation discards the pending native request even when its PID is unchanged.
        }
        coordinator.finish(token: token, ranked: [identifier])
        XCTAssertEqual(model.suggestionsState, .idle)
    }

    func testSettingsDiscardsCompletedAndPendingSuggestionsBeforePresentation() throws {
        for completed in [false, true] {
            let store = try LibraryStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), inMemory: true)
            let coordinator = SuggestionsCoordinator()
            var presentations = 0
            let model = AppModel(store: store, suggestionCoordinator: coordinator, settingsPresenter: { model in
                presentations += 1
                XCTAssertEqual(model.suggestionsState, .idle)
                XCTAssertNil(model.paste.destination)
            })
            let target = PasteDestination(app: .current, window: nil, element: AXUIElementCreateApplication(NSRunningApplication.current.processIdentifier))
            let paste = PasteService(model: model, native: .init(activationCenter: NotificationCenter(), frontmostApplication: { .current }, ownBundleID: "com.example.stash", capture: { _ in target }))
            model.paste = paste
            paste.captureMenuDestination()
            paste.captureDestinationFromFrontmost(useMenuDestination: true)
            XCTAssertNotNil(paste.destination)
            let identifier = UUID()
            guard case let .started(token) = coordinator.begin(readiness: ready, candidateIDs: [identifier]) else { return XCTFail("Expected ranking") }
            if completed { coordinator.finish(token: token, ranked: [identifier]) }

            model.showSettings()
            coordinator.finish(token: token, ranked: [identifier])

            XCTAssertEqual(presentations, 1)
            XCTAssertEqual(model.suggestionsState, .idle)
            XCTAssertNil(model.suggestions)
            XCTAssertEqual(paste.previousApp?.processIdentifier, NSRunningApplication.current.processIdentifier)
            paste.captureDestinationFromFrontmost(useMenuDestination: true)
            XCTAssertNil(paste.destination, "Settings also clears the pending menu destination")
        }
    }

    func testDiscardingPasteServiceRemovesItsActivationObserver() throws {
        let store = try LibraryStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), inMemory: true)
        let model = AppModel(store: store)
        let center = ActivationRemovalCenter()
        autoreleasepool {
            var paste: PasteService? = PasteService(model: model, native: .init(activationCenter: center))
            XCTAssertNotNil(paste)
            paste = nil
        }
        XCTAssertEqual(center.removals, 1)
    }
}

private final class ActivationRemovalCenter: NotificationCenter, @unchecked Sendable {
    private(set) var removals = 0
    override func removeObserver(_ observer: Any) {
        removals += 1
        super.removeObserver(observer)
    }
}
