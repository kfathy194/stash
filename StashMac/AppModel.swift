import AppKit
import Observation
import StashCore
import Vision
import LinkPresentation

@MainActor @Observable final class AppModel {
    static var cloudKitAvailable: Bool { Bundle.main.object(forInfoDictionaryKey: "StashCloudKitEnabled") as? Bool != false }
    let store: LibraryStore
    var query = "" { didSet { if query != oldValue { dismissSuggestions() } } }
    var filter = SearchFilter() { didSet { if filter != oldValue { dismissSuggestions() } } }
    var currentBoard: UUID? { didSet { if currentBoard != oldValue { dismissSuggestions() } } }
    var selection: Set<UUID> = []
    var anchor: UUID?
    var settingsSection = "General"
    var showFilters = false
    var searchFocused = false
    var toast: String?
    var stack = PasteStack()
    @ObservationIgnored private let suggestionCoordinator: SuggestionsCoordinator
    @ObservationIgnored private let settingsPresenter: @MainActor (AppModel) -> Void
    @ObservationIgnored private var rankingTask: Task<Void, Never>?
    @ObservationIgnored var panel: PanelController?
    @ObservationIgnored var capture: CaptureService!
    @ObservationIgnored var paste: PasteService!
    @ObservationIgnored var hotkeys: HotKeyService!
    @ObservationIgnored var mcp: MCPServer?
    @ObservationIgnored var intelligence = IntelligenceService()
    @ObservationIgnored var settingsWindow: NSWindow?
    @ObservationIgnored var toastTask: Task<Void, Never>?
    var settings: LibrarySettings { store.settings }
    var visible: [ClipItem] {
        let found = store.results(query: query, filter: filter, boardID: currentBoard, allLocations: !query.isEmpty || !filter.isEmpty)
        guard let suggestions else { return found }
        let rank = Dictionary(uniqueKeysWithValues: suggestions.enumerated().map { ($1, $0) })
        let ranked = found.filter { rank[$0.id] != nil }.sorted { rank[$0.id] ?? 0 < rank[$1.id] ?? 0 }
        return ranked + found.filter { rank[$0.id] == nil }
    }
    var selected: [ClipItem] { visible.filter { selection.contains($0.id) } }
    init(store: LibraryStore, suggestionCoordinator: SuggestionsCoordinator = SuggestionsCoordinator(), settingsPresenter: @escaping @MainActor (AppModel) -> Void = { $0.presentSettings() }) {
        self.store = store
        self.suggestionCoordinator = suggestionCoordinator
        self.settingsPresenter = settingsPresenter
    }

    // MARK: Suggestions (#63)

    var suggestionsState: SuggestionsState { suggestionCoordinator.state }
    var suggestions: [UUID]? { suggestionCoordinator.resultIDs }
    var isRanking: Bool { suggestionCoordinator.isRanking }

    struct SuggestionsNotice: Equatable {
        enum Kind: Equatable { case empty, unavailable, failed }
        let kind: Kind
        let text: String
        let offersSettings: Bool
    }
    private static let settingsFixable: Set<SuggestionsBlocker> = [.suggestionsDisabled, .screenRecordingRequired]
    var suggestionNotice: SuggestionsNotice? {
        switch suggestionCoordinator.state {
        case .empty: SuggestionsNotice(kind: .empty, text: "No suggestions matched this context.", offersSettings: false)
        case .unavailable(let blocker): SuggestionsNotice(kind: .unavailable, text: blocker.explanation, offersSettings: Self.settingsFixable.contains(blocker))
        case .failed(let reason): SuggestionsNotice(kind: .failed, text: "Suggestions could not finish: \(reason)", offersSettings: false)
        default: nil
        }
    }
    var suggestionsHelp: String {
        switch suggestionCoordinator.state {
        case .ranking: "Ranking your clips… click to cancel"
        case .results: "Suggestions shown · click to turn off"
        default: "Suggestions"
        }
    }

    func toggleSuggestions() {
        switch suggestionCoordinator.state {
        case .ranking:
            dismissSuggestions()
            message("Suggestions cancelled.")
        case .results:
            dismissSuggestions()
        default:
            startSuggestions()
        }
    }

    private func startSuggestions() {
        let runningApp = paste.previousApp
        let bundleID = runningApp?.isTerminated == false ? runningApp?.bundleIdentifier : nil
        let candidates = Array(visible.prefix(SuggestionsCoordinator.candidateLimit))
        let outcome = suggestionCoordinator.begin(readiness: intelligence.readiness(optIn: settings.suggestionsEnabled, previousAppBundleID: bundleID, ignoredBundleIDs: Set(settings.ignoredApplications)), candidateIDs: candidates.map(\.id))
        guard case let .started(token) = outcome, let app = runningApp else { return }
        rankingTask = Task { [weak self] in
            guard let self else { return }
            let validateRequest = { [weak self] in
                try Task.checkCancellation()
                guard let self, self.panel?.isVisible == true,
                      self.paste.previousApp?.processIdentifier == app.processIdentifier else { throw CancellationError() }
                let readiness = self.intelligence.readiness(optIn: self.settings.suggestionsEnabled, previousAppBundleID: app.isTerminated ? nil : app.bundleIdentifier, ignoredBundleIDs: Set(self.settings.ignoredApplications))
                guard self.suggestionCoordinator.validate(token: token, readiness: readiness) else { throw CancellationError() }
            }
            do {
                try await self.intelligence.rank(items: candidates, app: app, validateRequest: validateRequest) { ranked in
                    try validateRequest()
                    self.suggestionCoordinator.finish(token: token, ranked: ranked)
                    self.selectFirstIfNeeded()
                }
            } catch is CancellationError {
                self.suggestionCoordinator.discardInFlight(token: token)
            } catch {
                do { try validateRequest() }
                catch { self.suggestionCoordinator.discardInFlight(token: token); return }
                if let nativeError = error as? IntelligenceService.IntelligenceError {
                    if let blocker = nativeError.blocker { self.suggestionCoordinator.block(token: token, blocker: blocker) }
                    else if case let .rankingFailed(reason) = nativeError { self.suggestionCoordinator.fail(token: token, reason: reason) }
                } else {
                    self.suggestionCoordinator.fail(token: token, reason: error.localizedDescription)
                }
            }
        }
    }

    /// Closing the panel, changing context, turning Suggestions off or superseding
    /// a request discards visible results and cancels stale work.
    func dismissSuggestions() {
        rankingTask?.cancel()
        rankingTask = nil
        intelligence.cancel()
        suggestionCoordinator.cancel()
    }

    func panelDidHide() { dismissSuggestions() }

    func start(captureEnabled: Bool = true) {
        paste = PasteService(model: self); capture = CaptureService(model: self); hotkeys = HotKeyService(model: self)
        if captureEnabled { capture.start() }; hotkeys.register(); perform { try store.applyRetention() }
        if settings.mcpEnabled { startMCP() }
    }
    @discardableResult func perform<T>(_ operation: () throws -> T) -> T? { do { return try operation() } catch { store.context.rollback(); message(error.localizedDescription); return nil } }
    func message(_ value: String) { toast = value; toastTask?.cancel(); toastTask = Task { try? await Task.sleep(for: .seconds(4)); if !Task.isCancelled { toast = nil } } }
    @discardableResult func saveSettings(_ edit: (inout LibrarySettings) -> Void) -> Bool {
        var updated = settings; edit(&updated)
        if updated.suggestionsEnabled != settings.suggestionsEnabled || updated.ignoredApplications != settings.ignoredApplications { dismissSuggestions() }
        let saved = perform({ try store.updateSettings(updated) }) != nil
        hotkeys?.register(); panel?.updateMenu()
        return saved
    }
    func selectFirstIfNeeded() { selection.formIntersection(Set(visible.map(\.id))); if selection.isEmpty, let first = visible.first { selection = [first.id]; anchor = first.id } }
    func select(_ item: ClipItem, modifiers: NSEvent.ModifierFlags = []) {
        if modifiers.contains(.shift), let anchor, let start = visible.firstIndex(where: { $0.id == anchor }), let end = visible.firstIndex(where: { $0.id == item.id }) { selection.formUnion(visible[min(start, end)...max(start, end)].map(\.id)) }
        else if modifiers.contains(.command) { if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }; anchor = item.id }
        else { selection = [item.id]; anchor = item.id }
        selectFirstIfNeeded()
    }
    func move(_ delta: Int, extending: Bool = false) {
        guard !visible.isEmpty else { return }; let index = visible.firstIndex(where: { $0.id == (anchor ?? selection.first) }) ?? 0
        let next = visible[max(0, min(visible.count - 1, index + delta))]
        if extending { selection.insert(next.id) } else { selection = [next.id] }; anchor = next.id
    }
    func switchBoard(_ delta: Int) { let boards: [UUID?] = [nil] + store.pinboards.map { Optional($0.id) }; let index = boards.firstIndex(of: currentBoard) ?? 0; currentBoard = boards[(index + delta + boards.count) % boards.count]; query = ""; selection = []; selectFirstIfNeeded() }
    func pause(minutes: Int? = nil) { saveSettings { $0.pausedIndefinitely = minutes == nil; $0.pausedUntil = minutes.map { Date().addingTimeInterval(Double($0) * 60) } }; message("Capture paused") }
    func togglePause() { if settings.isPaused() { saveSettings { $0.pausedIndefinitely = false; $0.pausedUntil = nil } } else { pause() } }
    func toggleStack() { if stack.isActive { stack.stop(); paste.stopStack() } else { stack.start(); paste.startStack() }; message(stack.isActive ? "Stack started. Copy items in the order you need them." : "Stack stopped") }
    func captured(_ item: ClipItem) { perform { try store.add(item) }; if store.items.contains(where: { $0.id == item.id }) { stack.append(item.id) }; selectFirstIfNeeded(); enrich(item) }
    func enrich(_ item: ClipItem) {
        if item.kind == .image, let data = item.data {
            Task { let recognized = await Self.recognize(data); guard var current = store.items.first(where: { $0.id == item.id }) else { return }; current.ocrText = recognized; perform { try store.update(current) } }
        }
        if item.kind == .link, let url = URL(string: item.text) {
            Task { let provider = LPMetadataProvider(); provider.timeout = 8
                do { let metadata = try await provider.startFetchingMetadata(for: url); guard var current = store.items.first(where: { $0.id == item.id }) else { return }; current.linkTitle = metadata.title; current.linkDomain = url.host; perform { try store.update(current) }
                    if let imageProvider = metadata.imageProvider { let data: Data? = await withCheckedContinuation { continuation in imageProvider.loadDataRepresentation(forTypeIdentifier: "public.image") { data, _ in continuation.resume(returning: data) } }; if let data, let image = NSImage(data: data) { guard let latest = store.items.first(where: { $0.id == item.id }) else { return }; current = latest; current.thumbnail = CaptureService.thumbnail(image); perform { try store.update(current) } } }
                } catch { /* URL itself remains useful offline. */ }
            }
        }
    }
    nonisolated static func recognize(_ data: Data) async -> String {
        await Task.detached(priority: .utility) { let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.usesLanguageCorrection = true
            do { try VNImageRequestHandler(data: data).perform([request]); return request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n") ?? "" } catch { return "" }
        }.value
    }
    func prompt(title: String, value: String = "", message: String = "", action: (String) -> Void) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message; alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: value); field.frame = NSRect(x: 0, y: 0, width: 320, height: 24); alert.accessoryView = field; alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn { action(field.stringValue) }
    }
    func newBoard() { prompt(title: "New pinboard", message: "Keep useful things close.") { name in perform { let board = try store.createBoard(name: name); currentBoard = board.id } } }
    func rename() { guard let item = selected.first else { return }; prompt(title: "Name this item", value: item.title ?? "") { title in var copy = item; copy.title = title; perform { try store.update(copy) } } }
    func edit() { guard let item = selected.first, [.text,.richText,.code,.color,.link].contains(item.kind) else { return }; EditorWindow.open(item: item, model: self) }
    func newText() { EditorWindow.open(item: ClipItem(kind: .text), model: self, isNew: true) }
    func deleteSelection() { let ids = Array(selection); perform { try store.delete(ids) }; ids.forEach { stack.remove($0) }; selection = []; selectFirstIfNeeded() }
    func pin(to board: UUID?) { perform { try store.pin(Array(selection), to: board) } }
    func openSelected() {
        guard let item = selected.first else { return }
        if item.kind == .link, let url = URL(string: item.text) { NSWorkspace.shared.open(url) }
        if item.kind == .file { perform { for url in try FileAssets.resolvedURLs(for: store.materialized(item), directory: LibraryStore.defaultDirectory()) { NSWorkspace.shared.open(url) } } }
    }
    func revealSelected() { guard let item = selected.first else { return }; currentBoard = item.pinboardID; query = ""; filter = .init(); selection = [item.id]; anchor = item.id }
    func showSettings(section: String? = nil) {
        if let section { settingsSection = section }
        dismissSuggestions()
        paste?.clearDestination()
        settingsPresenter(self)
    }
    private func presentSettings() {
        if settingsWindow == nil { let controller = NSHostingController(rootView: SettingsView(model: self)); let window = NSWindow(contentViewController: controller); window.title = "Stash Settings"; window.styleMask = [.titled, .closable, .miniaturizable]; window.setContentSize(NSSize(width: 760, height: 550)); window.isReleasedWhenClosed = false; settingsWindow = window }
        NSApp.activate(ignoringOtherApps: true); settingsWindow?.center(); settingsWindow?.makeKeyAndOrderFront(nil)
    }
    func startMCP() { do { let server = try MCPServer(model: self); try server.start(); mcp = server } catch { saveSettings { $0.mcpEnabled = false }; message("MCP: " + error.localizedDescription) } }
    func shareBoard(_ id: UUID) {
        guard Self.cloudKitAvailable else { message("iCloud sharing is unavailable in this development build."); return }
        Task { do { let share = try await store.shareBoard(id); let service = NSSharingService(named: .cloudSharing); service?.perform(withItems: [share, CKContainer(identifier: LibraryStore.cloudContainer)]) } catch { message(error.localizedDescription) } }
    }
}
import SwiftUI
import CloudKit
import UniformTypeIdentifiers
