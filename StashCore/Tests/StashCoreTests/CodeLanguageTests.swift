import XCTest
@testable import StashCore

final class CodeLanguageTests: XCTestCase {
    func testLegacyPayloadHasNoLanguageAndPlainEditsKeepExistingClassificationRules() throws {
        let original = ClipItem(kind: .code, text: "legacy")
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        payload.removeValue(forKey: "codeLanguage")
        var legacy = try JSONDecoder().decode(ClipItem.self, from: JSONSerialization.data(withJSONObject: payload))
        legacy.updatePlainText("https://example.test")
        XCTAssertEqual(legacy.kind, .code)
        XCTAssertNil(legacy.codeLanguage)
        var ordinary = ClipItem(kind: .richText, text: "old")
        ordinary.updatePlainText("https://example.test")
        XCTAssertEqual(ordinary.kind, .link)
        XCTAssertNil(ordinary.codeLanguage)
    }

    func testPlainEditorUpdateRetainsCodeLanguageAndClearsRichBytes() {
        var item = ClipItem(kind: .code, text: "before")
        item.codeLanguage = "future-language"
        item.richData = Data("obsolete RTF".utf8)
        item.updatePlainText("\t<?php echo 'café'; ?>  \n")
        XCTAssertEqual(item.kind, .code)
        XCTAssertEqual(item.codeLanguage, "future-language")
        XCTAssertEqual(item.text, "\t<?php echo 'café'; ?>  \n")
        XCTAssertNil(item.richData)
    }

    @MainActor func testUnknownLanguageAndExactSourceSurviveLibraryAndArchiveRoundTrips() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = "\t<div data-name='café'>  \r\n</div>\n"
        let original = ClipItem(kind: .code, text: source)
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        payload["codeLanguage"] = "future-language"
        let item = try JSONDecoder().decode(ClipItem.self, from: JSONSerialization.data(withJSONObject: payload))
        let store = try LibraryStore(directory: root)
        let board = try store.createBoard(name: "Generated code")
        try store.add(item)
        try store.pin([item.id], to: board.id)
        let reopened = try LibraryStore(directory: root)
        let restored = try XCTUnwrap(reopened.items.first)
        let restoredPayload = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(restored)) as? [String: Any])
        XCTAssertEqual(restoredPayload["codeLanguage"] as? String, "future-language")
        XCTAssertEqual(restored.text, "\t<div data-name='café'>  \r\n</div>\n")
        let imported = try LibraryStore(inMemory: true)
        try imported.importArchive(reopened.archive())
        let archived = try XCTUnwrap(imported.items.first)
        let archivedPayload = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(archived)) as? [String: Any])
        XCTAssertEqual(archivedPayload["codeLanguage"] as? String, "future-language")
        XCTAssertEqual(archived.kind, .code)
        XCTAssertEqual(archived.text, source)
    }
}
