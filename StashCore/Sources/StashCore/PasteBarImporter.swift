import Foundation
import CryptoKit
import CSQLite
import ImageIO

public enum PasteBarImportError: LocalizedError {
    case invalidBackup, unsupportedSchema, archiveLimit, recoveryFailed
    public var errorDescription: String? {
        switch self {
        case .recoveryFailed: "The import failed and recovery could not finish. Reopen Stash before retrying."
        case .invalidBackup: "This is not a valid PasteBar backup."
        case .unsupportedSchema: "This PasteBar database format is not supported."
        case .archiveLimit: "This PasteBar backup exceeds the supported archive size."
        }
    }
}

public struct PasteBarImportSummary: Sendable {
    public internal(set) var importedHistory = 0
    public internal(set) var importedSavedClips = 0
    public internal(set) var importedPinboards = 0
    public internal(set) var duplicates = 0
    public internal(set) var protectedRecords = 0
    public internal(set) var unsupportedRecords = 0
    public internal(set) var missingImages = 0
    public internal(set) var unresolvedFiles = 0
    public internal(set) var needsRefresh = false
    public var message: String {
        "Imported — history: \(importedHistory), saved clips: \(importedSavedClips), pinboards: \(importedPinboards). Skipped — duplicates: \(duplicates), protected: \(protectedRecords), unsupported: \(unsupportedRecords), missing images: \(missingImages). Unresolved file references: \(unresolvedFiles)." + (needsRefresh ? " Saved successfully; reopen Stash to refresh the library view." : "")
    }
}

struct PasteBarImporter: Sendable {
    var items: [ClipItem] = []
    var pinboards: [Pinboard] = []
    var summary = PasteBarImportSummary()
    private var payloadBytes = 0
    private var imageCache: [String: Data] = [:]
    private var cachedBytes = 0

    init(url: URL, now: Date) throws {
        let zip = try PasteBarZIP(url: url)
        guard let database = try zip.contents("pastebar-db.data") else { throw PasteBarImportError.invalidBackup }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("source.sqlite")
        try database.write(to: databaseURL)
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db); throw PasteBarImportError.invalidBackup
        }
        defer { sqlite3_close(db) }
        sqlite3_limit(db, SQLITE_LIMIT_LENGTH, 64 * 1024 * 1024)
        let budget = Unmanaged.passRetained(PasteBarSQLiteBudget())
        sqlite3_progress_handler(db, 1000, { pointer in
            guard let pointer else { return 1 }
            let budget = Unmanaged<PasteBarSQLiteBudget>.fromOpaque(pointer).takeUnretainedValue()
            budget.remaining -= 1
            return budget.remaining > 0 ? 0 : 1
        }, budget.toOpaque())
        defer { sqlite3_progress_handler(db, 0, nil, nil); budget.release() }
        var readBytes = 0
        let history = try Self.rows(db, table: "clipboard_history", required: ["history_id", "value", "is_text", "is_code", "is_link", "is_image"], bytes: &readBytes)
        var seen: Set<String> = []
        for row in history {
            let id = try row.identifier("history_id")
            guard seen.insert(id).inserted else { throw PasteBarImportError.invalidBackup }
            if row.protected { summary.protectedRecords += 1; continue }
            if var item = try content(row, createdAt: now, imageFolder: "clipboard-images", zip: zip) {
                item.id = Self.identity("history", id)
                item.title = row["title"]
                item.sourceAppName = row["copied_from_app"] ?? "PasteBar"
                try append(item)
            }
        }
        if try Self.hasTable(db, "items") {
            let saved = try Self.rows(db, table: "items", required: ["item_id", "name", "value"], bytes: &readBytes)
            let collections = try Self.unique(Self.rows(db, table: "collections", required: ["collection_id", "title"], bytes: &readBytes), key: "collection_id")
            let tabs = try Self.unique(Self.rows(db, table: "tabs", required: ["tab_id", "collection_id", "tab_name"], bytes: &readBytes), key: "tab_id")
            let byID = try Self.unique(saved, key: "item_id")
            let placements = try Self.rows(db, table: "collection_clips", required: ["collection_id", "tab_id", "item_id", "parent_id", "order_number"], bytes: &readBytes)
            guard history.count + saved.count + placements.count <= 100_000 else { throw PasteBarImportError.archiveLimit }
            let groups = Dictionary(grouping: placements) { Self.key([$0["collection_id"] ?? "", $0["tab_id"] ?? ""]) }
            let sortedGroups = groups.keys.sorted { left, right in
                let a = groups[left]!.first!, b = groups[right]!.first!
                let collectionA = a["collection_id"] ?? "", collectionB = b["collection_id"] ?? ""
                if collectionA != collectionB { return collectionA < collectionB }
                let orderA = tabs[a["tab_id"] ?? ""]?.number("tab_order_number") ?? 0
                let orderB = tabs[b["tab_id"] ?? ""]?.number("tab_order_number") ?? 0
                return orderA == orderB ? left < right : orderA < orderB
            }
            for groupKey in sortedGroups {
                guard let group = groups[groupKey], let first = group.first,
                      let collectionID = first["collection_id"], let tabID = first["tab_id"],
                      let collection = collections[collectionID], let tab = tabs[tabID], tab["collection_id"] == collectionID else { throw PasteBarImportError.invalidBackup }
                let members = try Self.unique(group, key: "item_id")
                let boardID = Self.identity("pinboard", groupKey)
                let boardNameBytes = (collection["title"] ?? "Collection").utf8.count + (tab["tab_name"] ?? "Tab").utf8.count + 3
                guard boardNameBytes <= 1024 * 1024, payloadBytes + boardNameBytes <= 256 * 1024 * 1024 else { throw PasteBarImportError.archiveLimit }
                var board = Pinboard(name: (collection["title"] ?? "Collection") + " / " + (tab["tab_name"] ?? "Tab"))
                board.id = boardID
                board.order = Double(pinboards.count)
                if let color = Self.tabColor(tab["tab_color"]) { board.colorHex = color }
                let before = items.count
                for placement in try Self.flattenedPlacements(group, members: members) {
                    let itemID = try placement.identifier("item_id")
                    guard let row = byID[itemID] else { throw PasteBarImportError.invalidBackup }
                    if row.structural || row.flag("is_deleted") { continue }
                    var ancestor = placement["parent_id"], path: [String] = [], visited: Set<String> = [itemID]
                    var protected = tab.flag("tab_is_protected") || row.protected
                    while let parent = ancestor, !parent.isEmpty {
                        guard visited.count <= 256 else { throw PasteBarImportError.archiveLimit }
                        guard visited.insert(parent).inserted, let parentRow = byID[parent], let membership = members[parent] else { throw PasteBarImportError.invalidBackup }
                        protected = protected || parentRow.protected
                        if let name = parentRow["name"], !name.isEmpty { path.insert(name, at: 0) }
                        ancestor = membership["parent_id"]
                    }
                    if protected { summary.protectedRecords += 1; continue }
                    if row.dynamic { summary.unsupportedRecords += 1; continue }
                    let createdAt = row.date("created_at") ?? now
                    if var item = try content(row, createdAt: createdAt, imageFolder: "clip-images", zip: zip) {
                        item.id = Self.identity("saved", Self.key([collectionID, tabID, itemID]))
                        item.pinboardID = boardID; item.isInHistory = false
                        let title = path + [row["name"] ?? "Clip"]
                        let titleBytes = title.reduce(0) { $0 + $1.utf8.count } + max(0, title.count - 1) * 3
                        guard titleBytes <= 1024 * 1024, payloadBytes + titleBytes <= 256 * 1024 * 1024 else { throw PasteBarImportError.archiveLimit }
                        item.title = title.joined(separator: " / ")
                        item.order = Double(items.count - before)
                        item.modifiedAt = row.date("updated_at") ?? createdAt
                        item.sourceAppName = "PasteBar"
                        try append(item)
                    }
                }
                if items.count > before {
                    payloadBytes += boardNameBytes
                    guard payloadBytes <= 256 * 1024 * 1024 else { throw PasteBarImportError.archiveLimit }
                    pinboards.append(board)
                }
            }
            let placed = Set(placements.compactMap { $0["item_id"] })
            for row in saved where !placed.contains(row["item_id"] ?? "") && !row.structural && !row.flag("is_deleted") {
                if row.protected { summary.protectedRecords += 1 } else { summary.unsupportedRecords += 1 }
            }
        }
    }

    private static func flattenedPlacements(_ group: [PasteBarRow], members: [String: PasteBarRow]) throws -> [PasteBarRow] {
        var children: [String: [PasteBarRow]] = [:]
        for placement in group {
            let parent = placement["parent_id"] ?? ""
            guard parent.isEmpty || members[parent] != nil else { throw PasteBarImportError.invalidBackup }
            children[parent, default: []].append(placement)
        }
        for parent in children.keys {
            children[parent]!.sort {
                let a = $0.number("order_number"), b = $1.number("order_number")
                return a == b ? ($0["item_id"] ?? "") < ($1["item_id"] ?? "") : a < b
            }
        }
        var pending = (children[""] ?? []).reversed().map { ($0, 0) }
        var result: [PasteBarRow] = []
        while let (placement, depth) = pending.popLast() {
            guard depth <= 256 else { throw PasteBarImportError.archiveLimit }
            result.append(placement)
            for child in (children[placement["item_id"] ?? ""] ?? []).reversed() { pending.append((child, depth + 1)) }
        }
        guard result.count == group.count else { throw PasteBarImportError.invalidBackup }
        return result
    }
    private static func tabColor(_ value: String?) -> String? {
        guard let value else { return nil }
        if ContentClassifier.kind(for: value) == .color { return value.replacingOccurrences(of: "#", with: "") }
        // PasteBar stores palette names; use their representative Tailwind 500 shades.
        return ["slate": "64748B", "sky": "0EA5E9", "stone": "78716C", "teal": "14B8A6",
                "indigo": "6366F1", "green": "22C55E", "yellow": "EAB308", "blue": "3B82F6",
                "purple": "A855F7", "rose": "F43F5E", "lime": "84CC16", "emerald": "10B981",
                "amber": "F59E0B", "cyan": "06B6D4", "fuchsia": "D946EF", "pink": "EC4899"][value.lowercased()]
    }

    private mutating func content(_ row: PasteBarRow, createdAt: Date, imageFolder: String, zip: PasteBarZIP) throws -> ClipItem? {
        let text = row["value"] ?? ""
        var item = ClipItem(kind: row.flag("is_code") ? .code : row.flag("is_link") ? .link : ContentClassifier.kind(for: text), text: text, createdAt: createdAt)
        if row.flag("is_image") {
            var bytes: Data?
            if let path = row["image_path_full_res"] {
                let normalized = path.replacingOccurrences(of: "\\", with: "/")
                if let range = normalized.range(of: imageFolder + "/") {
                    let key = String(normalized[range.lowerBound...])
                    if let cached = imageCache[key] { bytes = cached }
                    else if let loaded = try zip.contents(key) {
                        cachedBytes += loaded.count
                        guard cachedBytes <= 256 * 1024 * 1024 else { throw PasteBarImportError.archiveLimit }
                        imageCache[key] = loaded; bytes = loaded
                    }
                }
            }
            if bytes == nil, let uri = row["image_data_url"], let comma = uri.firstIndex(of: ","), uri.hasPrefix("data:image/"), uri[..<comma].hasSuffix(";base64") {
                let encoded = String(uri[uri.index(after: comma)...])
                bytes = Data(base64Encoded: encoded + String(repeating: "=", count: (4 - encoded.count % 4) % 4))
            }
            if bytes == nil { bytes = row.blobs["image_data_low_res"] }
            if let bytes, let source = CGImageSourceCreateWithData(bytes as CFData, nil), CGImageSourceGetCount(source) > 0,
               let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
               let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
               width > 0, height > 0, width <= 32768, height <= 32768, width * height <= 100_000_000,
               let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 400] as CFDictionary) {
                item.kind = .image; item.data = bytes; item.byteCount = bytes.count; item.imageWidth = width; item.imageHeight = height
                let preview = NSMutableData()
                if let destination = CGImageDestinationCreateWithData(preview, "public.png" as CFString, 1, nil) {
                    CGImageDestinationAddImage(destination, thumbnail, nil)
                    if CGImageDestinationFinalize(destination) { item.thumbnail = preview as Data }
                }
            } else {
                summary.missingImages += 1
                if text.isEmpty || row.flag("is_image_data") { return nil }
            }
        } else if !row.flag("is_code"), !row.flag("is_link"), let path = Self.fileReference(text) {
            item.kind = .file; item.fileURLs = [path.absoluteString]; item.fileName = path.lastPathComponent
            if (path.host != nil && path.host != "localhost") || text.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil || !FileManager.default.fileExists(atPath: path.path) { summary.unresolvedFiles += 1 }
        } else if text.isEmpty || row.flag("is_file") || row.flag("is_path") { summary.unsupportedRecords += 1; return nil }
        return item
    }
    private mutating func append(_ item: ClipItem) throws {
        let metadata = [item.text, item.title ?? "", item.sourceAppID, item.sourceAppName, item.device,
                        item.fileName ?? "", item.fileTypeIdentifier ?? "", item.linkTitle ?? "", item.linkDomain ?? "", item.ocrText]
        payloadBytes += metadata.reduce(0) { $0 + $1.utf8.count } + item.fileURLs.reduce(0) { $0 + $1.utf8.count }
            + item.fileBookmarks.reduce(0) { $0 + $1.count } + (item.richData?.count ?? 0) + (item.data?.count ?? 0) + (item.thumbnail?.count ?? 0)
        guard payloadBytes <= 256 * 1024 * 1024 else { throw PasteBarImportError.archiveLimit }
        items.append(item)
    }
    private static func key(_ parts: [String]) -> String { parts.map { "\($0.utf8.count):\($0)" }.joined() }
    private static func unique(_ rows: [PasteBarRow], key: String) throws -> [String: PasteBarRow] {
        var result: [String: PasteBarRow] = [:]
        for row in rows { let id = try row.identifier(key); guard result.updateValue(row, forKey: id) == nil else { throw PasteBarImportError.invalidBackup } }
        return result
    }
    private static func hasTable(_ db: OpaquePointer?, _ table: String) throws -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT type,sql FROM sqlite_master WHERE type IN ('table','view') AND name=?", -1, &statement, nil) == SQLITE_OK else { throw PasteBarImportError.unsupportedSchema }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, table, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return false }
        guard step == SQLITE_ROW, let type = sqlite3_column_text(statement, 0), String(cString: type) == "table", let sql = sqlite3_column_text(statement, 1), String(cString: sql).uppercased().hasPrefix("CREATE TABLE") else { throw PasteBarImportError.unsupportedSchema }
        return true
    }
    private static func rows(_ db: OpaquePointer?, table: String, required: Set<String>, bytes: inout Int) throws -> [PasteBarRow] {
        guard try hasTable(db, table) else { throw PasteBarImportError.unsupportedSchema }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT * FROM " + table, -1, &statement, nil) == SQLITE_OK else { throw PasteBarImportError.unsupportedSchema }
        defer { sqlite3_finalize(statement) }
        let columns = (0..<sqlite3_column_count(statement)).map { String(cString: sqlite3_column_name(statement, $0)) }
        guard required.isSubset(of: Set(columns)) else { throw PasteBarImportError.unsupportedSchema }
        var rows: [PasteBarRow] = []
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            guard rows.count < 100_000 else { throw PasteBarImportError.archiveLimit }
            var row = PasteBarRow()
            for position in columns.indices {
                let column = Int32(position), size = Int(sqlite3_column_bytes(statement, column))
                bytes += size
                guard bytes <= 256 * 1024 * 1024 else { throw PasteBarImportError.archiveLimit }
                if sqlite3_column_type(statement, column) == SQLITE_BLOB, let pointer = sqlite3_column_blob(statement, column) { row.blobs[columns[position]] = Data(bytes: pointer, count: size) }
                else if sqlite3_column_type(statement, column) != SQLITE_NULL {
                    guard let pointer = sqlite3_column_text(statement, column), let value = String(data: Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, column))), encoding: .utf8) else { throw PasteBarImportError.invalidBackup }
                    row.strings[columns[position]] = value
                }
            }
            rows.append(row); step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE else { throw PasteBarImportError.invalidBackup }
        return rows
    }
    static func identity(_ table: String, _ sourceID: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(("Stash/PasteBar/" + table + "/" + sourceID).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x80; bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }
    static func fileReference(_ value: String) -> URL? {
        guard !value.contains("\0") else { return nil }
        let normalized = value.replacingOccurrences(of: "\\", with: "/")
        if value.hasPrefix("\\\\") {
            let parts = normalized.dropFirst(2).split(separator: "/", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            var components = URLComponents()
            components.scheme = "file"; components.host = String(parts[0]); components.path = "/" + parts[1]
            return components.url
        }
        if value.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil { return URL(fileURLWithPath: "/" + normalized) }
        if value.hasPrefix("file://"), let url = URL(string: value), url.isFileURL { return url }
        if value.hasPrefix("/") { return URL(fileURLWithPath: value) }
        return nil
    }
}

private struct PasteBarRow {
    var strings: [String: String] = [:]
    var blobs: [String: Data] = [:]
    subscript(_ key: String) -> String? { strings[key] }
    func flag(_ key: String) -> Bool { self[key] == "1" }
    func number(_ key: String) -> Double {
        guard let string = self[key], let value = Double(string), value.isFinite else { return 0 }
        return value
    }
    var protected: Bool { flag("is_protected") || flag("is_masked") || flag("has_masked_words") || (self["value"] ?? "").localizedCaseInsensitiveContains("[mask]") }
    var structural: Bool { ["is_folder", "is_board", "is_separator", "is_menu"].contains(where: flag) }
    var dynamic: Bool { ["is_command", "is_form", "is_template", "is_web_request", "is_web_scraping"].contains(where: flag) }
    func identifier(_ key: String) throws -> String {
        guard let value = self[key], !value.isEmpty else { throw PasteBarImportError.invalidBackup }; return value
    }
    func date(_ key: String) -> Date? {
        guard let string = self[key], let value = Double(string), value.isFinite else { return nil }
        return Date(timeIntervalSince1970: value > 100_000_000_000 ? value / 1000 : value)
    }
}

private final class PasteBarSQLiteBudget { var remaining = 100_000 }
