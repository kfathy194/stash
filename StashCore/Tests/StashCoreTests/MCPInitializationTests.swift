import Foundation
import XCTest
import StashCore

final class MCPInitializationTests: XCTestCase {
    func testInitializationAdvertisesFixtureBundleVersionAndRetainsProtocol() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = root.appendingPathComponent("Stash.app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "com.example.stash.fixture", "CFBundleShortVersionString": "0.1.7", "CFBundleVersion": "49"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: contents.deletingLastPathComponent()))
        let payload = MCPInitialization.payload(bundle: bundle)
        let server = try XCTUnwrap(payload["serverInfo"] as? [String: String])
        XCTAssertEqual(server, ["name": "Stash", "version": "0.1.7"])
        XCTAssertEqual(payload["protocolVersion"] as? String, "2025-03-26")
        let capabilities = try XCTUnwrap(payload["capabilities"] as? [String: [String: Bool]])
        XCTAssertEqual(capabilities, ["tools": ["listChanged": false]])
    }
}
