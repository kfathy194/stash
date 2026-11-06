import Foundation
import XCTest
@testable import StashMac

@MainActor final class OnboardingDirectPasteTests: XCTestCase {
    func testPermissionRequestAndRefreshDoNotStartCaptureOrPreventFinishingWithoutAccess() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("stash-direct-paste-test-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var status = DirectPastePermission.Status.notGranted
        var requests = 0
        let permission = DirectPastePermission(status: { status }, request: { requests += 1 })
        let startup = try MacStartup(directory: directory, directPastePermission: permission)

        startup.requestDirectPastePermission()
        XCTAssertEqual(requests, 0, "An explicit request must originate on the Direct paste step")
        startup.go(to: .directPaste)
        XCTAssertEqual(startup.directPasteStatus, .notGranted)
        XCTAssertEqual(requests, 0, "Entering the step must not prompt")
        startup.requestDirectPastePermission()
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(startup.directPasteStatus, .notGranted, "A request is not a grant")
        XCTAssertFalse(startup.startIfReady { _ in XCTFail("Capture cannot start during the permission step") })

        status = .granted
        startup.refreshDirectPastePermission()
        XCTAssertEqual(startup.directPasteStatus, .granted)
        XCTAssertFalse(startup.startIfReady { _ in XCTFail("A grant cannot start capture before Finish") })

        status = .unavailable
        startup.refreshDirectPastePermission()
        XCTAssertEqual(startup.directPasteStatus, .unavailable)
        startup.go(to: .ready)
        XCTAssertTrue(startup.finish(), "An unavailable grant cannot prevent setup completion")
        XCTAssertTrue(startup.startIfReady { _ in })
        XCTAssertEqual(requests, 1, "Finishing must not request Accessibility")
    }
}
