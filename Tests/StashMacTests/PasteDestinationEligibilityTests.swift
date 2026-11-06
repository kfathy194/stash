import AppKit
import ApplicationServices
import XCTest
@testable import StashMac

/// Generated AX metadata only: no native focus, content, clipboard or event calls.
@MainActor final class PasteDestinationEligibilityTests: XCTestCase {
    func testTerminalSessionCanBeCapturedWithoutAXValueOrSelectedTextWrites() {
        XCTAssertTrue(eligible(), "The observed Terminal session must retain its paste destination instead of triggering manualPasteFallback")
    }

    func testTerminalCapabilitiesDoNotMakeOtherAppsReadOnlyTextAreasEditable() {
        for bundleID in [nil, "com.example.editor", "com.apple.Terminal.other"] {
            XCTAssertFalse(eligible(bundleID: bundleID))
        }
    }

    func testTerminalRequiresAFocusedWindowAndExactTextAreaRole() {
        XCTAssertFalse(eligible(hasFocusedWindow: false))
        for role in [kAXTextFieldRole, kAXComboBoxRole, kAXStaticTextRole, "AXSecureTextField"] {
            XCTAssertFalse(eligible(role: role))
        }
        XCTAssertFalse(eligible(roleResult: .cannotComplete))
    }

    func testTerminalRequiresSuccessfulSettableRangeAndFocusCapabilities() {
        for attribute in [kAXSelectedTextRangeAttribute, kAXFocusedAttribute] {
            XCTAssertFalse(eligible(capabilities: [attribute: (.success, false)]), attribute)
            XCTAssertFalse(eligible(capabilities: [attribute: (.cannotComplete, true)]), attribute)
            XCTAssertFalse(eligible(capabilities: [attribute: (.attributeUnsupported, false)]), attribute)
        }
    }

    func testOrdinaryWritableFieldsRemainEligible() {
        XCTAssertTrue(eligible(bundleID: "com.example.editor", capabilities: [kAXSelectedTextAttribute: (.success, true)]))
        for role in [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole] {
            XCTAssertTrue(eligible(bundleID: "com.example.editor", role: role, capabilities: [kAXValueAttribute: (.success, true)]))
        }
    }

    func testFailedOrdinaryCapabilityReadsDoNotAdmitReadOnlyFields() {
        for attribute in [kAXSelectedTextAttribute, kAXValueAttribute] {
            XCTAssertFalse(eligible(bundleID: "com.example.editor", capabilities: [attribute: (.cannotComplete, true)]))
        }
    }

    private func eligible(bundleID: String? = "com.apple.Terminal", hasFocusedWindow: Bool = true,
                          role: String = kAXTextAreaRole, roleResult: AXError = .success,
                          capabilities: [String: (AXError, Bool)] = [:]) -> Bool {
        let native = PasteService.DestinationAccess(settable: { _, attribute, value in
            let capability = capabilities[attribute as String] ?? (.success, [kAXSelectedTextRangeAttribute, kAXFocusedAttribute].contains(attribute as String))
            value.pointee = DarwinBoolean(capability.1)
            return capability.0
        }, copyValue: { _, _, value in
            value.pointee = role as CFString
            return roleResult
        })
        return PasteService.isEditable(AXUIElementCreateApplication(0), bundleID: bundleID, hasFocusedWindow: hasFocusedWindow, native: native)
    }
}
