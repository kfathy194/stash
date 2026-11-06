import Foundation
import Observation
@preconcurrency import CoreData
import CloudKit

@MainActor @Observable public final class LibraryStore {
    public static let appGroup = "group.com.kfathy.stash"
    public static let cloudContainer = "iCloud.com.kfathy.stash"
    public private(set) var items: [ClipItem] = []
    public private(set) var pinboards: [Pinboard] = []
    public private(set) var settings = LibrarySettings()
    public private(set) var syncStatus = "On this device"
    public private(set) var revision = 0
    public let container: NSPersistentCloudKitContainer
    @ObservationIgnored private var index: SearchIndex
    @ObservationIgnored private let observers: LibraryNotificationRegistrations
    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var memory: Bool
    @ObservationIgnored private var undoEntries: [UndoEntry] = []

    private struct ItemLocation {
        let id: UUID
        let boardID: UUID?
        let isInHistory: Bool
        let order: Double
        let hadPrivateCopy: Bool
    }
    private struct DeletedItem {
        let item: ClipItem
        let hadPrivateCopy: Bool
        let managedCopies: [FileAssets.ManagedCopy]
    }
    private struct DeletedBoard {
        let board: Pinboard
        let mayRecreate: Bool
    }
    private enum UndoEntry {
        case move([ItemLocation])
        case deletion([DeletedItem], board: DeletedBoard?)
    }
    @ObservationIgnored private var indexedItems: [UUID:ClipItem] = [:]
    @ObservationIgnored private var devicePreferences=DevicePreferences()
    @ObservationIgnored internal var writePermissionCheck: ((NSManagedObject) -> Bool)?
    public var context: NSManagedObjectContext { container.viewContext }

    public static func defaultDirectory() -> URL {
        #if os(macOS)
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #else
        let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #endif
        return base.appendingPathComponent("Stash", isDirectory: true)
    }
    public static var syncRequested:Bool {
        guard let data=try? Data(contentsOf:defaultDirectory().appendingPathComponent("DeviceSettings.json")),let preferences=try? JSONDecoder().decode(DevicePreferences.self,from:data) else {return false}
        return preferences.syncEnabled
    }
    public convenience init(directory: URL? = nil, inMemory: Bool = false, syncEnabled: Bool = false) throws {
        try self.init(directory: directory, inMemory: inMemory, syncEnabled: syncEnabled,
                      notificationCenter: .default, makeIndex: { try SearchIndex(url: nil) })
    }
    // Internal system-resource seams keep lifetime/failure checks deterministic.
    init(directory: URL?, inMemory: Bool, syncEnabled: Bool, notificationCenter: NotificationCenter,
         makeIndex: () throws -> SearchIndex) throws {
        self.directory = directory ?? Self.defaultDirectory(); self.memory = inMemory
        observers = LibraryNotificationRegistrations(center: notificationCenter)
        if !inMemory {
            try FileManager.default.createDirectory(at:self.directory,withIntermediateDirectories:true)
            let url=self.directory.appendingPathComponent("DeviceSettings.json")
            if FileManager.default.fileExists(atPath:url.path) {devicePreferences=try JSONDecoder().decode(DevicePreferences.self,from:Data(contentsOf:url))}
        }
        index = try makeIndex()
        container = NSPersistentCloudKitContainer(name: "Stash", managedObjectModel: Self.model())
        var descriptions: [NSPersistentStoreDescription] = []
        for (name, configuration, scope) in [("History", "History", CKDatabase.Scope.private), ("Boards", "Boards", .private), ("Shared", "Boards", .shared)] {
            let desc = NSPersistentStoreDescription(url: inMemory ? URL(fileURLWithPath: "/dev/null/" + UUID().uuidString + "/" + name + ".sqlite") : self.directory.appendingPathComponent(name + ".sqlite"))
            desc.configuration = configuration
            desc.type = inMemory ? NSInMemoryStoreType : NSSQLiteStoreType
            desc.shouldAddStoreAsynchronously = false
            desc.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
            desc.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
            if syncEnabled && !inMemory { let options = NSPersistentCloudKitContainerOptions(containerIdentifier: Self.cloudContainer); options.databaseScope = scope; desc.cloudKitContainerOptions = options }
            descriptions.append(desc)
        }
        container.persistentStoreDescriptions = descriptions
        var loadError: Error?
        container.loadPersistentStores { _, error in if let error { loadError = error } }
        if let loadError { throw loadError }
        context.automaticallyMergesChangesFromParent = true
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        try reload()
        syncStatus = syncEnabled ? "Waiting for iCloud" : "On this device"
        observers.append(notificationCenter.addObserver(forName: .NSPersistentStoreRemoteChange, object: container.persistentStoreCoordinator, queue: .main) { [weak self] _ in Task { @MainActor [weak self] in try? self?.reload() } })
        observers.append(notificationCenter.addObserver(forName: NSPersistentCloudKitContainer.eventChangedNotification, object: container, queue: .main) { [weak self] note in
            let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey] as? NSPersistentCloudKitContainer.Event
            let status = event?.error?.localizedDescription ?? (event?.endDate == nil ? "Syncing…" : "Up to date")
            Task { @MainActor [weak self] in self?.syncStatus = status; try? self?.reload() }
        })
    }

    public func reload() throws {
        try withManagedMutation { }
    }
    private func reloadUnlocked() throws {
        try recoverPendingPasteBarImport()
        if !context.hasChanges { context.refreshAllObjects() }
        let decoder = JSONDecoder()
        var privateItems = try fetch("ClipRecord").compactMap { object -> ClipItem? in
            guard let payload = object.value(forKey: "payload") as? Data else { return nil }; return try decoder.decode(ClipItem.self, from: payload)
        }
        let boards = try fetch("BoardRecord").compactMap { object -> Pinboard? in
            guard let payload = object.value(forKey: "payload") as? Data else { return nil }; return try decoder.decode(Pinboard.self, from: payload)
        }
        let shared = try fetch("SharedClipRecord").compactMap { object -> ClipItem? in
            guard let payload = object.value(forKey: "payload") as? Data else { return nil }; return try decoder.decode(ClipItem.self, from: payload)
        }
        let boardIDs = Set(boards.map(\.id)), sharedIDs = Set(shared.map(\.id))
        for offset in privateItems.indices {
            if let boardID = privateItems[offset].pinboardID, (!boardIDs.contains(boardID) || !sharedIDs.contains(privateItems[offset].id)) {
                // A removed share must not leave an invisible, permanently retained item.
                // Keep the original private copy as ordinary history; later out-of-order
                // shared imports can safely reconnect it without losing user content.
                privateItems[offset].pinboardID = nil; privateItems[offset].isInHistory = true
                try writeClip(privateItems[offset], entity:"ClipRecord")
            }
        }
        if context.hasChanges { try context.save() }
        var byID = Dictionary(privateItems.map { ($0.id, $0) }, uniquingKeysWith: { $0.modifiedAt > $1.modifiedAt ? $0 : $1 })
        for item in shared { if var existing = byID[item.id] { if item.modifiedAt > existing.modifiedAt { var updated = item; updated.isInHistory = existing.isInHistory; byID[item.id] = updated } else { existing.pinboardID = item.pinboardID; byID[item.id] = existing } } else { var copy = item; copy.isInHistory = false; byID[item.id] = copy } }
        items = byID.values.sorted { $0.createdAt > $1.createdAt }
        pinboards = boards.sorted { $0.order < $1.order }
        if let pref = try fetch("PreferenceRecord").sorted(by: { ($0.value(forKey: "modifiedAt") as? Date ?? .distantPast) > ($1.value(forKey: "modifiedAt") as? Date ?? .distantPast) }).first, let data = pref.value(forKey: "payload") as? Data { settings = try decoder.decode(LibrarySettings.self, from: data) }
        devicePreferences.apply(to:&settings)
        let previous = Set(indexedItems.keys), current = Set(items.map(\.id))
        for id in previous.subtracting(current) { try index.remove(id); indexedItems.removeValue(forKey:id) }
        for item in items where indexedItems[item.id] != item { try index.upsert(item); indexedItems[item.id] = item }
        revision += 1
    }
    public func results(query: String = "", filter: SearchFilter = .init(), boardID: UUID? = nil, allLocations: Bool = false) -> [ClipItem] {
        let matches: Set<UUID>? = query.isEmpty ? nil : Set((try? index.search(query, limit: max(items.count, 1))) ?? [])
        return items.filter { item in
            filter.matches(item) && (matches == nil || matches!.contains(item.id)) && (allLocations || (boardID.map { item.pinboardID == $0 } ?? item.isInHistory))
        }.sorted { boardID != nil ? ($0.order == $1.order ? $0.createdAt > $1.createdAt : $0.order < $1.order) : $0.createdAt > $1.createdAt }
    }
    public func materialized(_ item: ClipItem) throws -> ClipItem {
        var result = item
        if let object = try find("SharedClipRecord", id: item.id) ?? find("ClipRecord", id: item.id) {
            result.data = object.value(forKey: "asset") as? Data
            result.richData = object.value(forKey: "rich") as? Data
        }
        return result
    }
    public func add(_ item: ClipItem) throws {
        try withManagedMutation {
            try writeClip(item, entity: "ClipRecord"); try commit()
        }
    }
    public func update(_ item: ClipItem, replacingAssets: Bool = false) throws {
        try withManagedMutation {
            var updated = item; updated.modifiedAt = .now
            if try find("ClipRecord", id: item.id) != nil { try writeClip(updated, entity: "ClipRecord", replaceAssets: replacingAssets) }
            if let shared = try find("SharedClipRecord", id: item.id) { try requireWritable(shared); try writeClip(updated, entity: "SharedClipRecord", existing: shared, replaceAssets: replacingAssets) }
            try commit()
        }
    }
    public func updateSettings(_ newSettings:LibrarySettings) throws {
        try withManagedMutation {
            let previous=devicePreferences
            devicePreferences=DevicePreferences(newSettings)
            do {
                if !memory {try JSONEncoder().encode(devicePreferences).write(to:directory.appendingPathComponent("DeviceSettings.json"),options:.atomic)}
                var synced=newSettings
                synced.mcpEnabled=false;synced.suggestionsEnabled=false;synced.syncEnabled=false;synced.onboardingComplete=false;synced.showMenuBarIcon=true;synced.panelHeight=350
                let object=try fetch("PreferenceRecord").first ?? newObject("PreferenceRecord",store:"History")
                object.setValue("settings",forKey:"id");object.setValue(try JSONEncoder().encode(synced),forKey:"payload");object.setValue(Date(),forKey:"modifiedAt")
                try commit()
            } catch {
                context.rollback();devicePreferences=previous
                if !memory {try? JSONEncoder().encode(previous).write(to:directory.appendingPathComponent("DeviceSettings.json"),options:.atomic)}
                throw error
            }
        }
    }
    @discardableResult public func createBoard(name: String, colorHex: String = "30B7A8") throws -> Pinboard {
        return try withManagedMutation {
            let board = Pinboard(name: name.isEmpty ? "Untitled board" : name, colorHex: colorHex, order: Double(pinboards.count))
            try writeBoard(board); try commit(); return board
        }
    }
    public func updateBoard(_ board: Pinboard) throws {
        try withManagedMutation {
            try writeBoard(board); try commit()
        }
    }
    public func pin(_ ids: [UUID], to boardID: UUID?) throws {
        try withManagedMutation {
            let locations = try items.filter { ids.contains($0.id) }.map {
                ItemLocation(id: $0.id, boardID: $0.pinboardID, isInHistory: $0.isInHistory,
                             order: $0.order, hadPrivateCopy: try find("ClipRecord", id: $0.id) != nil)
            }
            guard !locations.isEmpty else { return }
            do {
                let destination = try boardID.flatMap { try find("BoardRecord", id: $0) }
                if boardID != nil && destination == nil { throw StoreError.unavailable }
                if let destination { try requireWritable(destination) }
                for location in locations {
                    guard let original = items.first(where: { $0.id == location.id }) else { continue }
                    var item = try materialized(original)
                    item.pinboardID = boardID
                    if boardID == nil { item.isInHistory = true }
                    item.modifiedAt = .now
                    item.order = Double(items.filter { $0.pinboardID == boardID }.count)
                    try restoreLocation(item, keepPrivateCopy: location.hadPrivateCopy || boardID == nil, destination: destination)
                }
                try commit()
                remember(.move(locations))
            } catch { context.rollback(); throw error }
        }
    }
    public func delete(_ ids: [UUID], undoable: Bool = true) throws {
        try withManagedMutation {
            let deleted = undoable ? try deletionSnapshot(ids: ids) : []
            let affected = try managedFileIDs(for: items.filter { ids.contains($0.id) })
            do {
                for id in ids {
                    for entity in ["ClipRecord", "SharedClipRecord"] {
                        if let object = try find(entity, id: id) { try requireWritable(object); context.delete(object) }
                    }
                }
                try commit()
                if undoable && !deleted.isEmpty { remember(.deletion(deleted, board: nil)) }
                try cleanManagedFiles(Array(affected))
            } catch { context.rollback(); throw error }
        }
    }
    public func deleteBoard(_ id: UUID) throws {
        try withManagedMutation {
            guard let board = try find("BoardRecord", id: id),
                  let metadata = pinboards.first(where: { $0.id == id }) else { return }
            let deleted = try deletionSnapshot(ids: items.filter { $0.pinboardID == id }.map(\.id))
            let affected = try managedFileIDs(for: deleted.map(\.item))
            // A board from an accepted share must not be recreated as though access survived.
            let recovery = DeletedBoard(board: metadata, mayRecreate: board.objectID.persistentStore?.url?.lastPathComponent != "Shared.sqlite")
            do {
                try requireWritable(board)
                for snapshot in deleted {
                    if let original = try find("ClipRecord", id: snapshot.item.id) { context.delete(original) }
                }
                context.delete(board)
                try commit()
                remember(.deletion(deleted, board: recovery))
                try cleanManagedFiles(Array(affected))
            } catch { context.rollback(); throw error }
        }
    }
    public func eraseHistory() throws {
        try withManagedMutation {
            var removed: [UUID] = []
            for item in items where item.isInHistory {
                if item.pinboardID == nil { if let object = try find("ClipRecord", id: item.id) { try requireWritable(object); removed.append(contentsOf: try managedFileIDs(for: [item])); context.delete(object) } }
                else { var copy = item; copy.isInHistory = false; try writeClip(copy, entity: "ClipRecord") }
            }
            try commit(); undoEntries.removeAll()
            try cleanManagedFiles(removed)
        }
    }
    public func applyRetention(now: Date = .now) throws {
        try withManagedMutation {
            var removed: [UUID] = []
            for item in items where item.isInHistory {
                switch Retention.action(for: item, days: settings.retentionDays, now: now) {
                case .keep: break
                case .delete: if let object = try find("ClipRecord", id: item.id) { try requireWritable(object); removed.append(contentsOf: try managedFileIDs(for: [item])); context.delete(object) }
                case .removeFromHistory: var copy = item; copy.isInHistory = false; try writeClip(copy, entity: "ClipRecord")
                }
            }
            if context.hasChanges { try commit() }
            try cleanManagedFiles(removed)
        }
    }
    public func archive() throws -> Data { try LibraryArchive(items: items.map { try materialized($0) }, pinboards: pinboards, settings: settings).encode() }
    public func importArchive(_ data: Data) throws {
        try withManagedMutation {
            let archive = try LibraryArchive.decode(data)
            do {
                for board in archive.pinboards { try writeBoard(board) }
                for item in archive.items {
                    if let existing = try find("SharedClipRecord", id:item.id) { try requireWritable(existing); if item.pinboardID == nil { context.delete(existing) } }
                    try writeClip(item, entity: "ClipRecord", replaceAssets: true)
                    if let id = item.pinboardID, let board = try find("BoardRecord", id: id) { try requireWritable(board); try writeClip(item, entity: "SharedClipRecord", parent: board, replaceAssets: true) }
                }
                try commit()
            } catch { context.rollback(); throw error }
        }
    }
    @discardableResult public func importPasteBarBackup(from url: URL, now: Date = .now) async throws -> PasteBarImportSummary {
        let migration = try await Task.detached(priority: .userInitiated) { try PasteBarImporter(url: url, now: now) }.value
        return try withManagedMutation {
            var summary = migration.summary
            var inserted: [(String, String)] = []
            var checkedPrivateDestinations: Set<UUID> = []
            for board in migration.pinboards {
                if try find("BoardRecord", id: board.id) == nil {
                    var appended = board; appended.order = Double(pinboards.count + summary.importedPinboards)
                    try writeBoard(appended)
                    inserted.append(("BoardRecord", board.id.uuidString))
                    summary.importedPinboards += 1
                }
            }
            for item in migration.items {
                if try find("ClipRecord", id: item.id) != nil || find("SharedClipRecord", id: item.id) != nil {
                    summary.duplicates += 1
                } else if let boardID = item.pinboardID {
                    guard let board = try find("BoardRecord", id: boardID) else { throw StoreError.unavailable }
                    if checkedPrivateDestinations.insert(boardID).inserted { try requirePrivatePasteBarDestination(board) }
                    try requireWritable(board)
                    try writeClip(item, entity: "SharedClipRecord", parent: board, replaceAssets: true)
                    inserted.append(("SharedClipRecord", item.id.uuidString))
                    summary.importedSavedClips += 1
                } else {
                    try writeClip(item, entity: "ClipRecord", replaceAssets: true)
                    inserted.append(("ClipRecord", item.id.uuidString))
                    summary.importedHistory += 1
                }
            }
            if summary.importedHistory + summary.importedSavedClips + summary.importedPinboards > 0 {
                do {
                    for object in context.insertedObjects { try object.validateForInsert() }
                    try writePasteBarJournal(inserted, committed: false)
                    try persistenceSaveCheck?()
                    try context.save()
                    try writePasteBarJournal(inserted, committed: true)
                } catch {
                    let saveError = error
                    context.rollback()
                    do {
                        try removeCommittedMigrationRecords(inserted)
                        try clearPasteBarJournal()
                        try reloadUnlocked()
                    } catch { throw PasteBarImportError.recoveryFailed }
                    throw saveError
                }
                try? clearPasteBarJournal()
                // A refresh failure cannot roll back an already committed import.
                do { try reloadUnlocked() } catch { summary.needsRefresh = true }
            }
            return summary
        }
    }
    private func requirePrivatePasteBarDestination(_ board: NSManagedObject) throws {
        guard board.objectID.persistentStore?.url?.lastPathComponent != "Shared.sqlite" else { throw StoreError.privateImportDestination }
        guard !board.isInserted else { return }
        // A writable destination can still publish newly imported content to share participants.
        let shared: Bool
        do { shared = try pasteBarBoardShareCheck?(board.objectID) ?? (container.fetchShares(matching: [board.objectID])[board.objectID] != nil) }
        catch { throw StoreError.privateImportDestination }
        guard !shared else { throw StoreError.privateImportDestination }
    }
    @ObservationIgnored internal var pasteBarBoardShareCheck: ((NSManagedObjectID) throws -> Bool)?
    @ObservationIgnored internal var pasteBarRecoveryCheck: (() throws -> Void)?
    private var pasteBarJournalURL: URL { directory.appendingPathComponent("PasteBarImport.pending.json") }
    private func writePasteBarJournal(_ records: [(String, String)], committed: Bool) throws {
        guard !memory else { return }
        let journal = PasteBarImportJournal(committed: committed, records: Dictionary(grouping: records, by: { $0.0 }).mapValues { $0.map { $0.1 } })
        try JSONEncoder().encode(journal).write(to: pasteBarJournalURL, options: .atomic)
        if !committed { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pasteBarJournalURL.path) }
    }
    private func clearPasteBarJournal() throws {
        if !memory && FileManager.default.fileExists(atPath: pasteBarJournalURL.path) { try FileManager.default.removeItem(at: pasteBarJournalURL) }
    }
    private func recoverPendingPasteBarImport() throws {
        guard !memory, FileManager.default.fileExists(atPath: pasteBarJournalURL.path) else { return }
        let size = try FileManager.default.attributesOfItem(atPath: pasteBarJournalURL.path)[.size] as? NSNumber
        guard let size, size.intValue <= 16 * 1024 * 1024 else { throw PasteBarImportError.recoveryFailed }
        guard let data = try? Data(contentsOf: pasteBarJournalURL), let journal = try? JSONDecoder().decode(PasteBarImportJournal.self, from: data) else { throw PasteBarImportError.recoveryFailed }
        guard Set(journal.records.keys).isSubset(of: ["ClipRecord", "SharedClipRecord", "BoardRecord"]),
              journal.records.values.reduce(0, { $0 + $1.count }) <= 200_000,
              journal.records.values.joined().allSatisfy({ UUID(uuidString: $0) != nil }) else { throw PasteBarImportError.recoveryFailed }
        if journal.committed { try? clearPasteBarJournal(); return }
        do {
            try removeCommittedMigrationRecords(journal.records.flatMap { entity, ids in ids.map { (entity, $0) } })
            try clearPasteBarJournal()
        } catch { throw PasteBarImportError.recoveryFailed }
    }
    private func removeCommittedMigrationRecords(_ inserted: [(String, String)]) throws {
        // Core Data can commit one store before another fails; rollback only clears pending edits.
        let recovery = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        recovery.persistentStoreCoordinator = container.persistentStoreCoordinator
        for (entity, records) in Dictionary(grouping: inserted, by: { $0.0 }) {
            let ids = records.map { $0.1 }
            for start in stride(from: 0, to: ids.count, by: 500) {
                let request = NSFetchRequest<NSManagedObject>(entityName: entity)
                request.predicate = NSPredicate(format: "id IN %@", Array(ids[start..<min(start + 500, ids.count)]))
                for object in try recovery.fetch(request) { recovery.delete(object) }
            }
        }
        if recovery.hasChanges { try pasteBarRecoveryCheck?(); try recovery.save() }
        context.refreshAllObjects()
    }
    public func undo() throws {
        try withManagedMutation {
            guard let entry = undoEntries.last else { return }
            var recreated: [FileAssets.ManagedReference] = []
            do {
                try reloadUnlocked()
                var copiesToRestore: [FileAssets.ManagedCopy] = []
                switch entry {
                case .move(let locations):
                    for location in locations {
                        guard let current = items.first(where: { $0.id == location.id }) else { continue }
                        var item = try materialized(current)
                        let destination = try location.boardID.flatMap { try find("BoardRecord", id: $0) }
                        item.pinboardID = location.boardID
                        item.isInHistory = location.isInHistory
                        item.order = location.order
                        if location.boardID != nil && destination == nil {
                            // ADR 0001: recover surviving private content, never recreate a removed share.
                            guard try find("ClipRecord", id: item.id) != nil else { throw StoreError.unavailable }
                            item.pinboardID = nil
                            item.isInHistory = true
                        }
                        item.modifiedAt = .now
                        try restoreLocation(item, keepPrivateCopy: location.hadPrivateCopy || item.pinboardID == nil, destination: destination)
                    }
                case .deletion(let deleted, let boardRecovery):
                    if let recovery = boardRecovery, try find("BoardRecord", id: recovery.board.id) == nil, recovery.mayRecreate {
                        try writeBoard(recovery.board)
                    }
                    for snapshot in deleted {
                        // Another writer may already have recovered this identity. Keep its later edits.
                        guard !items.contains(where: { $0.id == snapshot.item.id }) else { continue }
                        var item = snapshot.item
                        let destination = try item.pinboardID.flatMap { try find("BoardRecord", id: $0) }
                        if item.pinboardID != nil && destination == nil {
                            guard snapshot.hadPrivateCopy else { throw StoreError.unavailable }
                            item.pinboardID = nil
                            item.isInHistory = true
                        }
                        try restoreLocation(item, keepPrivateCopy: snapshot.hadPrivateCopy || item.pinboardID == nil, destination: destination)
                        copiesToRestore.append(contentsOf: snapshot.managedCopies)
                    }
                }
                for copy in copiesToRestore where !memory {
                    if try FileAssets.restore(copy, directory: directory) { recreated.append(copy.reference) }
                }
                try commit()
                undoEntries.removeLast()
            } catch {
                context.rollback()
                // A failed save must not leave newly recreated, unowned contents behind.
                // If save succeeded but reload failed, committed ownership preserves them.
                if let owners = try? committedManagedOwners() {
                    for reference in recreated where !owners.contains(reference.ownerID) {
                        try? FileAssets.removeRestored(reference, directory: directory)
                    }
                }
                throw error
            }
        }
    }
    public func sharedGraphItemIDs(_ id: UUID) throws -> [UUID] { guard let board = try find("BoardRecord", id: id) else { return [] }; let children = board.value(forKey: "clips") as? Set<NSManagedObject> ?? []; return children.compactMap { ($0.value(forKey: "id") as? String).flatMap(UUID.init(uuidString:)) } }
    public func boardObject(_ id: UUID) throws -> NSManagedObject? { try find("BoardRecord", id: id) }
    public func boardIsWritable(_ id: UUID) -> Bool { guard let board = try? find("BoardRecord", id: id) else { return false }; return memory || !settings.syncEnabled || container.canUpdateRecord(forManagedObjectWith: board.objectID) }
    public func shareBoard(_ id: UUID) async throws -> CKShare {
        guard settings.syncEnabled, let board = try find("BoardRecord", id: id) else { throw StoreError.syncDisabled }
        if let existing = try container.fetchShares(matching: [board.objectID])[board.objectID] { return existing }
        return try await withCheckedThrowingContinuation { continuation in
            container.share([board], to: nil) { _, share, _, error in
                if let error { continuation.resume(throwing: error) } else if let share { continuation.resume(returning: share) } else { continuation.resume(throwing: StoreError.unavailable) }
            }
        }
    }
    public func acceptShare(_ metadata: CKShare.Metadata) async throws {
        guard let store = container.persistentStoreCoordinator.persistentStores.first(where: { $0.url?.lastPathComponent == "Shared.sqlite" }) else { throw StoreError.syncDisabled }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in container.acceptShareInvitations(from: [metadata], into: store) { _, error in if let error { continuation.resume(throwing: error) } else { continuation.resume() } } }
        try reload()
    }
    @ObservationIgnored private var pendingFileCleanup: Set<UUID> = []
    // Fault injection at the filesystem boundary; production always uses FileManager.
    @ObservationIgnored internal var managedFileRemoval: ((URL) throws -> Void)?

    private func withManagedMutation<T>(_ body: () throws -> T) throws -> T {
        func operation() throws -> T {
            try self.reloadUnlocked()
            do { return try body() }
            catch { self.context.rollback(); throw error }
        }
        // Memory-only sessions never touch the user's default library on disk.
        if memory { return try operation() }
        return try FileAssets.withManagedAccess(directory: directory, operation)
    }

    /// Retry only previously affected identities, rechecking committed ownership first.
    public func retryManagedFileCleanup() throws {
        try withManagedMutation { try cleanManagedFiles([]) }
    }

    private func cleanManagedFiles(_ affected: [UUID]) throws {
        guard !memory else { return }
        pendingFileCleanup.formUnion(affected)
        guard !pendingFileCleanup.isEmpty else { return }
        let owners: Set<UUID>
        do { owners = try committedManagedOwners() }
        catch { throw ManagedFileCleanupError() }
        var failed = false
        for id in pendingFileCleanup {
            do {
                if !owners.contains(id) {
                    let folder = try FileAssets.managedFolder(for: id, directory: directory)
                    if FileManager.default.fileExists(atPath: folder.path) {
                        if let managedFileRemoval { try managedFileRemoval(folder) }
                        else { try FileManager.default.removeItem(at: folder) }
                    }
                }
                pendingFileCleanup.remove(id)
            } catch { failed = true }
        }
        if failed { throw ManagedFileCleanupError() }
    }

    private func managedFileIDs(for selected: [ClipItem]) throws -> Set<UUID> {
        var ids = Set(selected.map(\.id))
        guard !memory else { return ids }
        for item in selected {
            let full = try materialized(item)
            ids.formUnion(try FileAssets.managedReferences(for: full, directory: directory).map(\.ownerID))
        }
        return ids
    }

    /// Consult committed metadata, including different identities referencing a managed copy.
    private func committedManagedOwners() throws -> Set<UUID> {
        let committed = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        committed.persistentStoreCoordinator = container.persistentStoreCoordinator
        var owners: Set<UUID> = []
        for entity in ["ClipRecord", "SharedClipRecord"] {
            let request = NSFetchRequest<NSManagedObject>(entityName: entity)
            request.includesPendingChanges = false
            for record in try committed.fetch(request) {
                if let raw = record.value(forKey: "id") as? String, let id = UUID(uuidString: raw) { owners.insert(id) }
                guard let data = record.value(forKey: "payload") as? Data else { continue }
                let item = try JSONDecoder().decode(ClipItem.self, from: data)
                if item.kind == .file && record.value(forKey: "asset") == nil {
                    owners.formUnion(try FileAssets.managedReferences(for: item, directory: directory).map(\.ownerID))
                }
            }
        }
        return owners
    }

    public struct ManagedFileCleanupError: LocalizedError {
        public var errorDescription: String? {
            "The records were deleted, but some managed attachment files could not be removed. Retry attachment cleanup or erase history again."
        }
    }

    private func deletionSnapshot(ids: [UUID]) throws -> [DeletedItem] {
        try items.filter { ids.contains($0.id) }.map {
            let full = try materialized($0)
            return DeletedItem(item: full, hadPrivateCopy: try find("ClipRecord", id: $0.id) != nil,
                               managedCopies: memory ? [] : try FileAssets.recoveryCopies(for: full, directory: directory))
        }
    }
    private func remember(_ entry: UndoEntry) {
        undoEntries.append(entry)
        if undoEntries.count > 10 { undoEntries.removeFirst() }
    }
    private func restoreLocation(_ item: ClipItem, keepPrivateCopy: Bool, destination: NSManagedObject?) throws {
        if let destination { try requireWritable(destination) }
        if let shared = try find("SharedClipRecord", id: item.id) {
            try requireWritable(shared)
            context.delete(shared)
        }
        if let destination { try writeClip(item, entity: "SharedClipRecord", parent: destination, replaceAssets: true) }
        if keepPrivateCopy {
            try writeClip(item, entity: "ClipRecord", replaceAssets: true)
        } else if let original = try find("ClipRecord", id: item.id) {
            context.delete(original)
        }
    }
    @ObservationIgnored internal var persistenceSaveCheck: (() throws -> Void)?
    private func commit() throws { do { try persistenceSaveCheck?(); try context.save(); try reloadUnlocked() } catch { context.rollback(); throw error } }
    private func requireWritable(_ object: NSManagedObject) throws { if let writePermissionCheck, !writePermissionCheck(object) { throw StoreError.readOnly }; if settings.syncEnabled && !memory && !container.canUpdateRecord(forManagedObjectWith: object.objectID) { throw StoreError.readOnly } }
    private func fetch(_ entity: String) throws -> [NSManagedObject] { let request = NSFetchRequest<NSManagedObject>(entityName: entity); request.fetchBatchSize = 100; return try context.fetch(request) }
    private func find(_ entity: String, id: UUID) throws -> NSManagedObject? { let request = NSFetchRequest<NSManagedObject>(entityName: entity); request.predicate = NSPredicate(format: "id == %@", id.uuidString); request.fetchLimit = 1; return try context.fetch(request).first }
    private func newObject(_ entity: String, store name: String) -> NSManagedObject {
        let object = NSEntityDescription.insertNewObject(forEntityName: entity, into: context)
        if let store = container.persistentStoreCoordinator.persistentStores.first(where: { $0.url?.lastPathComponent == name + ".sqlite" || (memory && $0.configurationName == (name == "History" ? "History" : "Boards")) }) { context.assign(object, to: store) }
        return object
    }
    private func writeBoard(_ board: Pinboard) throws {
        let object = try find("BoardRecord", id: board.id) ?? newObject("BoardRecord", store: "Boards")
        if !object.isInserted { try requireWritable(object) }
        object.setValue(board.id.uuidString, forKey: "id"); object.setValue(try JSONEncoder().encode(board), forKey: "payload")
    }
    private func writeClip(_ item: ClipItem, entity: String, existing: NSManagedObject? = nil, parent: NSManagedObject? = nil, replaceAssets: Bool = false) throws {
        let object = try existing ?? find(entity, id: item.id) ?? newObject(entity, store: entity == "ClipRecord" ? "History" : "Boards")
        var metadata = item; metadata.data = nil; metadata.richData = nil
        object.setValue(item.id.uuidString, forKey: "id"); object.setValue(try JSONEncoder().encode(metadata), forKey: "payload")
        if replaceAssets || item.data != nil || object.isInserted { object.setValue(item.data, forKey: "asset") }
        if replaceAssets || item.richData != nil || object.isInserted { object.setValue(item.richData, forKey: "rich") }
        if let parent { object.setValue(parent, forKey: "board"); if object.isInserted, let store = parent.objectID.persistentStore { context.assign(object, to: store) } }
    }
    private static func model() -> NSManagedObjectModel {
        func attribute(_ name: String, _ type: NSAttributeType, external: Bool = false) -> NSAttributeDescription { let a = NSAttributeDescription(); a.name = name; a.attributeType = type; a.isOptional = true; a.allowsExternalBinaryDataStorage = external; return a }
        func entity(_ name: String, assets: Bool = false) -> NSEntityDescription { let e = NSEntityDescription(); e.name = name; e.managedObjectClassName = "NSManagedObject"; e.properties = [attribute("id", .stringAttributeType), attribute("payload", .binaryDataAttributeType)]; if assets { e.properties += [attribute("asset", .binaryDataAttributeType, external: true), attribute("rich", .binaryDataAttributeType, external: true)] }; return e }
        let clip = entity("ClipRecord", assets: true), preference = entity("PreferenceRecord"), board = entity("BoardRecord"), shared = entity("SharedClipRecord", assets: true)
        preference.properties += [attribute("modifiedAt", .dateAttributeType)]
        let clips = NSRelationshipDescription(); clips.name = "clips"; clips.destinationEntity = shared; clips.minCount = 0; clips.maxCount = 0; clips.isOptional = true; clips.deleteRule = .cascadeDeleteRule
        let owner = NSRelationshipDescription(); owner.name = "board"; owner.destinationEntity = board; owner.minCount = 0; owner.maxCount = 1; owner.isOptional = true; owner.deleteRule = .nullifyDeleteRule
        clips.inverseRelationship = owner; owner.inverseRelationship = clips; board.properties += [clips]; shared.properties += [owner]
        let model = NSManagedObjectModel(); model.entities = [clip, preference, board, shared]; model.setEntities([clip, preference], forConfigurationName: "History"); model.setEntities([board, shared], forConfigurationName: "Boards"); return model
    }
    public enum StoreError: LocalizedError { case readOnly, syncDisabled, unavailable, privateImportDestination
        public var errorDescription: String? { switch self { case .privateImportDestination: "PasteBar migration requires a private pinboard; this destination is shared or its sharing status could not be checked."; case .readOnly: "This shared pinboard is read-only."; case .syncDisabled: "Enable iCloud Sync and reopen Stash before sharing."; case .unavailable: "The operation is not available right now." } }
    }
}

/// NotificationCenter owns block observers independently of the token array.
/// Keep registrations in a lifetime owner so successful and partial library
/// initialization release every token without requiring an actor-isolated deinit.
private final class LibraryNotificationRegistrations {
    private let center: NotificationCenter
    private var tokens: [NSObjectProtocol] = []

    init(center: NotificationCenter) { self.center = center }
    func append(_ token: NSObjectProtocol) { tokens.append(token) }
    deinit { for token in tokens { center.removeObserver(token) } }
}

private struct PasteBarImportJournal: Codable {
    let committed: Bool
    let records: [String: [String]]
}
