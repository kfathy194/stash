import UIKit
import SwiftUI
import StashCore

@MainActor final class ShareViewController:UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        do {
            let store = try LibraryStore()
            let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
            let root = ShareView(store:store,providers:providers,onDone:{ [weak self] in self?.extensionContext?.completeRequest(returningItems:nil) })
            let host = UIHostingController(rootView:root); addChild(host); view.addSubview(host.view); host.view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([host.view.topAnchor.constraint(equalTo:view.topAnchor),host.view.bottomAnchor.constraint(equalTo:view.bottomAnchor),host.view.leadingAnchor.constraint(equalTo:view.leadingAnchor),host.view.trailingAnchor.constraint(equalTo:view.trailingAnchor)]); host.didMove(toParent:self)
        } catch { let label = UILabel(); label.text = "Stash couldn't open the library: " + error.localizedDescription; label.numberOfLines = 0; label.frame = view.bounds.insetBy(dx:24,dy:50); label.autoresizingMask = [.flexibleWidth,.flexibleHeight]; view.addSubview(label) }
    }
}
struct ShareView:View {
    @Bindable var store:LibraryStore
    let providers:[NSItemProvider]
    let onDone:() -> Void
    @State private var items:[ClipItem] = []
    @State private var board:UUID?
    @State private var error:String?
    @State private var loading = true
    var body:some View { NavigationStack { Form { Section { Label("Save to Stash",systemImage:"square.stack.3d.up.fill").foregroundStyle(.teal); if loading { ProgressView("Reading content…") } else { Text("\(items.count) item\(items.count == 1 ? "" : "s") ready") } }; Picker("Save in",selection:$board) { Text("Clipboard").tag(nil as UUID?); ForEach(store.pinboards) { Text($0.name).tag(Optional($0.id)) } }; ForEach(items) { item in Text(item.kind == .image ? "Image" : String(item.text.prefix(250))).lineLimit(4) }; if let error { Text(error).foregroundStyle(.red) } }.navigationTitle("Stash").toolbar { ToolbarItem(placement:.cancellationAction) { Button("Cancel",action:onDone) }; ToolbarItem(placement:.confirmationAction) { Button("Save") { do { for item in items { try store.add(item); if let board { try store.pin([item.id],to:board) } }; onDone() } catch { self.error = error.localizedDescription } }.disabled(loading || items.isEmpty) } }.task { items = await ProviderImport.items(from:providers); loading = false; if items.isEmpty {error = "This content type is not supported."} } } }
}
