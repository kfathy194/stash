import Foundation

/// App-owned initialize result. Reading bundle metadata needs no client credential or library access.
public enum MCPInitialization {
    public static func payload(bundle: Bundle) -> [String: Any] {
        ["protocolVersion": "2025-03-26",
         "capabilities": ["tools": ["listChanged": false]],
         "serverInfo": ["name": "Stash", "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"]]
    }
}
