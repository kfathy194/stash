import AppIntents
import StashCore

struct AddStashItemIntent:AppIntent {
    static let title:LocalizedStringResource = "Add to Stash"
    static let description = IntentDescription("Save text to your clipboard library.")
    @Parameter(title:"Text") var text:String
    func perform() async throws -> some IntentResult { try await MainActor.run { let store = try LibraryStore(); try store.add(ClipItem(kind:ContentClassifier.kind(for:text),text:text)) }; return .result() }
}
struct LatestStashItemIntent:AppIntent {
    static let title:LocalizedStringResource = "Get Latest Stash Item"
    func perform() async throws -> some IntentResult & ReturnsValue<String> { let text = try await MainActor.run { let store = try LibraryStore(); return store.items.first(where:{$0.isInHistory})?.text ?? "" }; return .result(value:text) }
}
struct SearchStashIntent:AppIntent {
    static let title:LocalizedStringResource = "Search Stash"
    @Parameter(title:"Query") var query:String
    func perform() async throws -> some IntentResult & ReturnsValue<[String]> { let results = try await MainActor.run { let store = try LibraryStore(); return store.results(query:query,allLocations:true).prefix(30).map(\.text) }; return .result(value:results) }
}
struct CopyFromPinboardIntent:AppIntent {
    static let title:LocalizedStringResource = "Copy from Stash Pinboard"
    @Parameter(title:"Pinboard name") var boardName:String
    func perform() async throws -> some IntentResult & ReturnsValue<String> { let text = try await MainActor.run { let store = try LibraryStore(); guard let id = store.pinboards.first(where:{$0.name.localizedCaseInsensitiveCompare(boardName) == .orderedSame})?.id else { return "" }; let text = store.results(boardID:id).first?.text ?? ""; UIPasteboard.general.string = text; return text }; return .result(value:text) }
}
struct StashShortcuts:AppShortcutsProvider {
    static var appShortcuts:[AppShortcut] { AppShortcut(intent:AddStashItemIntent(),phrases:["Add to \(.applicationName)"],shortTitle:"Add Item",systemImageName:"plus.square"); AppShortcut(intent:LatestStashItemIntent(),phrases:["Get latest item from \(.applicationName)"],shortTitle:"Latest Item",systemImageName:"doc.on.clipboard"); AppShortcut(intent:SearchStashIntent(),phrases:["Search \(.applicationName)"],shortTitle:"Search",systemImageName:"magnifyingglass") }
}
import UIKit
