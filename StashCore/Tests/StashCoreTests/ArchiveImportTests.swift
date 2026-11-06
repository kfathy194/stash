import XCTest
import AppKit
@testable import StashCore

final class ArchiveImportTests: XCTestCase {
    @MainActor func testPlainArchiveClearsNewerRichTextFromMaterializationAndExport() throws {
        let store = try LibraryStore(inMemory: true)
        let original = ClipItem(kind: .text, text: "saved plain text")
        try store.add(original)
        let archive = try store.archive()
        var newer = original
        newer.kind = .richText
        newer.text = "newer private text"
        newer.richData = try NSAttributedString(string: newer.text).data(
            from: NSRange(location: 0, length: newer.text.utf16.count),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        try store.update(newer, replacingAssets: true)

        try store.importArchive(archive)

        let restored = try store.materialized(XCTUnwrap(store.items.first))
        XCTAssertEqual(restored.text, "saved plain text")
        XCTAssertNil(restored.richData, "The copy path must not receive the newer RTF")
        let exported = try LibraryArchive.decode(store.archive())
        XCTAssertNil(exported.items.first?.richData)
        XCTAssertEqual(exported.items.first?.text, "saved plain text")
    }

    @MainActor func testImportReplacesAndClearsAssetsInPrivateAndSharedCopies() throws {
        for pinned in [false, true] {
            let store = try LibraryStore(inMemory: true)
            let board = try store.createBoard(name: "Saved")
            var item = ClipItem(kind: .file, text: "attachment")
            item.data = Data([1, 2, 3])
            item.richData = Data([4, 5])
            try store.add(item)
            if pinned { try store.pin([item.id], to: board.id) }
            var imported = try store.materialized(XCTUnwrap(store.items.first))
            imported.data = Data([9, 8, 7])
            imported.richData = nil
            let replacement = try LibraryArchive(items: [imported], pinboards: store.pinboards, settings: store.settings).encode()
            try store.importArchive(replacement)
            var restored = try store.materialized(XCTUnwrap(store.items.first))
            XCTAssertEqual(restored.data, Data([9, 8, 7]))
            XCTAssertNil(restored.richData)
            imported.data = nil
            try store.importArchive(LibraryArchive(items: [imported], pinboards: store.pinboards, settings: store.settings).encode())
            restored = try store.materialized(XCTUnwrap(store.items.first))
            XCTAssertNil(restored.data)
            XCTAssertNil(restored.richData)
            if pinned {
                // Removing the shared graph exposes the surviving private representation.
                let object = try XCTUnwrap(store.boardObject(board.id))
                store.context.delete(object)
                try store.context.save()
                try store.reload()
                let privateCopy = try store.materialized(XCTUnwrap(store.items.first))
                XCTAssertNil(privateCopy.data)
                XCTAssertNil(privateCopy.richData)
            }
        }
    }

    @MainActor func testRepeatedVersionOneImportPreservesUnrelatedContentAndDevicePreferences() throws {
        let store = try LibraryStore(inMemory: true)
        let original = ClipItem(kind: .text, text: "saved")
        try store.add(original)
        let archive = try store.archive()
        XCTAssertEqual(try LibraryArchive.decode(archive).version, 1)
        let unrelated = ClipItem(kind: .text, text: "keep unrelated")
        try store.add(unrelated)
        let board = try store.createBoard(name: "New board")
        var current = store.settings
        current.retentionDays = 99
        current.mcpEnabled = true
        current.suggestionsEnabled = true
        try store.updateSettings(current)
        try store.importArchive(archive)
        try store.importArchive(archive)
        XCTAssertEqual(Set(store.items.map(\.id)), Set([original.id, unrelated.id]))
        XCTAssertEqual(store.items.count, 2)
        XCTAssertEqual(store.pinboards.map(\.id), [board.id])
        XCTAssertEqual(store.settings, current)
    }

    @MainActor func testReadOnlySharedImportRollsBackEarlierChanges() throws {
        let store = try LibraryStore(inMemory: true)
        let board = try store.createBoard(name: "Current name")
        let item = ClipItem(kind: .text, text: "current text")
        try store.add(item)
        try store.pin([item.id], to: board.id)
        var imported = item
        imported.pinboardID = board.id
        imported.text = "imported text"
        imported.richData = Data([8, 9])
        var renamed = board
        renamed.name = "Imported name"
        let extra = ClipItem(kind: .text, text: "must roll back")
        let archive = try LibraryArchive(items: [extra, imported], pinboards: [renamed], settings: store.settings).encode()
        store.writePermissionCheck = { $0.entity.name != "SharedClipRecord" }
        XCTAssertThrowsError(try store.importArchive(archive)) { error in
            guard case LibraryStore.StoreError.readOnly = error else { return XCTFail("Expected read-only error, got \(error)") }
        }
        store.writePermissionCheck = nil
        try store.reload()
        XCTAssertEqual(store.items.map(\.id), [item.id])
        XCTAssertEqual(store.pinboards.first?.name, "Current name")
        let restored = try store.materialized(XCTUnwrap(store.items.first))
        XCTAssertEqual(restored.text, "current text")
        XCTAssertNil(restored.richData)
    }
}
