import Foundation

public enum MCPScope: String, Codable, CaseIterable, Sendable { case readHistory, readPinboards, writeItems }
public struct MCPClient: Identifiable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var scopes: [MCPScope]
    public init(id: UUID = UUID(), name: String, scopes: [MCPScope]) { self.id = id; self.name = name; self.scopes = scopes }
    public func canRead(_ item: ClipItem) -> Bool { (item.isInHistory && scopes.contains(.readHistory)) || (item.pinboardID != nil && scopes.contains(.readPinboards)) }
}
