import XCTest
@testable import StashCore

/// Suggestions state, result, cancellation and privacy (#63), tested through the
/// public coordinator seam that the Mac panel drives. Native OS/model checks and
/// visible rendering are separate live journeys.
@MainActor final class SuggestionsCoordinatorTests:XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID()
    private var ready: SuggestionsReadiness {
        SuggestionsReadiness(optIn:true, systemAvailable:true, modelAvailability:.available, accessibilityGranted:true, screenRecordingGranted:true, previousAppBundleID:"com.example.editor", ignoredBundleIDs:[])
    }

    func testEnabledSupportedRequestStartsAndShowsProgress() {
        let coordinator = SuggestionsCoordinator()
        let outcome = coordinator.begin(readiness: ready, candidateIDs: [a, b, c])
        guard case .started = outcome else { return XCTFail("Expected a started request, got \(outcome)") }
        XCTAssertEqual(coordinator.state, .ranking)
        XCTAssertTrue(coordinator.isRanking)
        XCTAssertNil(coordinator.resultIDs)
    }

    func testDisabledOptInIsBlockedWithItsOwnExplanation() {
        let coordinator = SuggestionsCoordinator()
        var readiness = ready; readiness.optIn = false
        XCTAssertEqual(coordinator.begin(readiness: readiness, candidateIDs: [a, b, c]), .blocked(.suggestionsDisabled))
        XCTAssertEqual(coordinator.state, .unavailable(.suggestionsDisabled))
        XCTAssertFalse(coordinator.isRanking)
    }

    func testEachNativePrerequisiteHasItsOwnBlocker() {
        var cases: [(keyPath: WritableKeyPath<SuggestionsReadiness, Bool>, expected: SuggestionsBlocker)] = [
            (\SuggestionsReadiness.systemAvailable, .systemUnavailable),
            (\SuggestionsReadiness.accessibilityGranted, .accessibilityRequired),
            (\SuggestionsReadiness.screenRecordingGranted, .screenRecordingRequired)
        ]
        for prerequisite in cases {
            let coordinator = SuggestionsCoordinator()
            var readiness = ready; readiness[keyPath: prerequisite.keyPath] = false
            XCTAssertEqual(coordinator.begin(readiness: readiness, candidateIDs: [a, b, c]), .blocked(prerequisite.expected), "Expected \(prerequisite.expected) to be reported distinctly")
            XCTAssertEqual(coordinator.state, .unavailable(prerequisite.expected))
        }
        // Documented precedence when several prerequisites are missing at once:
        // system, model, accessibility, screen recording.
        cases.removeFirst()
        var combined = ready
        combined.modelAvailability = .unavailable
        for prerequisite in cases { combined[keyPath: prerequisite.keyPath] = false }
        XCTAssertEqual(SuggestionsCoordinator().begin(readiness: combined, candidateIDs: [a, b, c]), .blocked(.modelUnavailable))
    }

    func testMissingPreviousAppIsDistinctFromExcludedApp() {
        let withoutApp = SuggestionsCoordinator()
        var readiness = ready; readiness.previousAppBundleID = nil
        XCTAssertEqual(withoutApp.begin(readiness: readiness, candidateIDs: [a, b, c]), .blocked(.noPreviousApp))
        XCTAssertEqual(withoutApp.state, .unavailable(.noPreviousApp))
        let excluded = SuggestionsCoordinator()
        readiness.previousAppBundleID = "com.example.editor"; readiness.ignoredBundleIDs = ["com.example.editor"]
        XCTAssertEqual(excluded.begin(readiness: readiness, candidateIDs: [a, b, c]), .blocked(.appExcluded))
        XCTAssertEqual(excluded.state, .unavailable(.appExcluded))
    }

    func testCompletedRankingShowsOnlyUniqueSuppliedIdentities() {
        let coordinator = SuggestionsCoordinator()
        guard case let .started(token) = coordinator.begin(readiness: ready, candidateIDs: [a, b, c]) else { return XCTFail("Expected a started request") }
        coordinator.finish(token: token, ranked: [a, a, b, UUID(), c])
        XCTAssertEqual(coordinator.state, .results([a, b, c]))
        XCTAssertEqual(coordinator.resultIDs, [a, b, c])
        XCTAssertFalse(coordinator.isRanking)
    }

    func testEmptyRankingIsDistinctFromResultsIdleAndFailure() {
        let coordinator = SuggestionsCoordinator()
        guard case let .started(token) = coordinator.begin(readiness: ready, candidateIDs: [a, b, c]) else { return XCTFail("Expected a started request") }
        coordinator.finish(token: token, ranked: [a])
        XCTAssertEqual(coordinator.state, .results([a]))
        coordinator.begin(readiness: ready, candidateIDs: [a, b, c])
        coordinator.cancel()
        guard case let .started(retry) = coordinator.begin(readiness: ready, candidateIDs: [a, b, c]) else { return XCTFail("Expected a retry to start") }
        coordinator.finish(token: retry, ranked: [])
        XCTAssertEqual(coordinator.state, .empty)
        XCTAssertNotEqual(coordinator.state, .idle)
        XCTAssertNotEqual(coordinator.state, .failed("no matches"))
        XCTAssertNil(coordinator.resultIDs)
    }

    func testSecondTapWhileRankingCancelsInsteadOfDuplicatingWork() {
        let coordinator = SuggestionsCoordinator()
        guard case let .started(first) = coordinator.begin(readiness: ready, candidateIDs: [a, b, c]) else { return XCTFail("Expected a started request") }
        XCTAssertEqual(coordinator.begin(readiness: ready, candidateIDs: [a, b, c]), .cancelled)
        XCTAssertEqual(coordinator.state, .idle)
        coordinator.finish(token: first, ranked: [a])
        XCTAssertEqual(coordinator.state, .idle, "A cancelled request must not produce results afterwards")
    }

    func testSecondTapWithVisibleResultsTurnsSuggestionsOff() {
        let coordinator = SuggestionsCoordinator()
        guard case let .started(token) = coordinator.begin(readiness: ready, candidateIDs: [a, b, c]) else { return XCTFail("Expected a started request") }
        coordinator.finish(token: token, ranked: [b, a])
        XCTAssertEqual(coordinator.begin(readiness: ready, candidateIDs: [a, b, c]), .turnedOff)
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertNil(coordinator.resultIDs)
    }

    func testLateResultsCannotReplaceCurrentResults() {
        let coordinator = SuggestionsCoordinator()
        guard case let .started(stale) = coordinator.begin(readiness: ready, candidateIDs: [a, b, c]) else { return XCTFail("Expected a started request") }
        coordinator.cancel()
        guard case let .started(current) = coordinator.begin(readiness: ready, candidateIDs: [a, b, c]) else { return XCTFail("Expected the replacement request to start") }
        coordinator.finish(token: stale, ranked: [a])
        XCTAssertEqual(coordinator.state, .ranking, "A late superseded result must not replace current work")
        coordinator.finish(token: current, ranked: [b])
        XCTAssertEqual(coordinator.state, .results([b]))
    }

    func testCancellingDiscardsResultsAndRejectsLateCompletion() {
        let coordinator = SuggestionsCoordinator()
        guard case let .started(token) = coordinator.begin(readiness: ready, candidateIDs: [a, b, c]) else { return XCTFail("Expected a started request") }
        coordinator.finish(token: token, ranked: [a])
        XCTAssertTrue(coordinator.cancel())
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertFalse(coordinator.cancel(), "Cancelling an idle coordinator reports nothing to discard")
        guard case let .started(late) = coordinator.begin(readiness: ready, candidateIDs: [a, b, c]) else { return XCTFail("Expected a new request") }
        coordinator.cancel()
        coordinator.finish(token: late, ranked: [b])
        XCTAssertEqual(coordinator.state, .idle, "Completion after cancellation is discarded")
    }

    func testFailureIsDistinctAndRecoverable() {
        let coordinator = SuggestionsCoordinator()
        guard case let .started(token) = coordinator.begin(readiness: ready, candidateIDs: [a, b, c]) else { return XCTFail("Expected a started request") }
        coordinator.fail(token: token, reason: "The on-device model timed out.")
        XCTAssertEqual(coordinator.state, .failed("The on-device model timed out."))
        XCTAssertNotEqual(coordinator.state, .unavailable(.modelUnavailable))
        XCTAssertNil(coordinator.resultIDs)
        guard case .started = coordinator.begin(readiness: ready, candidateIDs: [a, b, c]) else { return XCTFail("A failed request must be retryable") }
        XCTAssertEqual(coordinator.state, .ranking)
    }

    func testPrerequisiteFoundDuringRequestSurfacesDistinctBlocker() {
        let coordinator = SuggestionsCoordinator()
        guard case let .started(token) = coordinator.begin(readiness: ready, candidateIDs: [a, b, c]) else { return XCTFail("Expected a started request") }
        coordinator.block(token: token, blocker: .secureField)
        XCTAssertEqual(coordinator.state, .unavailable(.secureField))
        XCTAssertFalse(coordinator.isRanking)
    }

    func testInFlightCancellationIsSilentlyDiscardedOnce() {
        let coordinator = SuggestionsCoordinator()
        guard case let .started(token) = coordinator.begin(readiness: ready, candidateIDs: [a, b, c]) else { return XCTFail("Expected a started request") }
        coordinator.discardInFlight(token: token)
        XCTAssertEqual(coordinator.state, .idle)
        coordinator.discardInFlight(token: token)
        XCTAssertEqual(coordinator.state, .idle)
        coordinator.finish(token: token, ranked: [a])
        XCTAssertEqual(coordinator.state, .idle)
    }

    func testPrivacyChangeBlocksInFlightResultAndRejectsLateCompletion() {
        let coordinator = SuggestionsCoordinator()
        guard case let .started(token) = coordinator.begin(readiness: ready, candidateIDs: [a, b, c]) else { return XCTFail("Expected a request") }
        var excluded = ready
        excluded.ignoredBundleIDs = ["com.example.editor"]
        XCTAssertFalse(coordinator.validate(token: token, readiness: excluded))
        XCTAssertEqual(coordinator.state, .unavailable(.appExcluded))
        coordinator.finish(token: token, ranked: [a])
        XCTAssertEqual(coordinator.state, .unavailable(.appExcluded))
    }

    func testOnlyTheBoundedSuppliedCandidatesCanAppearInResults() {
        let coordinator = SuggestionsCoordinator()
        let identifiers = (0..<41).map { _ in UUID() }
        guard case let .started(token) = coordinator.begin(readiness: ready, candidateIDs: identifiers) else { return XCTFail("Expected a request") }
        coordinator.finish(token: token, ranked: [identifiers[40], identifiers[0], identifiers[0], identifiers[39], UUID()])
        XCTAssertEqual(coordinator.state, .results([identifiers[0], identifiers[39]]))
    }

    func testRevokedConsentOrPermissionsBlockAnInFlightRequest() {
        for (keyPath, blocker) in [
            (\SuggestionsReadiness.optIn, SuggestionsBlocker.suggestionsDisabled),
            (\SuggestionsReadiness.accessibilityGranted, .accessibilityRequired),
            (\SuggestionsReadiness.screenRecordingGranted, .screenRecordingRequired)
        ] {
            let coordinator = SuggestionsCoordinator()
            guard case let .started(token) = coordinator.begin(readiness: ready, candidateIDs: [a]) else { return XCTFail("Expected a request") }
            var revoked = ready; revoked[keyPath: keyPath] = false
            XCTAssertFalse(coordinator.validate(token: token, readiness: revoked))
            coordinator.finish(token: token, ranked: [a])
            XCTAssertEqual(coordinator.state, .unavailable(blocker))
        }
    }

    func testStalePrivacyValidationCannotReplaceANewerRequest() {
        let coordinator = SuggestionsCoordinator()
        guard case let .started(stale) = coordinator.begin(readiness: ready, candidateIDs: [a]) else { return XCTFail("Expected a request") }
        coordinator.cancel()
        guard case let .started(current) = coordinator.begin(readiness: ready, candidateIDs: [b]) else { return XCTFail("Expected a request") }
        var excluded = ready; excluded.ignoredBundleIDs = ["com.example.editor"]
        XCTAssertFalse(coordinator.validate(token: stale, readiness: excluded))
        XCTAssertEqual(coordinator.state, .ranking)
        coordinator.finish(token: current, ranked: [b])
        XCTAssertEqual(coordinator.state, .results([b]))
    }

    func testSecureAndAmbiguousFocusGuidanceSurvivesCancellationHandling() {
        for blocker in [SuggestionsBlocker.secureField, .focusUnresolved] {
            let coordinator = SuggestionsCoordinator()
            guard case let .started(token) = coordinator.begin(readiness: ready, candidateIDs: [a]) else { return XCTFail("Expected a request") }
            coordinator.block(token: token, blocker: blocker)
            coordinator.discardInFlight(token: token)
            XCTAssertEqual(coordinator.state, .unavailable(blocker))
        }
    }

    func testEveryBlockerHasADistinctUserFacingExplanation() {
        let explanations = SuggestionsBlocker.allCases.map(\.explanation)
        XCTAssertEqual(Set(explanations).count, explanations.count, "Each prerequisite needs its own visible explanation")
        XCTAssertTrue(explanations.allSatisfy { !$0.isEmpty })
    }
}
