import Foundation
import Observation

/// A distinct reason Suggestions cannot run or produced nothing usable. Each case
/// maps to its own user-facing explanation so waiting, empty, blocked and failed
/// states are never indistinguishable.
public enum SuggestionsBlocker: String, Sendable, Equatable, CaseIterable {
    case suggestionsDisabled
    case systemUnavailable
    case modelUnavailable
    case appleIntelligenceNotEnabled
    case deviceNotEligible
    case modelNotReady
    case accessibilityRequired
    case screenRecordingRequired
    case secureField
    case noPreviousApp
    case appExcluded
    case focusUnresolved

    public var explanation: String {
        switch self {
        case .suggestionsDisabled: "Enable Suggestions in Settings → Intelligence first."
        case .systemUnavailable: "Suggestions requires macOS 26 or later."
        case .modelUnavailable: "The on-device model is unavailable to Stash. Try Suggestions again later."
        case .appleIntelligenceNotEnabled: "Enable Apple Intelligence in System Settings → Apple Intelligence & Siri, then try Suggestions again."
        case .deviceNotEligible: "This Mac is not eligible for Apple Intelligence. On-device Suggestions is unavailable."
        case .modelNotReady: "macOS reports that the on-device model is not ready for Stash. Try Suggestions again later."
        case .accessibilityRequired: "Allow Stash in System Settings → Privacy & Security → Accessibility so it can avoid password fields."
        case .screenRecordingRequired: "Allow Screen Recording in Settings → Intelligence. Stash reads your active window only while this panel is open."
        case .secureField: "Suggestions are disabled in password fields. Focus another field and try again."
        case .noPreviousApp: "Stash could not identify the app you were using. Focus your app, then open Stash and try Suggestions again."
        case .appExcluded: "Suggestions are unavailable for this app because it is in your ignored apps list."
        case .focusUnresolved: "The focused window could not be identified safely. Focus your app’s window, then reopen Stash and try again."
        }
    }
}

/// User-observable Suggestions outcome. Ranking results contain only unique,
/// supplied clip-item identities; no generated replacement content.
public enum SuggestionsState: Equatable, Sendable {
    case idle
    case ranking
    case results([UUID])
    case empty
    case unavailable(SuggestionsBlocker)
    case failed(String)
}

/// Preserves system model availability without importing the platform framework.
public enum SuggestionsModelAvailability: Sendable, Equatable {
    case available, appleIntelligenceNotEnabled, deviceNotEligible, modelNotReady, unavailable

    public var blocker: SuggestionsBlocker? {
        switch self {
        case .available: nil
        case .appleIntelligenceNotEnabled: .appleIntelligenceNotEnabled
        case .deviceNotEligible: .deviceNotEligible
        case .modelNotReady: .modelNotReady
        case .unavailable: .modelUnavailable
        }
    }
}

/// Native prerequisite snapshot gathered at request time; never assumed.
public struct SuggestionsReadiness: Sendable, Equatable {
    public var optIn: Bool
    public var systemAvailable: Bool
    public var modelAvailability: SuggestionsModelAvailability
    public var accessibilityGranted: Bool
    public var screenRecordingGranted: Bool
    public var previousAppBundleID: String?
    public var ignoredBundleIDs: Set<String>

    public init(optIn: Bool, systemAvailable: Bool, modelAvailability: SuggestionsModelAvailability, accessibilityGranted: Bool, screenRecordingGranted: Bool, previousAppBundleID: String?, ignoredBundleIDs: Set<String>) {
        self.optIn = optIn
        self.systemAvailable = systemAvailable
        self.modelAvailability = modelAvailability
        self.accessibilityGranted = accessibilityGranted
        self.screenRecordingGranted = screenRecordingGranted
        self.previousAppBundleID = previousAppBundleID
        self.ignoredBundleIDs = ignoredBundleIDs
    }
}

public enum SuggestionsBegin: Equatable, Sendable {
    case started(UUID)
    case blocked(SuggestionsBlocker)
    case cancelled
    case turnedOff
}

/// Owns the visible Suggestions lifecycle for the Mac panel: idle, ranking,
/// result/empty and unavailable/failed. Every request carries a token so superseded
/// or cancelled work can never replace current results.
@MainActor @Observable public final class SuggestionsCoordinator {
    public private(set) var state: SuggestionsState = .idle
    public static let candidateLimit = 40
    private var token: UUID?
    private var candidateIDs = Set<UUID>()

    public init() {}

    /// The user tapped Suggestions. A tap while ranking cancels instead of
    /// duplicating work; a tap on visible results turns Suggestions off; otherwise
    /// readiness is evaluated from the supplied snapshot without assuming
    /// permission or model state.
    @discardableResult
    public func begin(readiness: SuggestionsReadiness, candidateIDs: [UUID]) -> SuggestionsBegin {
        switch state {
        case .ranking:
            cancel()
            return .cancelled
        case .results:
            cancel()
            return .turnedOff
        case .idle, .empty, .unavailable, .failed:
            guard let blocker = Self.blocker(in: readiness) else {
                let issued = UUID()
                token = issued
                self.candidateIDs = Set(candidateIDs.prefix(Self.candidateLimit))
                state = .ranking
                return .started(issued)
            }
            state = .unavailable(blocker)
            return .blocked(blocker)
        }
    }

    /// The one prerequisite blocker implied by the snapshot, if any. Precedence:
    /// opt-in, system, model, accessibility, screen recording, previous app,
    /// ignored app.
    static func blocker(in readiness: SuggestionsReadiness) -> SuggestionsBlocker? {
        if !readiness.optIn { return .suggestionsDisabled }
        if !readiness.systemAvailable { return .systemUnavailable }
        if let blocker = readiness.modelAvailability.blocker { return blocker }
        if !readiness.accessibilityGranted { return .accessibilityRequired }
        if !readiness.screenRecordingGranted { return .screenRecordingRequired }
        guard let bundleID = readiness.previousAppBundleID else { return .noPreviousApp }
        if readiness.ignoredBundleIDs.contains(bundleID) { return .appExcluded }
        return nil
    }

    /// Recheck device consent, permissions and exclusions after native awaits.
    /// A stale request cannot change the visible outcome of its replacement.
    public func validate(token issued: UUID, readiness: SuggestionsReadiness) -> Bool {
        guard issued == token, state == .ranking else { return false }
        if let blocker = Self.blocker(in: readiness) {
            block(token: issued, blocker: blocker)
            return false
        }
        return true
    }

    /// Ranking completed. Unknown identities are dropped and duplicates collapse;
    /// an empty surviving set is a distinct empty outcome.
    public func finish(token issued: UUID, ranked: [UUID]) {
        guard issued == token, state == .ranking else { return }
        var seen = Set<UUID>()
        let unique = ranked.filter { candidateIDs.contains($0) && seen.insert($0).inserted }
        state = unique.isEmpty ? .empty : .results(unique)
        token = nil
        candidateIDs.removeAll()
    }

    /// Ranking failed for a non-prerequisite reason.
    public func fail(token issued: UUID, reason: String) {
        guard issued == token, state == .ranking else { return }
        state = .failed(reason)
        token = nil
        candidateIDs.removeAll()
    }

    /// A prerequisite was found missing during the request (secure field, ambiguous focus).
    public func block(token issued: UUID, blocker: SuggestionsBlocker) {
        guard issued == token, state == .ranking else { return }
        state = .unavailable(blocker)
        token = nil
        candidateIDs.removeAll()
    }

    /// Panel closed, context changed, or Suggestions were turned off. Reports
    /// whether anything active or visible was discarded.
    @discardableResult
    public func cancel() -> Bool {
        guard state != .idle else { return false }
        token = nil
        candidateIDs.removeAll()
        state = .idle
        return true
    }

    /// The surrounding task observed cancellation. Discards only if this token is
    /// still the current request, so a stale task cannot hide newer work.
    public func discardInFlight(token issued: UUID) {
        guard issued == token, state == .ranking else { return }
        cancel()
    }

    public var isRanking: Bool { state == .ranking }

    public var resultIDs: [UUID]? {
        if case let .results(identifiers) = state { return identifiers }
        return nil
    }
}
