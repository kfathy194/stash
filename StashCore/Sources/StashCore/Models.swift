import Foundation

public enum ClipKind: String, Codable, CaseIterable, Sendable {
    case text, richText, link, image, file, color, code
    public var label: String { switch self { case .richText: "Rich Text"; default: rawValue.capitalized } }
    public var symbol: String { switch self { case .text: "text.alignleft"; case .richText: "textformat"; case .link: "link"; case .image: "photo"; case .file: "doc"; case .color: "paintpalette"; case .code: "chevron.left.forwardslash.chevron.right" } }
}

public struct ClipItem: Identifiable, Codable, Hashable, Sendable {
    public var id = UUID()
    public var kind: ClipKind
    public var codeLanguage: String?
    public var text: String
    public var title: String?
    public var creatorClientID: UUID?
    public var richData: Data?
    public var data: Data?
    public var thumbnail: Data?
    public var fileURLs: [String] = []
    public var fileName: String?
    public var fileTypeIdentifier: String?
    public var fileBookmarks: [Data] = []
    public var sourceAppID: String = ""
    public var sourceAppName: String = "Unknown app"
    public var device: String = ""
    public var createdAt: Date
    public var modifiedAt: Date
    public var pinboardID: UUID?
    public var isInHistory = true
    public var order: Double = 0
    public var linkTitle: String?
    public var linkDomain: String?
    public var ocrText = ""
    public var imageWidth: Int = 0
    public var imageHeight: Int = 0
    public var byteCount: Int = 0
    public init(kind: ClipKind, text: String = "", createdAt: Date = .now) {
        self.kind = kind; self.text = text; self.createdAt = createdAt; self.modifiedAt = createdAt
    }
    public mutating func updatePlainText(_ text: String) {
        self.text = text
        if kind != .code {
            kind = ContentClassifier.kind(for: text)
            codeLanguage = nil
        }
        richData = nil
    }
    public var displayTitle: String { title.flatMap { $0.isEmpty ? nil : $0 } ?? linkTitle ?? (kind == .file ? (fileURLs.first.flatMap(URL.init(string:))?.lastPathComponent ?? "File") : kind.label) }
    public var searchableText: String { [title ?? "", text, linkTitle ?? "", linkDomain ?? "", ocrText, fileURLs.joined(separator: " "), sourceAppName, device].joined(separator: "\n") }
    public var metadata: String {
        if kind == .image { return "\(imageWidth) × \(imageHeight) · \(ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file))" }
        if kind == .file { return ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file) }
        return "\(text.count.formatted()) characters"
    }
}

public struct Pinboard: Identifiable, Codable, Hashable, Sendable {
    public var id = UUID()
    public var name: String
    public var colorHex: String
    public var order: Double
    public var createdAt = Date()
    public init(name: String, colorHex: String = "30B7A8", order: Double = 0) { self.name = name; self.colorHex = colorHex; self.order = order }
}

public struct KeyBinding: Codable, Hashable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32
    public init(keyCode: UInt32, modifiers: UInt32) { self.keyCode = keyCode; self.modifiers = modifiers }
}

public struct LibrarySettings: Codable, Equatable, Sendable {
    public var retentionDays: Int? = 30
    public var pausedUntil: Date?
    public var pausedIndefinitely = false
    public var ignoreConfidential = true
    public var ignoreTransient = true
    public var ignoredApplications = ["com.agilebits.onepassword7", "com.1password.1password", "com.bitwarden.desktop", "com.dashlane.Dashlane", "org.keepassxc.keepassxc", "com.apple.Passwords"]
    public var showMenuBarIcon = true
    public var runInBackground = true
    public var syncEnabled = false
    public var suggestionsEnabled = false
    public var mcpEnabled = false
    public var onboardingComplete = false
    public var panelHeight: Double = 350
    public var quickPasteModifier = "command"
    public var plainTextModifier = "shift"
    // Carbon cmdKey = 256, shiftKey = 512, optionKey = 2048, controlKey = 4096
    public var panelShortcut = KeyBinding(keyCode: 9, modifiers: 768)
    public var stackShortcut = KeyBinding(keyCode: 8, modifiers: 768)
    public var nextBoardShortcut = KeyBinding(keyCode: 124, modifiers: 256)
    public var previousBoardShortcut = KeyBinding(keyCode: 123, modifiers: 256)
    public init() {}
    public func isPaused(at date: Date = .now) -> Bool { pausedIndefinitely || (pausedUntil.map { $0 > date } ?? false) }
}

public struct SearchFilter: Equatable, Sendable {
    public var kind: ClipKind?
    public var sourceAppID: String?
    public var device: String?
    public var after: Date?
    public var before: Date?
    public init() {}
    public func matches(_ item: ClipItem) -> Bool {
        (kind == nil || item.kind == kind) && (sourceAppID == nil || item.sourceAppID == sourceAppID) && (device == nil || item.device == device) && (after == nil || item.createdAt >= after!) && (before == nil || item.createdAt <= before!)
    }
    public var isEmpty: Bool { self == SearchFilter() }
}

public struct LibraryArchive: Codable, Sendable {
    public var version = 1
    public var items: [ClipItem]
    public var pinboards: [Pinboard]
    public var settings: LibrarySettings
    public init(items: [ClipItem], pinboards: [Pinboard], settings: LibrarySettings) { self.items = items; self.pinboards = pinboards; self.settings = settings }
    public func encode() throws -> Data { try JSONEncoder().encode(self) }
    public static func decode(_ data: Data) throws -> LibraryArchive {
        let archive = try JSONDecoder().decode(Self.self, from: data)
        guard archive.version == 1 else { throw ArchiveError.unsupportedVersion }
        guard Set(archive.items.map(\.id)).count == archive.items.count, Set(archive.pinboards.map(\.id)).count == archive.pinboards.count else { throw ArchiveError.duplicateIdentifiers }
        let boards = Set(archive.pinboards.map(\.id))
        guard archive.items.allSatisfy({ $0.pinboardID == nil || boards.contains($0.pinboardID!) }) else { throw ArchiveError.missingPinboard }
        return archive
    }
    public enum ArchiveError: Error { case unsupportedVersion, duplicateIdentifiers, missingPinboard }
}
