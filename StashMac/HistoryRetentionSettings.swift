import SwiftUI
import AppKit
import StashCore

struct HistoryRetentionSettings: View {
    let store: LibraryStore
    let saveSettings: ((inout LibrarySettings) -> Void) -> Bool
    let reportError: (String) -> Void
    @State private var editingCustomRetention = false
    @State private var customRetentionText = ""
    @State private var customRetentionError: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Picker("Keep history", selection: Binding(get: { retentionSelection }, set: { selectRetention($0) })) { Text("1 Day").tag(1); Text("1 Week").tag(7); Text("1 Month").tag(30); Text("1 Year").tag(365); Text("Forever").tag(0); Text(customMenuTitle).tag(Self.customRetentionTag) }.frame(maxWidth: 300)
                if isCustomRetentionSelected { Button("Edit…", action: beginCustomRetention).accessibilityLabel("Edit custom history period") }
            }
            if editingCustomRetention { customRetentionEditor }
            Text("Pinned items stay until you remove them. There is no item-count limit.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func changeRetention(_ days: Int) {
        let shorter = days != 0 && (store.settings.retentionDays == nil || days < store.settings.retentionDays!)
        let expired = store.items.contains { $0.pinboardID == nil && Retention.action(for: $0, days: days, now: .now) == .delete }
        if shorter && expired && !confirm("Delete older history?", message: "Items older than the new limit will be permanently deleted. Pinboards are kept.", button: "Delete Older Items") { return }
        guard saveSettings({ $0.retentionDays = days == 0 ? nil : days }) else { return }
        do { try store.applyRetention() } catch { store.context.rollback(); reportError(error.localizedDescription) }
    }
    // The picker's day presets; Forever is stored as nil and Custom as any other positive count.
    private static let presetDays: Set<Int> = [1, 7, 30, 365]
    private static let customRetentionTag = -1
    private var isCustomRetentionSelected: Bool {
        guard let days = store.settings.retentionDays else { return false }
        return days > 0 && !Self.presetDays.contains(days)
    }
    private var retentionSelection: Int {
        guard let days = store.settings.retentionDays else { return 0 }
        return Self.presetDays.contains(days) ? days : Self.customRetentionTag
    }
    private var customMenuTitle: String {
        guard isCustomRetentionSelected, let days = store.settings.retentionDays else { return "Custom…" }
        return "Custom… (\(days) days)"
    }
    private func selectRetention(_ tag: Int) {
        guard tag != Self.customRetentionTag else { beginCustomRetention(); return }
        cancelCustomRetention(); changeRetention(tag)
    }
    private var customRetentionEditor: some View {
        GroupBox(label: Text("Custom period").font(.headline)) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("Days", text: $customRetentionText).frame(width: 120).accessibilityLabel("Custom history period in days").onSubmit(saveCustomRetention)
                    Text("days").foregroundStyle(.secondary)
                }
                if let error = customRetentionError { Text(error).font(.caption).foregroundStyle(.red) }
                HStack { Button("Save", action: saveCustomRetention).buttonStyle(.borderedProminent); Button("Cancel", action: cancelCustomRetention).keyboardShortcut(.cancelAction) }
                Text("Keep history for a whole number of days, for example 45. Stays until you change it.").font(.caption).foregroundStyle(.secondary)
            }.padding(4).frame(maxWidth: 340, alignment: .leading)
        }
    }
    private func beginCustomRetention() {
        customRetentionText = store.settings.retentionDays.flatMap { Self.presetDays.contains($0) || $0 <= 0 ? nil : String($0) } ?? ""
        customRetentionError = nil
        editingCustomRetention = true
    }
    private func cancelCustomRetention() {
        editingCustomRetention = false
        customRetentionText = ""
        customRetentionError = nil
    }
    private func saveCustomRetention() {
        do {
            let days = try Self.customDays(from: customRetentionText)
            customRetentionError = nil
            editingCustomRetention = false
            changeRetention(days)
        } catch let error as CustomDaysError { customRetentionError = Self.customRetentionMessage(for: error) } catch { customRetentionError = error.localizedDescription }
    }
    private enum CustomDaysError: Error { case empty, notWhole, notPositive, notRepresentable }
    /// Any positive representable day count is accepted; only input outside Int's range is unrepresentable.
    private static func customDays(from text: String) throws -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CustomDaysError.empty }
        guard let days = Int(trimmed) else {
            var digits = trimmed[...]
            if digits.first == "+" || digits.first == "-" { digits = digits.dropFirst() }
            guard !digits.isEmpty, digits.allSatisfy({ ("0"..."9").contains($0) }) else { throw CustomDaysError.notWhole }
            throw CustomDaysError.notRepresentable
        }
        guard days >= 1 else { throw CustomDaysError.notPositive }
        return days
    }
    private static func customRetentionMessage(for error: CustomDaysError) -> String {
        switch error {
        case .empty: "Enter a number of days."
        case .notWhole: "Enter a whole number of days, like 45. Fractions and other characters are not accepted."
        case .notPositive: "Days must be at least 1."
        case .notRepresentable: "That number is too large to store. Enter a smaller number of days."
        }
    }
    private func confirm(_ title: String, message: String, button: String) -> Bool { let alert = NSAlert(); alert.messageText = title; alert.informativeText = message; alert.addButton(withTitle: button); alert.addButton(withTitle: "Cancel"); return alert.runModal() == .alertFirstButtonReturn }
}
