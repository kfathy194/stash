import Foundation

/// User-facing app identity from the built bundle, independent of local source defaults.
public enum AppVersion {
    public static func displayString(bundle: Bundle) -> String {
        func value(_ key: String) -> String? {
            guard let text = bundle.object(forInfoDictionaryKey: key) as? String else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let version = value("CFBundleShortVersionString") ?? "unavailable"
        let build = value("CFBundleVersion") ?? "build unavailable"
        return "Version \(version) (\(build))"
    }
}
