import SwiftUI
import StashCore
import CloudKit
import UniformTypeIdentifiers

struct IOSSettings:View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store:LibraryStore
    @State private var importFile = false
    @State private var exportFile = false
    @State private var archive = ArchiveDocument(data:Data())
    @State private var pendingDays:Int?
    @State private var confirmRetention = false
    @State private var message:String?
    func binding<T>(_ path:WritableKeyPath<LibrarySettings,T>) -> Binding<T> { Binding(get:{store.settings[keyPath:path]},set:{value in var settings = store.settings; settings[keyPath:path] = value; run { try store.updateSettings(settings) }}) }
    var body:some View { NavigationStack { Form {
        Section("History") { Picker("Keep history",selection:Binding(get:{store.settings.retentionDays ?? 0},set:{days in pendingDays = days; let expires = store.items.contains { $0.pinboardID == nil && Retention.action(for:$0,days:days == 0 ? nil : days,now:.now) == .delete }; if expires { confirmRetention = true } else { applyRetention(days) } })) { Text("1 Day").tag(1);Text("1 Week").tag(7);Text("1 Month").tag(30);Text("1 Year").tag(365);Text("Forever").tag(0) }; Text("Pinned items are always kept.").font(.caption) }
        Section("iCloud") { Toggle("Sync on my devices",isOn:binding(\.syncEnabled)); Text(store.syncStatus); Text("Reopen Stash after changing sync. Use the same Apple Account on every device.").font(.caption) }
        Section("Backup") { Button("Export Library") { run { archive = ArchiveDocument(data:try store.archive()); exportFile = true } }; Button("Import Library") { importFile = true }; Text("Backups contain clipboard content and file references. Keep them private.").font(.caption) }
        Section("Keyboard") { Text("Enable Stash in Settings → General → Keyboard → Keyboards. Allow Full Access to read the shared on-device Stash library. The keyboard does not send data to any server.") }
        Section("Pinboards") { NavigationLink("Manage Pinboards") { IOSPinboards(store:store) };Button("Undo last deletion or move") {run {try store.undo()}} }
        Section("About") { HStack(spacing:12) {StashAppBadge(size:64);VStack(alignment:.leading,spacing:5) {StashWordmark(size:24);Text(StashBrand.tagline).font(.caption).foregroundStyle(.secondary)}};Text("Native, private, yours.").foregroundStyle(.secondary) }
    }.navigationTitle("Settings").toolbar { Button("Done") { dismiss() } }
        .fileExporter(isPresented:$exportFile,document:archive,contentType:.data,defaultFilename:"Stash-backup.stasharchive") { result in if case .failure(let error) = result { message = error.localizedDescription } }
        .fileImporter(isPresented:$importFile,allowedContentTypes:[.data]) { result in run { let url = try result.get(); let accessed = url.startAccessingSecurityScopedResource(); defer { if accessed { url.stopAccessingSecurityScopedResource() } }; try store.importArchive(Data(contentsOf:url)) } }
        .confirmationDialog("Delete older history? This cannot be undone.",isPresented:$confirmRetention) { Button("Delete Older Items",role:.destructive) { if let days = pendingDays { applyRetention(days) } } }
        .alert("Stash",isPresented:Binding(get:{message != nil},set:{if !$0 {message = nil}})) { Button("OK") { message = nil } } message:{Text(message ?? "")}
    } }
    private func run(_ block:() throws -> Void) { do { try block() } catch { message = error.localizedDescription } }
    private func applyRetention(_ days:Int) { var settings = store.settings; settings.retentionDays = days == 0 ? nil : days; run { try store.updateSettings(settings); try store.applyRetention() } }
}
struct ArchiveDocument:FileDocument {
    static var readableContentTypes:[UTType] { [.data] }
    var data:Data
    init(data:Data) {self.data = data}
    init(configuration:ReadConfiguration) throws {data = configuration.file.regularFileContents ?? Data()}
    func fileWrapper(configuration:WriteConfiguration) throws -> FileWrapper {FileWrapper(regularFileWithContents:data)}
}
struct IOSEditor:View {
    @Environment(\.dismiss) var dismiss
    @State var item:ClipItem
    var onSave:(ClipItem) -> Void
    var body:some View { NavigationStack { Form { TextField("Title",text:Binding(get:{item.title ?? ""},set:{item.title = $0})); TextEditor(text:$item.text).frame(minHeight:250) }.navigationTitle("Edit Item").toolbar { ToolbarItem(placement:.cancellationAction) { Button("Cancel") {dismiss()} }; ToolbarItem(placement:.confirmationAction) { Button("Save") { item.updatePlainText(item.text); onSave(item); dismiss() } } } } }
}
struct IOSPreview:View {
    let item:ClipItem
    var body:some View { ScrollView { VStack(alignment:.leading) { Text(item.displayTitle).font(.title2.bold()); if let data = item.data,let image = UIImage(data:data) { Image(uiImage:image).resizable().scaledToFit() }; Text(item.text).textSelection(.enabled); if !item.ocrText.isEmpty { Text(item.ocrText).textSelection(.enabled) }; if item.kind == .link,let url = URL(string:item.text) { Link("Open Link",destination:url) } }.padding() } }
}
struct CloudSharingView:UIViewControllerRepresentable {
    let share:CKShare
    func makeUIViewController(context:Context) -> UICloudSharingController { let controller = UICloudSharingController(share:share,container:CKContainer(identifier:LibraryStore.cloudContainer)); controller.availablePermissions = [.allowReadOnly,.allowReadWrite,.allowPrivate]; return controller }
    func updateUIViewController(_ controller:UICloudSharingController,context:Context) {}
}

struct IOSPinboards:View {
    @Bindable var store:LibraryStore
    @State private var pending:Pinboard?
    @State private var error:String?
    var body:some View { List {ForEach(store.pinboards) {board in NavigationLink {IOSPinboardEditor(store:store,board:board)} label:{HStack {Circle().fill(Color(hex:board.colorHex)).frame(width:12,height:12);Text(board.name)}}.deleteDisabled(!store.boardIsWritable(board.id)).moveDisabled(!store.boardIsWritable(board.id))}.onMove {from,to in var boards=store.pinboards;boards.move(fromOffsets:from,toOffset:to);run {for (offset,var board) in boards.enumerated() {board.order=Double(offset);try store.updateBoard(board)}}}.onDelete {offsets in if let index=offsets.first {pending=store.pinboards[index]}} }.navigationTitle("Pinboards").toolbar {EditButton()}.confirmationDialog("Delete pinboard and all its items?",isPresented:Binding(get:{pending != nil},set:{if !$0 {pending=nil}})) {Button("Delete Pinboard",role:.destructive) {if let pending {run {try store.deleteBoard(pending.id)}};pending=nil}}.alert("Stash",isPresented:Binding(get:{error != nil},set:{if !$0 {error=nil}})) {Button("OK") {error=nil}} message:{Text(error ?? "")} }
    private func run(_ action:() throws -> Void) {do {try action()} catch {self.error=error.localizedDescription}}
}
struct IOSPinboardEditor:View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store:LibraryStore
    @State var board:Pinboard
    @State private var error:String?
    var body:some View {Form {TextField("Name",text:$board.name);Picker("Color",selection:$board.colorHex) {Text("Jade").tag("30B7A8");Text("Iris").tag("7987EB");Text("Amber").tag("F0A154");Text("Rose").tag("E779A0");Text("Leaf").tag("62B877")};if let error {Text(error).foregroundStyle(.red)}}.navigationTitle("Edit Pinboard").disabled(!store.boardIsWritable(board.id)).toolbar {Button("Save") {do {try store.updateBoard(board);dismiss()} catch {self.error=error.localizedDescription}}} }
}
