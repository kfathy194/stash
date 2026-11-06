import XCTest
#if os(macOS)
import AppKit
#endif
@testable import StashCore

final class AttachmentResolutionTests: XCTestCase {
    @MainActor func testArchiveRestorationReplacesExistingManagedFileContents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.txt")
        try Data("old bytes".utf8).write(to: source)
        let directory = root.appendingPathComponent("library")
        let item = try FileAssets.importFile(from: source, name: "note.txt", type: "public.plain-text", directory: directory)
        let store = try LibraryStore(directory: directory)
        try store.add(item)
        var restored = item
        restored.data = Data("restored bytes".utf8)
        try store.importArchive(LibraryArchive(items: [restored], pinboards: [], settings: .init()).encode())
        let full = try store.materialized(XCTUnwrap(store.items.first))
        let url = try FileAssets.resolve(full, directory: directory)
        XCTAssertEqual(try Data(contentsOf: url), Data("restored bytes".utf8))
    }
    func testSavedBytesOverrideOutsideURLAndRecreateModifiedOrMissingCopy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = root.appendingPathComponent("outside.txt")
        try Data("outside original".utf8).write(to: original)
        var item = ClipItem(kind: .file, text: "saved")
        item.fileName = "../note.txt"; item.fileURLs = [original.absoluteString]; item.data = Data("saved bytes".utf8)
        let directory = root.appendingPathComponent("library")
        let first = try FileAssets.resolve(item, directory: directory)
        XCTAssertEqual(first.deletingLastPathComponent(), try FileAssets.managedFolder(for: item.id, directory: directory))
        XCTAssertEqual(first.lastPathComponent, "note.txt")
        try Data("edited cache".utf8).write(to: first)
        XCTAssertEqual(try Data(contentsOf: FileAssets.resolve(item, directory: directory)), Data("saved bytes".utf8))
        try FileManager.default.removeItem(at: first)
        XCTAssertEqual(try Data(contentsOf: FileAssets.resolve(item, directory: directory)), Data("saved bytes".utf8))
        XCTAssertEqual(try Data(contentsOf: original), Data("outside original".utf8))
    }

    func testSavedResolutionRejectsSymlinksAtEveryManagedBoundary() throws {
        for component in ["Files", "item", "target", "lock"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let directory = root.appendingPathComponent("library")
            let outside = root.appendingPathComponent("outside")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            let original = outside.appendingPathComponent("original.txt")
            try Data("untouched".utf8).write(to: original)
            var item = ClipItem(kind: .file, text: "file")
            item.fileName = "note.txt"; item.data = Data("saved".utf8)
            let files = directory.appendingPathComponent("Files")
            let folder = files.appendingPathComponent(item.id.uuidString)
            let link: URL
            if component == "Files" { link = files }
            else if component == "lock" { link = directory.appendingPathComponent(".attachment-lock") }
            else {
                try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
                if component == "item" { link = folder }
                else { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true); link = folder.appendingPathComponent("note.txt") }
            }
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: component == "target" || component == "lock" ? original : outside)
            XCTAssertThrowsError(try FileAssets.resolve(item, directory: directory), component)
            XCTAssertEqual(try Data(contentsOf: original), Data("untouched".utf8))
        }
    }

    func testReferenceOnlyURLsAndBookmarksRemainExternalAndMissingOriginalThrows() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = root.appendingPathComponent("original.txt")
        try Data("original".utf8).write(to: original)
        var item = ClipItem(kind: .file, text: "reference")
        item.fileURLs = [original.absoluteString]
        #if os(macOS)
        item.fileBookmarks = [try original.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)]
        #endif
        XCTAssertEqual(try FileAssets.resolve(item, directory: root.appendingPathComponent("library")), original)
        XCTAssertEqual(try Data(contentsOf: original), Data("original".utf8))
        try FileManager.default.removeItem(at: original)
        XCTAssertThrowsError(try FileAssets.resolve(item, directory: root.appendingPathComponent("library")))
    }

    #if os(macOS)
    @MainActor func testMacCopyAndDragWritersUseSavedBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside.txt")
        try Data("stale original".utf8).write(to: outside)
        var item = ClipItem(kind: .file, text: "file")
        item.fileURLs = [outside.absoluteString]; item.fileName = "saved.txt"; item.data = Data("restored saved bytes".utf8)
        let directory = root.appendingPathComponent("library")
        let writers = try FileAssets.pasteboardWriters(for: item, directory: directory)
        XCTAssertEqual(writers.count, 1)
        let representation = try XCTUnwrap(writers.first?.pasteboardPropertyList(forType: .fileURL) as? String)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(URL(string: representation))), Data("restored saved bytes".utf8))
        XCTAssertEqual(try Data(contentsOf: outside), Data("stale original".utf8))
        let provider = try FileAssets.dragProvider(for: item, directory: directory)
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier("public.file-url"))
    }

    @MainActor func testNativePasteboardRoundtripWhenServiceAvailable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var item = ClipItem(kind: .file, text: "saved file")
        item.fileName = "saved.txt"; item.data = Data("restored saved bytes".utf8)
        let writers = try FileAssets.pasteboardWriters(for: item, directory: root)
        let board = NSPasteboard(name: NSPasteboard.Name("StashAttachmentTest-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        guard board.writeObjects(writers) else { throw XCTSkip("Named pasteboard service is unavailable in this process sandbox.") }
        let urls = try XCTUnwrap(board.readObjects(forClasses: [NSURL.self]) as? [URL])
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(urls.first)), Data("restored saved bytes".utf8))
    }
    #endif

}
