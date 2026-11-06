import AppKit
import XCTest
import FoundationModels
import StashCore
@testable import StashMac

@MainActor final class SuggestionsNativeFailureTests: XCTestCase {
    private enum GeneratedFailure: Error { case capture }

    func testNativeModelReasonsReachTheBannerAndBlockBeforeScreenAccess() async throws {
        guard #available(macOS 26, *) else { throw XCTSkip("Suggestions requires macOS 26") }
        XCTAssertEqual(IntelligenceService.modelAvailability(.available), .available)
        let cases: [(SystemLanguageModel.Availability, SuggestionsBlocker, String)] = [
            (.unavailable(.appleIntelligenceNotEnabled), .appleIntelligenceNotEnabled, "Enable Apple Intelligence in System Settings → Apple Intelligence & Siri, then try Suggestions again."),
            (.unavailable(.deviceNotEligible), .deviceNotEligible, "This Mac is not eligible for Apple Intelligence. On-device Suggestions is unavailable."),
            (.unavailable(.modelNotReady), .modelNotReady, "macOS reports that the on-device model is not ready for Stash. Try Suggestions again later.")
        ]
        for (availability, blocker, explanation) in cases {
            let service = IntelligenceService(native: .init(modelAvailability: { IntelligenceService.modelAvailability(availability) }, accessibilityGranted: { true }, screenRecordingGranted: { true }, focus: { _ in
                XCTFail("Unavailable models must not inspect focus")
                throw GeneratedFailure.capture
            }, windows: {
                XCTFail("Unavailable models must not inspect the screen")
                throw GeneratedFailure.capture
            }))
            let coordinator = SuggestionsCoordinator()
            let store = try LibraryStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), inMemory: true)
            let model = AppModel(store: store, suggestionCoordinator: coordinator)
            let readiness = service.readiness(optIn: true, previousAppBundleID: "com.example.editor", ignoredBundleIDs: [])
            XCTAssertEqual(coordinator.begin(readiness: readiness, candidateIDs: []), .blocked(blocker))
            XCTAssertEqual(model.suggestionNotice?.text, explanation)
            XCTAssertEqual(model.suggestionNotice?.offersSettings, false)
            do {
                try await service.rank(items: [], app: .current, validateRequest: {}) { _ in XCTFail("Unavailable models must not publish") }
                XCTFail("Expected an unavailable model")
            } catch let error as IntelligenceService.IntelligenceError {
                XCTAssertEqual(error.blocker, blocker)
            }
        }
    }

    func testWindowDiscoveryFailureAfterContextChangesIsDiscarded() async throws {
        guard #available(macOS 26, *) else { throw XCTSkip("Suggestions requires macOS 26") }
        var focus = IntelligenceService.FocusedWindow(frame: CGRect(x: 10, y: 20, width: 400, height: 200), title: "Generated window")
        let service = IntelligenceService(native: .init(modelAvailability: { .available }, focus: { _ in focus }, windows: {
            await Task.yield()
            focus = .init(frame: CGRect(x: 40, y: 50, width: 500, height: 300), title: "Different generated window")
            throw GeneratedFailure.capture
        }))
        do {
            try await service.rank(items: [], app: .current, validateRequest: {}) { _ in XCTFail("Stale work must not publish") }
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // The original context no longer owns this failure.
        } catch {
            XCTFail("Expected cancellation, received \(error)")
        }
    }

    func testScreenshotFailureAfterContextChangesIsDiscarded() async throws {
        guard #available(macOS 26, *) else { throw XCTSkip("Suggestions requires macOS 26") }
        var focus = IntelligenceService.FocusedWindow(frame: CGRect(x: 10, y: 20, width: 400, height: 200), title: "Generated window")
        let descriptor = WindowDescriptor(id: 1, pid: NSRunningApplication.current.processIdentifier, frame: focus.frame, title: focus.title)
        let service = IntelligenceService(native: .init(modelAvailability: { .available }, focus: { _ in focus }, windows: {
            [.init(descriptor: descriptor, capture: {
                await Task.yield()
                focus = .init(frame: CGRect(x: 40, y: 50, width: 500, height: 300), title: "Different generated window")
                throw GeneratedFailure.capture
            })]
        }))
        do {
            try await service.rank(items: [], app: .current, validateRequest: {}) { _ in XCTFail("Stale work must not publish") }
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // A failed screenshot from the old window must stay invisible.
        } catch {
            XCTFail("Expected cancellation, received \(error)")
        }
    }


    func testGenuineNativeFailuresWithUnchangedContextRemainVisible() async throws {
        guard #available(macOS 26, *) else { throw XCTSkip("Suggestions requires macOS 26") }
        let focus = IntelligenceService.FocusedWindow(frame: CGRect(x: 10, y: 20, width: 400, height: 200), title: "Generated window")
        let descriptor = WindowDescriptor(id: 1, pid: NSRunningApplication.current.processIdentifier, frame: focus.frame, title: focus.title)
        for screenshot in [false, true] {
            let service = IntelligenceService(native: .init(modelAvailability: { .available }, focus: { _ in focus }, windows: {
                await Task.yield()
                if !screenshot { throw GeneratedFailure.capture }
                return [.init(descriptor: descriptor, capture: { throw GeneratedFailure.capture })]
            }))
            do {
                try await service.rank(items: [], app: .current, validateRequest: {}) { _ in XCTFail("Failed work must not publish") }
                XCTFail("Expected the generated native failure")
            } catch GeneratedFailure.capture {
                // A current request still reports a genuine failure.
            } catch {
                XCTFail("Expected the native failure, received \(error)")
            }
        }
    }

    func testNewSecureFocusGuidanceReplacesAnOldCaptureFailure() async throws {
        guard #available(macOS 26, *) else { throw XCTSkip("Suggestions requires macOS 26") }
        let focus = IntelligenceService.FocusedWindow(frame: CGRect(x: 10, y: 20, width: 400, height: 200), title: "Generated window")
        var secure = false
        let service = IntelligenceService(native: .init(modelAvailability: { .available }, focus: { _ in
            if secure { throw IntelligenceService.IntelligenceError.secureField }
            return focus
        }, windows: {
            await Task.yield()
            secure = true
            throw GeneratedFailure.capture
        }))
        do {
            try await service.rank(items: [], app: .current, validateRequest: {}) { _ in XCTFail("Protected work must not publish") }
            XCTFail("Expected secure-field guidance")
        } catch let error as IntelligenceService.IntelligenceError {
            XCTAssertEqual(error.blocker, .secureField)
        } catch {
            XCTFail("Expected secure-field guidance, received \(error)")
        }
    }

}
