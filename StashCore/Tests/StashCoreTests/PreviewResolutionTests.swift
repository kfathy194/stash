import XCTest
#if os(macOS)
import AppKit
#endif
@testable import StashCore

/// Supporting resolution contract for the Mac preview action (#62).
///
/// The preview materializes the requested item through `LibraryStore` and
/// resolves file content through `FileAssets`. These tests pin that public
/// seam for generated History and Pinboard items — including items that were
/// never selected — and for the unavailable-content cases the preview must
/// surface. They do not exercise the panel selection state, because preview
/// resolution is invoked with the item identity directly.
final class PreviewResolutionTests: XCTestCase {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @MainActor func testPreviewMaterializesRetainedContentForHistoryAndPinnedItems() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(directory: root.appendingPathComponent("library"))
        var note = ClipItem(kind: .text, text: "generated history note")
        note.title = "Generated note"
        try store.add(note)
        #if os(macOS)
        let rich = NSAttributedString(string: "generated rich body", attributes: [.font: NSFont.systemFont(ofSize: 12)])
        var document = ClipItem(kind: .richText, text: "generated rich body")
        document.richData = rich.rtf(from: NSRange(location: 0, length: rich.string.utf16.count))
        try store.add(document)
        #endif
        var snippet = ClipItem(kind: .code, text: "let preview = true")
        try store.add(snippet)
        let board = try store.createBoard(name: "Preview board", colorHex: "30B7A8")
        try store.pin([snippet.id], to: board.id)

        // Resolve each item directly by identity, as the preview action does:
        // prior panel selection plays no part in resolution.
        let historyItem = try XCTUnwrap(store.results().first { $0.id == note.id })
        XCTAssertEqual(try store.materialized(historyItem).text, "generated history note")
        #if os(macOS)
        let richItem = try XCTUnwrap(store.results().first { $0.id == document.id })
        let richData = try XCTUnwrap(try store.materialized(richItem).richData)
        let decoded = try NSAttributedString(data: richData, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        XCTAssertEqual(decoded.string, "generated rich body")
        #endif
        let pinned = try XCTUnwrap(store.results(boardID: board.id).first { $0.id == snippet.id })
        XCTAssertEqual(try store.materialized(pinned).text, "let preview = true")
    }

    @MainActor func testPreviewReportsImageItemsWhoseSavedBytesAreMissing() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(directory: root.appendingPathComponent("library"))
        #if os(macOS)
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus(); NSColor.red.setFill(); NSBezierPath(rect: NSRect(x: 0, y: 0, width: 4, height: 4)).fill(); image.unlockFocus()
        #else
        let image = NSObject()
        #endif
        var item = ClipItem(kind: .image, text: "")
        #if os(macOS)
        item.data = image.tiffRepresentation
        #endif
        item.byteCount = item.data?.count ?? 0
        try store.add(item)
        // Loss of the saved bytes is the state a preview must report instead of
        // silently rendering an empty window.
        item.data = nil; item.byteCount = 0
        try store.update(item, replacingAssets: true)
        let requested = try XCTUnwrap(store.items.first { $0.id == item.id })
        let full = try store.materialized(requested)
        XCTAssertNil(full.data, "A preview must detect that the saved image bytes are gone.")
    }

    @MainActor func testPreviewFileResolutionRestoresSavedAttachmentWithoutOverwritingOriginals() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("outside original.txt")
        try Data("original bytes".utf8).write(to: original)
        var item = ClipItem(kind: .file, text: "saved attachment")
        item.fileName = "note.txt"
        item.fileURLs = [original.absoluteString]
        item.data = Data("saved attachment bytes".utf8)
        item.byteCount = item.data?.count ?? 0
        let directory = root.appendingPathComponent("library")
        let store = try LibraryStore(directory: directory)
        try store.add(item)

        // Resolve as the preview does, including after the managed copy is gone.
        let requested = try XCTUnwrap(store.items.first { $0.id == item.id })
        let full = try store.materialized(requested)
        let resolved = try FileAssets.resolve(full, directory: directory)
        XCTAssertEqual(try Data(contentsOf: resolved), Data("saved attachment bytes".utf8))
        try FileManager.default.removeItem(at: resolved)
        let again = try store.materialized(XCTUnwrap(store.items.first { $0.id == item.id }))
        XCTAssertEqual(try Data(contentsOf: try FileAssets.resolve(again, directory: directory)), Data("saved attachment bytes".utf8))
        // Resolving a preview never rewrites the user's original file.
        XCTAssertEqual(try Data(contentsOf: original), Data("original bytes".utf8))
        let after = try store.materialized(XCTUnwrap(store.items.first { $0.id == item.id }))
        XCTAssertEqual(after.data, Data("saved attachment bytes".utf8))
    }

    @MainActor func testPreviewSurfacesUnavailableExternalFileReferences() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("removed original.txt")
        var item = ClipItem(kind: .file, text: "external reference")
        item.fileName = "removed original.txt"
        item.fileURLs = [missing.absoluteString]
        #if os(macOS)
        if let bookmark = try? missing.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) { item.fileBookmarks = [bookmark] }
        #endif
        let directory = root.appendingPathComponent("library")
        let store = try LibraryStore(directory: directory)
        try store.add(item)
        let requested = try XCTUnwrap(store.items.first { $0.id == item.id })
        let full = try store.materialized(requested)
        XCTAssertThrowsError(try FileAssets.resolve(full, directory: directory)) { error in
            XCTAssertEqual((error as? CocoaError)?.code, .fileNoSuchFile, "An inaccessible reference must be reported, not silently rendered empty.")
        }
    }

    #if os(macOS)
    @MainActor func testPreviewManagedCopiesNeedNoSecurityScopedAccess() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var item = ClipItem(kind: .file, text: "saved attachment")
        item.fileName = "note.txt"
        item.data = Data("saved attachment bytes".utf8)
        item.byteCount = item.data?.count ?? 0
        let directory = root.appendingPathComponent("library")
        let store = try LibraryStore(directory: directory)
        try store.add(item)
        let resolved = try FileAssets.resolve(try store.materialized(XCTUnwrap(store.items.first { $0.id == item.id })), directory: directory)
        // Saved attachments materialize inside Stash's own library directory, so
        // a preview of the managed copy must read without depending on a scoped
        // grant. The preview additionally holds and balances any scope the
        // system offers for the URL for the whole window lifetime.
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: resolved.path), "A managed copy must be readable for preview without any scoped grant.")
        XCTAssertEqual(try Data(contentsOf: resolved), Data("saved attachment bytes".utf8))
    }
    #endif
}
