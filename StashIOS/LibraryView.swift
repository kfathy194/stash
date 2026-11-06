import SwiftUI
import Combine
import StashCore
import UniformTypeIdentifiers

struct LibraryView: View {
    @Bindable var store:LibraryStore
    @Environment(\.scenePhase) private var phase
    @State private var query = ""
    @State private var boardID: UUID?
    @State private var filter = SearchFilter()
    @State private var showSettings = false
    @State private var showFilters = false
    @State private var editing:ClipItem?
    @State private var preview:ClipItem?
    @State private var title = ""
    @State private var newBoard = false
    @State private var renameItem:ClipItem?
    @State private var message:String?
    @State private var erase = false
    @State private var lastClipboardChange = -1
    @State private var continuousCapture = false
    @State private var sharing:SharingRequest?
    private let timer = Timer.publish(every:1,on:.main,in:.common).autoconnect()
    var items:[ClipItem] { store.results(query:query,filter:filter,boardID:boardID,allLocations:!query.isEmpty || !filter.isEmpty) }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:16) {
                    HStack { PasteCaptureButton { captured in add(captured) }.frame(width:180,height:42); Spacer(); if UIDevice.current.userInterfaceIdiom == .pad { Toggle("Capture while visible",isOn:$continuousCapture).font(.caption).frame(maxWidth:210) } }
                    if !store.settings.onboardingComplete { Text("Tap Paste to save from your clipboard, or send content here with the Share Sheet. Stash reads your clipboard only after a paste action or while visible capture is enabled.").font(.callout).foregroundStyle(.secondary).onTapGesture { var settings = store.settings; settings.onboardingComplete = true; run { try store.updateSettings(settings) } } }
                    if showFilters { filterBar }
                    if items.isEmpty { ContentUnavailableView("Ready when you copy",systemImage:"square.stack.3d.up",description:Text("Save text, links, images and files. Pin the things you use often.")) }
                    LazyVGrid(columns:[GridItem(.adaptive(minimum:160),spacing:14)],spacing:14) { ForEach(items) { item in IOSCard(item:item).onTapGesture { copy(item) }.contextMenu { actions(item) }.onDrag { if item.kind == .file,let full=try? store.materialized(item),let url=try? FileAssets.resolve(full,directory:LibraryStore.defaultDirectory()) {return NSItemProvider(contentsOf:url) ?? NSItemProvider(object:item.text as NSString)};return NSItemProvider(object:item.text as NSString) } } }
                }.padding()
            }
            .background(Color(uiColor:.systemGroupedBackground))
            .navigationTitle(boardID.flatMap { id in store.pinboards.first { $0.id == id }?.name } ?? "Clipboard")
            .searchable(text:$query,prompt:"Search text, links and images")
            .toolbar {
                ToolbarItem(placement:.topBarLeading) { Menu { Button("Clipboard") { boardID = nil }; ForEach(store.pinboards) { board in Button(board.name) { boardID = board.id } }; Divider(); Button("New Pinboard",systemImage:"plus") { newBoard = true } } label: { Image(systemName:"sidebar.left") } }
                ToolbarItemGroup(placement:.topBarTrailing) {
                    Button { showFilters.toggle() } label: { Image(systemName:"line.3.horizontal.decrease.circle") }
                    Menu { Button("New Text",systemImage:"square.and.pencil") { editing = ClipItem(kind:.text) }; if let id = boardID { Button("Share Pinboard",systemImage:"person.2") { share(id) } }; Button("Settings",systemImage:"gearshape") { showSettings = true }; Button("Erase History",role:.destructive) { erase = true } } label: { Image(systemName:"ellipsis.circle") }
                }
            }
            .alert("Rename item",isPresented:Binding(get:{renameItem != nil},set:{if !$0 {renameItem=nil}})) {TextField("Title",text:$title);Button("Save") {if var item=renameItem {item.title=title;run {try store.update(item)}};renameItem=nil};Button("Cancel",role:.cancel) {renameItem=nil}}
            .alert("New pinboard",isPresented:$newBoard) { TextField("Name",text:$title); Button("Create") { run { boardID = try store.createBoard(name:title).id }; title = "" }; Button("Cancel",role:.cancel) {} }
            .alert("Erase clipboard history?",isPresented:$erase) { Button("Erase History",role:.destructive) { run { try store.eraseHistory() } }; Button("Cancel",role:.cancel) {} } message: { Text("Pinboards are kept. This cannot be undone.") }
            .alert("Stash",isPresented:Binding(get:{message != nil},set:{if !$0 {message = nil}})) { Button("OK") { message = nil } } message:{ Text(message ?? "") }
            .sheet(isPresented:$showSettings) { IOSSettings(store:store) }
            .sheet(item:$editing) { item in IOSEditor(item:item) { result in run { if store.items.contains(where:{$0.id == result.id}) { try store.update(result,replacingAssets:true) } else { try store.add(result) } } } }
            .sheet(item:$preview) { item in IOSPreview(item:(try? store.materialized(item)) ?? item) }
            .sheet(item:$sharing) { request in CloudSharingView(share:request.share) }
            .onChange(of:phase) { _,phase in if phase == .active { run { try store.reload() }; lastClipboardChange = UIPasteboard.general.changeCount } }
            .onReceive(timer) { _ in guard phase == .active,continuousCapture,UIDevice.current.userInterfaceIdiom == .pad else { return }; let pasteboard = UIPasteboard.general; guard lastClipboardChange != pasteboard.changeCount else { return }; lastClipboardChange = pasteboard.changeCount; guard CapturePolicy.allows(types:pasteboard.types,app:nil,settings:store.settings,now:.now) else { return }; Task { add(await ProviderImport.items(from:pasteboard.itemProviders,source:"Visible iPad Clipboard")) } }
        }.tint(StashBrand.accent)
    }
    private var filterBar: some View {
        VStack { Picker("Type",selection:$filter.kind) { Text("All types").tag(nil as ClipKind?); ForEach(ClipKind.allCases,id:\.self) { Text($0.label).tag(Optional($0)) } }
            Picker("Device",selection:$filter.device) { Text("All devices").tag(nil as String?); ForEach(Array(Set(store.items.map(\.device))).sorted(),id:\.self) { Text($0).tag(Optional($0)) } }
            HStack { Button("Today") { filter.after = Calendar.current.startOfDay(for:.now) }; Button("Last week") { filter.after = .now.addingTimeInterval(-7*86400) }; Button("Clear") { filter = .init() } }
        }.padding().background(.background,in:RoundedRectangle(cornerRadius:12))
    }
    @ViewBuilder private func actions(_ item:ClipItem) -> some View {
        Button("Copy",systemImage:"doc.on.doc") { copy(item) }; Button("Preview",systemImage:"eye") { preview = item }
        Menu("Pin",systemImage:"pin") { ForEach(store.pinboards) { board in Button(board.name) { run { try store.pin([item.id],to:board.id) } } }; if item.pinboardID != nil { Button("Unpin") { run { try store.pin([item.id],to:nil) } } } }
        if [.text,.richText,.code,.color,.link].contains(item.kind) { Button("Edit",systemImage:"pencil") { editing = (try? store.materialized(item)) ?? item } }
        Button("Rename",systemImage:"text.cursor") { title=item.title ?? "";renameItem=item }
        if item.kind == .file,let full=try? store.materialized(item),let url=try? FileAssets.resolve(full,directory:LibraryStore.defaultDirectory()) {ShareLink(item:url)} else {ShareLink(item:item.text)}
        Button("Show in " + (item.pinboardID == nil ? "Clipboard" : "Pinboard")) { boardID = item.pinboardID; query = ""; filter = .init() }
        Button("Delete",systemImage:"trash",role:.destructive) { run { try store.delete([item.id]) } }
    }
    private func add(_ items:[ClipItem]) { run { for item in items { try store.add(item); if let boardID { try store.pin([item.id],to:boardID) } }; lastClipboardChange = UIPasteboard.general.changeCount } }
    private func copy(_ item:ClipItem) { run { let full = try store.materialized(item); if item.kind == .file,let data=full.data { let url=try FileAssets.resolve(full,directory:LibraryStore.defaultDirectory());UIPasteboard.general.items=[[full.fileTypeIdentifier ?? UTType.data.identifier:data,UTType.fileURL.identifier:url]] } else if item.kind == .image,let data = full.data,let image = UIImage(data:data) { UIPasteboard.general.image = image } else if full.kind != .code, let rich = full.richData { UIPasteboard.general.items = [[UTType.rtf.identifier:rich,UTType.utf8PlainText.identifier:item.text]] } else { UIPasteboard.general.string = item.text }; lastClipboardChange = UIPasteboard.general.changeCount }; UIImpactFeedbackGenerator(style:.light).impactOccurred() }
    private func run(_ operation:() throws -> Void) { do { try operation() } catch { store.context.rollback(); message = error.localizedDescription } }
    private func share(_ id:UUID) { Task { do { sharing = SharingRequest(share:try await store.shareBoard(id)) } catch { message = error.localizedDescription } } }
}

struct IOSCard: View {
    let item:ClipItem
    var body: some View { VStack(alignment:.leading,spacing:0) {
        HStack { Image(systemName:item.kind.symbol); Text(item.kind.label).fontWeight(.semibold); Spacer(); if item.pinboardID != nil { Image(systemName:"pin.fill") } }.font(.caption).padding(12).background(.teal.opacity(0.13))
        Group { if item.kind == .image,let data = item.thumbnail,let image = UIImage(data:data) { Image(uiImage:image).resizable().scaledToFit() } else if item.kind == .color { RoundedRectangle(cornerRadius:6).fill(Color(hex:item.text)).overlay { Text(item.text).font(.system(.headline,design:.monospaced)).foregroundStyle(.white).shadow(radius:2) } } else { Text(item.linkTitle ?? item.text).font(.body).lineLimit(6).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading) } }.frame(height:130).padding(12)
        Text(item.title ?? item.metadata).font(.caption2).foregroundStyle(.secondary).lineLimit(1).padding([.horizontal,.bottom],12)
    }.background(.background,in:RoundedRectangle(cornerRadius:14)).clipShape(RoundedRectangle(cornerRadius:14)).overlay { RoundedRectangle(cornerRadius:14).stroke(.primary.opacity(0.05)) }.accessibilityElement(children:.combine) }
}
extension Color { init(hex:String) { let n = UInt64(hex.replacingOccurrences(of:"#",with:""),radix:16) ?? 0x30B7A8; self.init(red:Double((n>>16)&255)/255,green:Double((n>>8)&255)/255,blue:Double(n&255)/255) } }
import CloudKit
struct SharingRequest:Identifiable { let id = UUID(); let share:CKShare }
