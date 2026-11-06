import Foundation
import Darwin
#if os(macOS)
import AppKit
#endif

public enum FileAssets {
    /// Serialize attachment work across the application and extensions. The library root
    /// is trusted; children and the lock file must never redirect through a symlink.
    /// This lock is not reentrant: do not call resolve/importFile from its body.
    public static func withManagedAccess<T>(directory: URL, _ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lock = directory.resolvingSymlinksInPath().appendingPathComponent(".attachment-lock")
        let descriptor = open(lock.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw CocoaError(.fileWriteNoPermission) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    /// Computes the owned directory from identity, never an archived absolute path.
    /// Call inside withManagedAccess when using the result for filesystem mutations.
    public static func managedFolder(for itemID: UUID, directory: URL) throws -> URL {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let files = root.appendingPathComponent("Files", isDirectory: true)
        let folder = files.appendingPathComponent(itemID.uuidString, isDirectory: true)
        try requireDirectoryIfPresent(files)
        try requireDirectoryIfPresent(folder)
        return folder
    }

    private static func requireDirectoryIfPresent(_ url: URL) throws {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw CocoaError(.fileWriteNoPermission) }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return }
    }

    private static func managedURL(for item: ClipItem, directory: URL) throws -> URL {
        let folder = try managedFolder(for: item.id, directory: directory)
        let name = String(URL(fileURLWithPath: item.fileName ?? "File").lastPathComponent.prefix(180))
        let target = folder.appendingPathComponent(name.isEmpty || name == "." || name == ".." || name == "/" ? "File" : name)
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw CocoaError(.fileWriteNoPermission) }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { }
        return target
    }

    struct ManagedReference: Hashable {
        let ownerID: UUID
        let name: String
    }
    struct ManagedCopy {
        let reference: ManagedReference
        let data: Data
    }

    // These helpers run inside the library's managed lock. They never acquire it again.
    static func managedReferences(for item: ClipItem, directory: URL) throws -> Set<ManagedReference> {
        guard item.kind == .file, item.data == nil else { return [] }
        var urls = item.fileURLs.compactMap(URL.init(string:))
        #if os(macOS)
        // Ownership inspection needs a path, not a new security grant. Only paths
        // inside our already accessible library are accepted below.
        for offset in item.fileURLs.indices {
            var stale = false
            if let bookmark = FileBookmarks.bookmark(at: offset, in: item.fileBookmarks),
               let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) {
                urls.append(url)
            }
        }
        #endif
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        var references: Set<ManagedReference> = []
        for raw in urls where raw.isFileURL {
            let url = raw.standardizedFileURL
            let folder = url.deletingLastPathComponent()
            let files = folder.deletingLastPathComponent()
            guard files.lastPathComponent == "Files",
                  files.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL == root,
                  let id = UUID(uuidString: folder.lastPathComponent) else { continue }
            let reference = ManagedReference(ownerID: id, name: url.lastPathComponent)
            _ = try managedURL(for: reference, directory: directory)
            references.insert(reference)
        }
        return references
    }

    private static func managedURL(for reference: ManagedReference, directory: URL) throws -> URL {
        let folder = try managedFolder(for: reference.ownerID, directory: directory)
        let target = folder.appendingPathComponent(reference.name)
        guard target.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL else {
            throw CocoaError(.fileWriteNoPermission)
        }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw CocoaError(.fileWriteNoPermission) }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { }
        return target
    }

    static func recoveryCopies(for item: ClipItem, directory: URL) throws -> [ManagedCopy] {
        try managedReferences(for: item, directory: directory).compactMap { reference in
            let url = try managedURL(for: reference, directory: directory)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return ManagedCopy(reference: reference, data: try Data(contentsOf: url))
        }
    }

    /// Only missing working copies are recreated. Existing later contents always survive undo.
    static func restore(_ copy: ManagedCopy, directory: URL) throws -> Bool {
        let url = try managedURL(for: copy.reference, directory: directory)
        guard !FileManager.default.fileExists(atPath: url.path) else { return false }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try copy.data.write(to: url, options: .atomic)
        return true
    }

    static func removeRestored(_ reference: ManagedReference, directory: URL) throws {
        let url = try managedURL(for: reference, directory: directory)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    /// Preserve provider bytes before its completion block returns.
    public static func importFile(from source: URL, name: String, type: String, directory: URL) throws -> ClipItem {
        var item = ClipItem(kind: .file, text: URL(fileURLWithPath: name).lastPathComponent)
        let safe = String(URL(fileURLWithPath: name).lastPathComponent.prefix(180))
        item.fileName = safe.isEmpty || safe == "." || safe == ".." || safe == "/" ? "File" : safe
        item.fileTypeIdentifier = type
        item.data = try Data(contentsOf: source)
        item.byteCount = item.data?.count ?? 0
        item.fileURLs = [try resolve(item, directory: directory).absoluteString]
        return item
    }

    public static func resolve(_ item: ClipItem, directory: URL) throws -> URL {
        if let data = item.data {
            return try withManagedAccess(directory: directory) {
                let target = try managedURL(for: item, directory: directory)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                // Atomic replacement also breaks any hard link instead of modifying its original.
                try data.write(to: target, options: .atomic)
                return target
            }
        }
        guard let first = try resolvedURLs(for: item, directory: directory).first else { throw CocoaError(.fileNoSuchFile) }
        return first
    }

    /// Shared file-selection boundary for copy and drag. Saved bytes take precedence
    /// over all archived URLs/bookmarks; reference-only clips preserve URL positions.
    public static func resolvedURLs(for item: ClipItem, directory: URL) throws -> [URL] {
        if item.data != nil { return [try resolve(item, directory: directory)] }
        guard !item.fileURLs.isEmpty else { throw CocoaError(.fileNoSuchFile) }
        return try item.fileURLs.enumerated().map { offset, raw in
            var candidate = URL(string: raw)
            #if os(macOS)
            var stale = false
            if let bookmark = FileBookmarks.bookmark(at: offset, in: item.fileBookmarks),
               let resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) { candidate = resolved }
            #endif
            guard let url = candidate, url.isFileURL else { throw CocoaError(.fileNoSuchFile) }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            guard FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileNoSuchFile) }
            return url
        }
    }

    #if os(macOS)
    /// The native file writers used by Mac copy, independently testable on a named pasteboard.
    public static func pasteboardWriters(for item: ClipItem, directory: URL) throws -> [NSURL] {
        try resolvedURLs(for: item, directory: directory).map { $0 as NSURL }
    }
    public static func dragProvider(for item: ClipItem, directory: URL) throws -> NSItemProvider {
        guard let url = try resolvedURLs(for: item, directory: directory).first,
              let provider = NSItemProvider(contentsOf: url) else { throw CocoaError(.fileReadUnknown) }
        return provider
    }
    #endif
}
