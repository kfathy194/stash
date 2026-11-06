import AppKit
import ApplicationServices
import SwiftUI

/// Accessibility is system-owned state. It is never a setting in an onboarding draft.
@MainActor struct DirectPastePermission {
    enum Status {
        case notGranted
        case granted
        case unavailable
    }

    let status: () -> Status
    let request: () -> Void

    static let system = Self(
        status: { AXIsProcessTrusted() ? .granted : .notGranted },
        request: {
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
    )
}

struct OnboardingDirectPasteView: View {
    let startup: MacStartup

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("Direct paste")
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
            Text("Accessibility lets Stash paste a selected clip into the compatible app you were using.")
                .foregroundStyle(.secondary)

            switch startup.directPasteStatus {
            case .granted:
                Label("Accessibility granted", systemImage: "checkmark.circle.fill")
            case .notGranted:
                Label("Accessibility not granted", systemImage: "lock")
                Button("Request Accessibility") { startup.requestDirectPastePermission() }
                    .buttonStyle(.bordered)
                Text("In System Settings → Privacy & Security → Accessibility, turn on Stash. Return here to check access.")
                    .foregroundStyle(.secondary)
            case .unavailable:
                Label("Accessibility status unavailable", systemImage: "exclamationmark.circle")
            }

            Text("To paste manually, select a clip with the arrow keys and press ⌘C. Then switch to your destination app and press ⌘V.")
            Text("Changes to Accessibility apply immediately in macOS and remain in effect if you discard this setup draft.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
