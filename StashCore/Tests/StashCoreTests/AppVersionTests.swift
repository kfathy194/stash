import Foundation
import XCTest
import StashCore

final class AppVersionTests: XCTestCase {
    func testAboutReportsBothValuesFromTheSuppliedBundle() throws {
        try withBundle(["CFBundleShortVersionString": "2.3.7", "CFBundleVersion": "142"]) { bundle in
            XCTAssertEqual(AppVersion.displayString(bundle: bundle), "Version 2.3.7 (142)")
        }
    }

    func testAboutReportsUnavailableFieldsWithoutInventingARelease() throws {
        let examples: [([String: Any], String)] = [
            ([:], "Version unavailable (build unavailable)"),
            (["CFBundleShortVersionString": "2.3.7"], "Version 2.3.7 (build unavailable)"),
            (["CFBundleVersion": "142"], "Version unavailable (142)"),
            (["CFBundleShortVersionString": "", "CFBundleVersion": "  "], "Version unavailable (build unavailable)"),
            (["CFBundleShortVersionString": 12, "CFBundleVersion": 142], "Version unavailable (build unavailable)")
        ]
        for (fields, expected) in examples {
            try withBundle(fields) { bundle in
                XCTAssertEqual(AppVersion.displayString(bundle: bundle), expected)
            }
        }
    }

    private func withBundle(_ fields: [String: Any], check: (Bundle) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = root.appendingPathComponent("Stash.app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var info = fields
        info["CFBundleIdentifier"] = "com.example.stash.fixture.\(UUID().uuidString)"
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try check(XCTUnwrap(Bundle(url: contents.deletingLastPathComponent())))
    }
}
