import SwiftUI
import StashCore
import UniformTypeIdentifiers

struct PanelView: View {
    @Bindable var model: AppModel
    @FocusState private var searchFocus: Bool
    @State private var draggedBoard: UUID?
    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 285
            VStack(spacing: 0) {
                Capsule().fill(.secondary.opacity(0.4)).frame(width: 40, height: 4).padding(.top, 7).padding(.bottom, 8)
                    .frame(maxWidth: .infinity).contentShape(Rectangle()).gesture(DragGesture().onChanged { model.panel?.resize(translation: -$0.translation.height, ended: false) }.onEnded { model.panel?.resize(translation: -$0.translation.height, ended: true) })
                toolbar.padding(.horizontal, 24).padding(.bottom, 12)
                suggestionBanner.padding(.horizontal, 24).padding(.bottom, 10)
                if model.searchFocused || !model.query.isEmpty || model.showFilters { searchBar.padding(.horizontal, 24).padding(.bottom, 10) }
                if model.showFilters { filters.padding(.horizontal, 24).padding(.bottom, 10) }
                if model.visible.isEmpty {
                    ContentUnavailableView(model.settings.isPaused() ? "Capture is paused" : model.query.isEmpty ? "Make room for your next idea" : "No matching items", systemImage: model.query.isEmpty ? "square.stack.3d.up" : "magnifyingglass", description: Text(model.query.isEmpty ? "Copy text, a link, an image or a file. It will be here when you need it." : "Try another word or remove a filter.")).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal) {
                            LazyHStack(alignment: .top, spacing: 16) {
                                ForEach(Array(model.visible.enumerated()), id: \.element.id) { position, item in
                                    CardView(item: item, number: position < 9 ? position + 1 : nil, selected: model.selection.contains(item.id), compact: compact, query: model.query, richPreview: item.kind == .richText ? (try? model.store.materialized(item).richData) : nil)
                                        .frame(width: compact ? 230 : 280).frame(maxHeight: .infinity).id(item.id)
                                        .onTapGesture { activate(item) }
                                        .contextMenu { itemMenu(item) }
                                        .onDrag { model.select(item); return dragProvider(item) }
                                        .onDrop(of: [UTType(exportedAs:"com.kfathy.stash.item"), .text], isTargeted: nil) { providers in reorderItem(providers, target: item) }
                                }
                            }.padding(.horizontal, 24).padding(.vertical, 5)
                        }.scrollIndicators(.hidden)
                        .onChange(of: model.anchor) { _, id in if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) } } }
                    }
                }
                HStack {
                    StashGlyph().fill(StashBrand.accent).frame(width:13,height:13); Text("Stash").font(.system(size:11,weight:.semibold,design:.rounded))
                    Text("·").foregroundStyle(.tertiary); Text("\(model.visible.count.formatted()) items").foregroundStyle(.secondary)
                    if model.suggestions != nil { Text("· Suggestions for " + (model.paste.previousApp?.localizedName ?? "your last app")).foregroundStyle(.teal) }
                    if model.settings.isPaused() { Label("Paused", systemImage: "pause.fill").foregroundStyle(.orange) }
                    if let toast = model.toast { Text(toast).lineLimit(1).foregroundStyle(.teal) }
                    Spacer(); Text("Click pastes   ↵ Paste   ⇧↵ Plain text   Space Preview   ⌘F Search").foregroundStyle(.secondary)
                }.font(.system(size: 11)).padding(.horizontal, 24).padding(.vertical, 12)
            }
        }
        .tint(StashBrand.accent)
        .onChange(of: model.query) { _, _ in model.selection = []; model.selectFirstIfNeeded() }
        .onChange(of: model.store.revision) { _, _ in model.selectFirstIfNeeded() }
        .onChange(of: model.searchFocused) { _, value in searchFocus = value }
        .onChange(of: searchFocus) { _, value in model.searchFocused = value }
    }
    private var toolbar: some View {
        HStack(spacing: 12) {
            ScrollView(.horizontal) { HStack(spacing: 8) {
                tab("Clipboard", id: nil, color: .teal)
                ForEach(model.store.pinboards) { board in tab(board.name, id: board.id, color: Color(hex: board.colorHex))
                    .contextMenu {
                        Button("Rename…") { model.prompt(title: "Rename pinboard", value: board.name) { name in var copy = board; copy.name = name; model.perform { try model.store.updateBoard(copy) } } }
                        Menu("Color") { ForEach(["30B7A8", "7987EB", "F0A154", "E779A0", "62B877"], id: \.self) { hex in Button(hex) { var copy = board; copy.colorHex = hex; model.perform { try model.store.updateBoard(copy) } } } }
                        Button("Share pinboard…", systemImage: "person.2") { model.shareBoard(board.id) }
                        Divider(); Button("Delete pinboard and its items…", role: .destructive) { let alert = NSAlert(); alert.messageText = "Delete \(board.name)?"; alert.informativeText = "All items in this pinboard will be deleted."; alert.addButton(withTitle: "Delete"); alert.addButton(withTitle: "Cancel"); if alert.runModal() == .alertFirstButtonReturn { model.perform { try model.store.deleteBoard(board.id) }; model.currentBoard = nil } }
                    }
                    .onDrag { draggedBoard = board.id; return NSItemProvider(object: board.id.uuidString as NSString) }
                    .onDrop(of: [UTType(exportedAs:"com.kfathy.stash.item"), .text], isTargeted: nil) { providers in
                        if let source = draggedBoard, source != board.id, var moving = model.store.pinboards.first(where: { $0.id == source }) { moving.order = board.order - 0.5; model.perform { try model.store.updateBoard(moving) }; draggedBoard = nil; return true }
                        return pinDrop(providers, board: board.id)
                    }
                }
                Button(action: model.newBoard) { Image(systemName: "plus") }.buttonStyle(.plain).help("New pinboard · ⇧⌘N")
            } }.scrollIndicators(.hidden)
            Spacer(minLength: 12)
            if model.stack.isActive { Menu { Button("Reverse order", systemImage: "arrow.up.arrow.down") { model.stack.reverse() }; ForEach(model.stack.items, id: \.self) { id in Button("Remove: " + (model.store.items.first { $0.id == id }?.displayTitle ?? "Item")) { model.stack.remove(id) } }; Button("Stop Stack") { model.toggleStack() } } label: { Label("\(model.stack.items.count)", systemImage: "square.3.layers.3d") } }
            Button { model.searchFocused.toggle() } label: { Image(systemName: "magnifyingglass") }.help("Search · ⌘F")
            Button { model.showFilters.toggle() } label: { Image(systemName: "line.3.horizontal.decrease.circle") }.help("Filters")
            Button { model.toggleSuggestions() } label: { if model.isRanking { ProgressView().controlSize(.small) } else { Image(systemName: model.suggestions == nil ? "sparkles" : "sparkles.square.filled.on.square") } }
                .help(model.suggestionsHelp)
                .accessibilityLabel(model.suggestionsHelp)
                .contextMenu { Button("Turn off Suggestions") { model.saveSettings { $0.suggestionsEnabled = false } } }
            Button(action: { model.showSettings() }) { Image(systemName: "gearshape") }.help("Settings · ⌘,")
        }.buttonStyle(.borderless).font(.system(size: 14))
    }
    @ViewBuilder private var suggestionBanner: some View {
        if let notice = model.suggestionNotice {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: notice.kind == .failed ? "exclamationmark.triangle" : "sparkles").foregroundStyle(notice.kind == .failed ? .orange : StashBrand.accent)
                    Text(notice.text).multilineTextAlignment(.leading).textSelection(.enabled)
                }.accessibilityElement(children: .combine).accessibilityLabel(notice.text)
                if notice.offersSettings { Button("Open Stash Intelligence") { model.showSettings(section: "Intelligence") } }
                Spacer(minLength: 4)
                Button { model.dismissSuggestions() } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).help("Dismiss").accessibilityLabel("Dismiss")
            }.font(.callout).padding(10).background((notice.kind == .failed ? Color.orange.opacity(0.12) : StashBrand.accent.opacity(0.12)), in: RoundedRectangle(cornerRadius: 10))
        } else if model.isRanking {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Ranking your clips for " + (model.paste.previousApp?.localizedName ?? "your previous app") + "…").foregroundStyle(.secondary)
                }.accessibilityElement(children: .combine).accessibilityLabel("Ranking your clips")
                Spacer(minLength: 4)
                Button("Cancel") { model.toggleSuggestions() }
            }.font(.callout)
        }
    }
    private func tab(_ name: String, id: UUID?, color: Color) -> some View {
        Button { model.currentBoard = id; model.query = ""; model.selection = []; model.selectFirstIfNeeded() } label: { HStack(spacing: 7) { Circle().fill(color).frame(width: 7, height: 7); Text(name).lineLimit(1) }.padding(.horizontal, 12).padding(.vertical, 7).background(model.currentBoard == id ? color.opacity(0.16) : .clear, in: Capsule()) }.buttonStyle(.plain)
    }
    private var searchBar: some View {
        HStack { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField("Search everything, including text in images", text: $model.query).textFieldStyle(.plain).focused($searchFocus)
            if model.filter.kind != nil { filterToken(model.filter.kind!.label) { model.filter.kind = nil } }
            if model.filter.sourceAppID != nil { filterToken("App") { model.filter.sourceAppID = nil } }
            if model.filter.device != nil { filterToken(model.filter.device!) { model.filter.device = nil } }
            if model.filter.after != nil || model.filter.before != nil { filterToken("Date") { model.filter.after = nil; model.filter.before = nil } }
            if !model.query.isEmpty { Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
        }.padding(10).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
    private func filterToken(_ name: String, action: @escaping () -> Void) -> some View { Button(action: action) { HStack(spacing: 3) { Text(name); Image(systemName: "xmark") }.font(.caption).padding(5).background(.teal.opacity(0.14), in: Capsule()) }.buttonStyle(.plain) }
    private var filters: some View {
        HStack {
            Picker("Type", selection: $model.filter.kind) { Text("Any").tag(nil as ClipKind?); ForEach(ClipKind.allCases, id: \.self) { Text($0.label).tag(Optional($0)) } }.frame(width: 160)
            Picker("App", selection: $model.filter.sourceAppID) { Text("Any").tag(nil as String?); ForEach(Array(Set(model.store.items.map(\.sourceAppID))).sorted(), id: \.self) { id in Text(model.store.items.first { $0.sourceAppID == id }?.sourceAppName ?? id).tag(Optional(id)) } }.frame(width: 190)
            Picker("Device", selection: $model.filter.device) { Text("Any").tag(nil as String?); ForEach(Array(Set(model.store.items.map(\.device))).sorted(), id: \.self) { Text($0).tag(Optional($0)) } }.frame(width: 180)
            Menu("Date range") { Button("Today") { model.filter.after = Calendar.current.startOfDay(for: .now); model.filter.before = nil }; Button("Last 7 days") { model.filter.after = .now.addingTimeInterval(-7 * 86400); model.filter.before = nil }; Button("Last 30 days") { model.filter.after = .now.addingTimeInterval(-30 * 86400); model.filter.before = nil }; Button("Any time") { model.filter.after = nil; model.filter.before = nil } }
            Button("Clear") { model.filter = .init() }; Spacer()
        }.font(.caption)
    }
    @ViewBuilder private func itemMenu(_ item: ClipItem) -> some View {
        Button("Paste") { if !model.selection.contains(item.id) { model.select(item) }; model.paste.paste() }
        Button("Paste as Plain Text") { model.select(item); model.paste.paste(plain: true) }
        Button("Copy") { if !model.selection.contains(item.id) { model.select(item) }; _ = model.paste.copy(model.selected) }
        Divider(); Menu("Pin") { ForEach(model.store.pinboards) { board in Button(board.name) { if !model.selection.contains(item.id) { model.select(item) }; model.pin(to: board.id) } }; Button("Remove from pinboard") { model.select(item); model.pin(to: nil) }; Button("New pinboard…", action: model.newBoard) }
        Button("Preview") { PreviewWindow.open(item: item, model: model) }
        Button("Rename…") { model.select(item); model.rename() }
        if [.text,.richText,.code,.color,.link].contains(item.kind) {Button("Edit…") { model.select(item); model.edit() }}
        Button("Show in " + (item.pinboardID.flatMap { id in model.store.pinboards.first { $0.id == id }?.name } ?? "Clipboard")) { model.select(item); model.revealSelected() }
        if item.kind == .image { Button("Extract Text") { let text = ClipItem(kind: .text, text: item.ocrText); model.perform { try model.store.add(text) } }; Button("Rotate Image") { PreviewWindow.rotate(item: item, model: model) } }
        if item.kind == .link || item.kind == .file { Button("Open") { model.select(item); model.openSelected() } }
        Divider(); Button("Delete", role: .destructive) { if !model.selection.contains(item.id) { model.select(item) }; model.deleteSelection() }
    }
    /// Only a truly unmodified primary click pastes: any held intent modifier (⌘ ⇧ ⌥ ⌃) keeps
    /// the click a selection or context gesture and never pastes. Caps Lock and keypad flags are
    /// keyboard state rather than click modifiers, so they do not suppress pasting. The paste
    /// service additionally drops a repeated same-item activation inside the double-click
    /// interval, so multi-clicks and double-clicks cannot insert twice.
    private func activate(_ item: ClipItem) {
        let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.intersection([.command, .shift, .option, .control]).isEmpty else { model.select(item, modifiers: flags); return }
        model.select(item)
        model.paste.paste([item], clickActivation: true)
    }
    private func dragProvider(_ item: ClipItem) -> NSItemProvider {
        let provider: NSItemProvider
        if item.kind == .file {
            do { provider = try FileAssets.dragProvider(for: model.store.materialized(item), directory: LibraryStore.defaultDirectory()) }
            catch { model.message(error.localizedDescription); provider = NSItemProvider(object: item.text as NSString) }
        } else { provider = NSItemProvider(object: item.text as NSString) }
        provider.registerDataRepresentation(forTypeIdentifier: "com.kfathy.stash.item", visibility: .ownProcess) { completion in completion(Data(item.id.uuidString.utf8), nil); return nil }
        if item.kind == .image, let full = try? model.store.materialized(item), let data = full.data, let tiff = NSImage(data:data)?.tiffRepresentation { provider.registerDataRepresentation(forTypeIdentifier: UTType.tiff.identifier, visibility: .all) { completion in completion(tiff, nil); return nil } }
        return provider
    }
    private func pinDrop(_ providers: [NSItemProvider], board: UUID) -> Bool {
        guard let provider = providers.first, provider.hasItemConformingToTypeIdentifier("com.kfathy.stash.item") else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: "com.kfathy.stash.item") { data, _ in if let data, let raw = String(data: data, encoding: .utf8), let id = UUID(uuidString: raw) { Task { @MainActor in model.perform { try model.store.pin([id], to: board) } } } }; return true
    }
    private func reorderItem(_ providers: [NSItemProvider], target: ClipItem) -> Bool {
        guard model.currentBoard != nil, let provider = providers.first else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: "com.kfathy.stash.item") { data, _ in if let data, let raw = String(data: data, encoding: .utf8), let id = UUID(uuidString: raw) { Task { @MainActor in guard var item = model.store.items.first(where: { $0.id == id }), item.pinboardID == target.pinboardID else { return }; item.order = target.order - 0.5; model.perform { try model.store.update(item) } } } }; return true
    }
}
