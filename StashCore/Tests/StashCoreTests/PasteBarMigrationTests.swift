import XCTest
import CSQLite
import CoreData
@testable import StashCore

final class PasteBarMigrationTests: XCTestCase {
    @MainActor func testHistoryMigrationAndRepeatPreserveEdits() async throws {
        let backup = try PasteBarFixture(sql: "INSERT INTO clipboard_history(history_id,value,is_text) VALUES ('text-1','hello',1),('text-2','hello',1); INSERT INTO clipboard_history(history_id,value,is_link) VALUES ('link','https://example.com',1); INSERT INTO clipboard_history(history_id,value,is_code) VALUES ('code','print(1)',1);")
        defer { backup.remove() }
        let store = try LibraryStore(inMemory: true)
        let existing = ClipItem(kind: .text, text: "existing")
        try store.add(existing)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let summary = try await store.importPasteBarBackup(from: backup.url, now: now)
        XCTAssertEqual(summary.importedHistory, 4)
        XCTAssertEqual(store.items.count, 5)
        let migrated = store.items.filter { $0.id != existing.id }
        XCTAssertTrue(migrated.allSatisfy { $0.createdAt == now && $0.modifiedAt == now && $0.isInHistory })
        XCTAssertEqual(Set(migrated.map(\.kind)), [.text, .link, .code])
        var edited = try XCTUnwrap(migrated.first)
        edited.text = "edited in Stash"
        try store.update(edited)
        let second = try await store.importPasteBarBackup(from: backup.url, now: now.addingTimeInterval(100))
        XCTAssertEqual(second.duplicates, 4)
        XCTAssertEqual(second.importedHistory, 0)
        XCTAssertEqual(store.items.first { $0.id == edited.id }?.text, "edited in Stash")
        XCTAssertEqual(store.settings.retentionDays, 30)
    }
    @MainActor func testSavedClipsKeepSourceDatesAndOrganizationOnRepeat() async throws {
        let backup = try PasteBarFixture(sql: Self.savedSchema + """
        INSERT INTO collections VALUES ('collection','Work');
        INSERT INTO tabs VALUES ('tab','collection','Writing',0,'#123ABC',0);
        INSERT INTO items(item_id,name,value,is_text,created_at) VALUES ('clip','Draft','saved content',1,1700000000000);
        INSERT INTO items(item_id,name,is_folder) VALUES ('folder','Campaign',1);
        INSERT INTO collection_clips VALUES ('collection','tab','folder',NULL,0),('collection','tab','clip','folder',2);
        INSERT INTO clipboard_history(history_id,value,is_text) VALUES ('clip','saved content',1);
        """)
        defer { backup.remove() }
        let store = try LibraryStore(inMemory: true)
        try await store.importPasteBarBackup(from: backup.url)
        XCTAssertEqual(store.pinboards.count, 1)
        let board = try XCTUnwrap(store.pinboards.first)
        XCTAssertEqual(board.name, "Work / Writing")
        XCTAssertEqual(board.colorHex, "123ABC")
        var clip = try XCTUnwrap(store.items.first { $0.pinboardID == board.id })
        XCTAssertFalse(clip.isInHistory)
        XCTAssertEqual(clip.title, "Campaign / Draft")
        XCTAssertEqual(clip.createdAt, Date(timeIntervalSince1970: 1700000000))
        XCTAssertEqual(clip.order, 0)
        XCTAssertEqual(store.items.count, 2)
        clip.text = "edited saved clip"
        try store.update(clip)
        var editedBoard = board; editedBoard.name = "Edited board"
        try store.updateBoard(editedBoard)
        try await store.importPasteBarBackup(from: backup.url)
        XCTAssertEqual(store.items.count, 2)
        XCTAssertEqual(store.pinboards.first?.name, "Edited board")
        XCTAssertEqual(store.items.first { $0.id == clip.id }?.text, "edited saved clip")
    }

    @MainActor func testIncompleteMultiStoreSaveRemovesOnlyCommittedMigrationRows() async throws {
        let backup = try PasteBarFixture(sql: Self.savedSchema + """
        INSERT INTO collections VALUES ('collection','Work');
        INSERT INTO tabs VALUES ('tab','collection','Writing',0,NULL,0);
        INSERT INTO items(item_id,name,value,is_text) VALUES ('saved','Draft','saved',1);
        INSERT INTO collection_clips VALUES ('collection','tab','saved',NULL,0);
        INSERT INTO clipboard_history(history_id,value,is_text) VALUES ('history','new history',1);
        """)
        defer { backup.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LibraryStore(directory: directory)
        let original = ClipItem(kind: .text, text: "unrelated")
        try store.add(original)
        store.persistenceSaveCheck = {
            // Persist the History portion, then model Core Data's incomplete-save error.
            let partial = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
            partial.persistentStoreCoordinator = store.container.persistentStoreCoordinator
            for pending in store.context.insertedObjects where pending.entity.name == "ClipRecord" {
                let copy = NSEntityDescription.insertNewObject(forEntityName: "ClipRecord", into: partial)
                for key in pending.entity.attributesByName.keys { copy.setValue(pending.value(forKey: key), forKey: key) }
            }
            try partial.save()
            throw NSError(domain: NSCocoaErrorDomain, code: NSPersistentStoreIncompleteSaveError)
        }
        do { try await store.importPasteBarBackup(from: backup.url); XCTFail("Expected incomplete save") } catch {}
        XCTAssertEqual(store.items.map(\.id), [original.id])
        let reopened = try LibraryStore(directory: directory)
        XCTAssertEqual(reopened.items.map(\.id), [original.id])
        XCTAssertTrue(reopened.pinboards.isEmpty)
        store.persistenceSaveCheck = nil
        let result = try await store.importPasteBarBackup(from: backup.url)
        XCTAssertEqual(result.importedHistory, 1)
        XCTAssertEqual(result.importedSavedClips, 1)
    }

    @MainActor func testSavedMembershipCopiesMediaAndProtectedAncestry() async throws {
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aL1sAAAAASUVORK5CYII=")!
        let backup = try PasteBarFixture(sql: Self.savedSchema + """
        INSERT INTO collections VALUES ('c','Work');
        INSERT INTO tabs VALUES ('a','c','First',0,'invalid',0),('b','c','Second',1,NULL,0),('secret','c','Secret',2,NULL,1);
        INSERT INTO items(item_id,name,value,is_text) VALUES ('same','Same','shared content',1),('masked','Masked','[mask]hidden[/mask]',1),('child','Child','hidden child',1);
        INSERT INTO items(item_id,name,is_folder,is_protected) VALUES ('folder','Private folder',1,1);
        INSERT INTO items(item_id,name,value,is_command) VALUES ('command','Command','echo unsafe',1);
        INSERT INTO items(item_id,name,is_image,image_path_full_res) VALUES ('image','Image',1,'{{base_folder}}/clip-images/img/image.png');
        INSERT INTO items(item_id,name,value,is_file) VALUES ('file','Document','/missing/external/document.txt',1);
        INSERT INTO collection_clips VALUES ('c','a','same',NULL,0),('c','b','same',NULL,0),('c','secret','same',NULL,0),('c','a','masked',NULL,1),('c','a','folder',NULL,2),('c','a','child','folder',3),('c','a','command',NULL,4),('c','a','image',NULL,5),('c','a','file',NULL,6);
        """, images: ["clip-images/img/image.png": png])
        defer { backup.remove() }
        let store = try LibraryStore(inMemory: true)
        let result = try await store.importPasteBarBackup(from: backup.url)
        XCTAssertEqual(result.importedSavedClips, 4)
        XCTAssertEqual(result.importedPinboards, 2)
        XCTAssertEqual(result.protectedRecords, 3)
        XCTAssertEqual(result.unsupportedRecords, 1)
        XCTAssertEqual(result.unresolvedFiles, 1)
        XCTAssertEqual(store.items.filter { $0.text == "shared content" }.count, 2)
        XCTAssertEqual(Set(store.items.filter { $0.text == "shared content" }.map(\.pinboardID)).count, 2)
        XCTAssertEqual(store.pinboards.first?.colorHex, "30B7A8")
        let image = try XCTUnwrap(store.items.first { $0.kind == .image })
        XCTAssertEqual(try store.materialized(image).data, png)
        XCTAssertFalse(store.items.contains { $0.text.contains("hidden") })
        let repeated = try await store.importPasteBarBackup(from: backup.url)
        XCTAssertEqual(repeated.duplicates, 4)
        XCTAssertEqual(store.items.count, 4)
    }

    @MainActor func testCyclicOrMissingSavedParentsFailBeforeWrites() async throws {
        for parent in ["folder", "missing"] {
            let backup = try PasteBarFixture(sql: Self.savedSchema + """
            INSERT INTO collections VALUES ('c','Work');
            INSERT INTO tabs VALUES ('t','c','Tab',0,NULL,0);
            INSERT INTO items(item_id,name,is_folder) VALUES ('folder','Loop',1);
            INSERT INTO items(item_id,name,value,is_text) VALUES ('child','Child','content',1);
            INSERT INTO collection_clips VALUES ('c','t','folder','folder',0),('c','t','child','\(parent)',1);
            INSERT INTO clipboard_history(history_id,value,is_text) VALUES ('new','new history',1);
            """)
            defer { backup.remove() }
            let store = try LibraryStore(inMemory: true)
            do { try await store.importPasteBarBackup(from: backup.url); XCTFail("Expected invalid hierarchy") } catch {}
            XCTAssertTrue(store.items.isEmpty)
            XCTAssertTrue(store.pinboards.isEmpty)
        }
    }

    @MainActor func testReadOnlyBoardStoreCannotLeaveHistoryPartOfImport() async throws {
        let backup = try PasteBarFixture(sql: Self.savedSchema + """
        INSERT INTO collections VALUES ('c','Work');
        INSERT INTO tabs VALUES ('t','c','Tab',0,NULL,0);
        INSERT INTO items(item_id,name,value,is_text) VALUES ('saved','Saved','saved',1);
        INSERT INTO collection_clips VALUES ('c','t','saved',NULL,0);
        INSERT INTO clipboard_history(history_id,value,is_text) VALUES ('new','new history',1);
        """)
        defer { backup.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LibraryStore(directory: directory)
        let boardStore = try XCTUnwrap(store.container.persistentStoreCoordinator.persistentStores.first { $0.url?.lastPathComponent == "Boards.sqlite" })
        boardStore.isReadOnly = true
        do { try await store.importPasteBarBackup(from: backup.url); XCTFail("Expected read-only store failure") } catch {}
        let reopened = try LibraryStore(directory: directory)
        XCTAssertTrue(reopened.items.isEmpty)
        XCTAssertTrue(reopened.pinboards.isEmpty)
    }

    @MainActor func testSavedHierarchyAndDerivedTitlesRespectResourceLimits() async throws {
        for largeTitle in [false, true] {
            let ancestors = largeTitle ? 1 : 257
            var sql = Self.savedSchema + "INSERT INTO collections VALUES ('c','Work'); INSERT INTO tabs VALUES ('t','c','Tab',0,NULL,0);"
            for index in 0..<ancestors {
                let name = largeTitle ? String(repeating: "a", count: 1024 * 1024 + 1) : "Folder"
                let parent = index == 0 ? "NULL" : "'folder-\(index - 1)'"
                sql += "INSERT INTO items(item_id,name,is_folder) VALUES ('folder-\(index)','\(name)',1); INSERT INTO collection_clips VALUES ('c','t','folder-\(index)',\(parent),0);"
            }
            sql += "INSERT INTO items(item_id,name,value,is_text) VALUES ('leaf','Leaf','content',1); INSERT INTO collection_clips VALUES ('c','t','leaf','folder-\(ancestors - 1)',1);"
            let backup = try PasteBarFixture(sql: sql)
            defer { backup.remove() }
            let store = try LibraryStore(inMemory: true)
            do { try await store.importPasteBarBackup(from: backup.url); XCTFail("Expected hierarchy/title limit") } catch {}
            XCTAssertTrue(store.items.isEmpty)
            XCTAssertTrue(store.pinboards.isEmpty)
        }
    }

    @MainActor func testReopenFinishesRollbackWhenCompensationInitiallyFails() async throws {
        let backup = try PasteBarFixture(sql: Self.savedSchema + """
        INSERT INTO collections VALUES ('c','Work');
        INSERT INTO tabs VALUES ('t','c','Tab',0,NULL,0);
        INSERT INTO items(item_id,name,value,is_text) VALUES ('saved','Saved','saved',1);
        INSERT INTO collection_clips VALUES ('c','t','saved',NULL,0);
        INSERT INTO clipboard_history(history_id,value,is_text) VALUES ('new','new history',1);
        """)
        defer { backup.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LibraryStore(directory: directory)
        let original = ClipItem(kind: .text, text: "keep unrelated")
        try store.add(original)
        store.persistenceSaveCheck = {
            let partial = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
            partial.persistentStoreCoordinator = store.container.persistentStoreCoordinator
            for pending in store.context.insertedObjects where pending.entity.name == "ClipRecord" {
                let copy = NSEntityDescription.insertNewObject(forEntityName: "ClipRecord", into: partial)
                for key in pending.entity.attributesByName.keys { copy.setValue(pending.value(forKey: key), forKey: key) }
            }
            try partial.save()
            throw NSError(domain: NSCocoaErrorDomain, code: NSPersistentStoreIncompleteSaveError)
        }
        store.pasteBarRecoveryCheck = { throw CocoaError(.fileWriteNoPermission) }
        do { try await store.importPasteBarBackup(from: backup.url); XCTFail("Expected recovery failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("recovery")) }
        let reopened = try LibraryStore(directory: directory)
        XCTAssertEqual(reopened.items.map(\.id), [original.id])
        XCTAssertTrue(reopened.pinboards.isEmpty)
        let retry = try await reopened.importPasteBarBackup(from: backup.url)
        XCTAssertEqual(retry.importedHistory, 1)
        XCTAssertEqual(retry.importedSavedClips, 1)
    }

    @MainActor func testNewMigrationContentCannotEnterReceivedSharedPinboard() async throws {
        let initial = try PasteBarFixture(sql: Self.sharedDestinationSQL(addingContent: false))
        let extended = try PasteBarFixture(sql: Self.sharedDestinationSQL(addingContent: true))
        defer { initial.remove(); extended.remove() }
        let identities = try LibraryStore(inMemory: true)
        try await identities.importPasteBarBackup(from: initial.url)
        let board = try XCTUnwrap(identities.pinboards.first)
        let existingClip = try XCTUnwrap(identities.items.first)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LibraryStore(directory: directory)
        let original = ClipItem(kind: .text, text: "unrelated private history")
        try store.add(original)
        let received = try XCTUnwrap(store.container.persistentStoreCoordinator.persistentStores.first { $0.url?.lastPathComponent == "Shared.sqlite" })
        let boardRecord = NSEntityDescription.insertNewObject(forEntityName: "BoardRecord", into: store.context)
        boardRecord.setValue(board.id.uuidString, forKey: "id")
        boardRecord.setValue(try JSONEncoder().encode(board), forKey: "payload")
        store.context.assign(boardRecord, to: received)
        let clipRecord = NSEntityDescription.insertNewObject(forEntityName: "SharedClipRecord", into: store.context)
        clipRecord.setValue(existingClip.id.uuidString, forKey: "id")
        clipRecord.setValue(try JSONEncoder().encode(existingClip), forKey: "payload")
        clipRecord.setValue(boardRecord, forKey: "board")
        store.context.assign(clipRecord, to: received)
        try store.context.save()
        try store.reload()
        do { try await store.importPasteBarBackup(from: extended.url); XCTFail("Private migration must reject a received shared destination") }
        catch { XCTAssertTrue(error.localizedDescription.contains("private")) }
        XCTAssertEqual(Set(store.items.map(\.id)), [original.id, existingClip.id])
        XCTAssertEqual(store.pinboards.map(\.id), [board.id])
        XCTAssertEqual(try store.sharedGraphItemIDs(board.id), [existingClip.id])
        XCTAssertFalse(store.context.hasChanges)
        let reopened = try LibraryStore(directory: directory)
        XCTAssertEqual(Set(reopened.items.map(\.id)), [original.id, existingClip.id])
        XCTAssertEqual(reopened.pinboards.map(\.id), [board.id])
        let repeated = try await store.importPasteBarBackup(from: initial.url)
        XCTAssertEqual(repeated.duplicates, 1)
        XCTAssertEqual(repeated.importedSavedClips, 0)
    }

    @MainActor func testNewMigrationContentRejectsOwnedSharesAndShareLookupFailures() async throws {
        let initial = try PasteBarFixture(sql: Self.sharedDestinationSQL(addingContent: false))
        let extended = try PasteBarFixture(sql: Self.sharedDestinationSQL(addingContent: true))
        defer { initial.remove(); extended.remove() }
        for lookupFails in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = try LibraryStore(directory: directory)
            try await store.importPasteBarBackup(from: initial.url)
            let board = try XCTUnwrap(store.pinboards.first)
            let existingClip = try XCTUnwrap(store.items.first)
            var inspected: [NSManagedObjectID] = []
            store.pasteBarBoardShareCheck = { objectID in
                inspected.append(objectID)
                if lookupFails { throw CocoaError(.fileReadNoPermission) }
                return true
            }
            do { try await store.importPasteBarBackup(from: extended.url); XCTFail("Private migration must reject an owned share or unknown share status") }
            catch { XCTAssertTrue(error.localizedDescription.contains("private")) }
            XCTAssertEqual(inspected, [try XCTUnwrap(store.boardObject(board.id)).objectID])
            XCTAssertEqual(store.items.map(\.id), [existingClip.id])
            XCTAssertEqual(store.pinboards.map(\.id), [board.id])
            XCTAssertFalse(store.context.hasChanges)
            let reopened = try LibraryStore(directory: directory)
            XCTAssertEqual(reopened.items.map(\.id), [existingClip.id])
            XCTAssertEqual(reopened.pinboards.map(\.id), [board.id])
            let repeated = try await store.importPasteBarBackup(from: initial.url)
            XCTAssertEqual(repeated.duplicates, 1)
            XCTAssertEqual(repeated.importedSavedClips, 0)
            XCTAssertEqual(inspected.count, 1)
        }
    }

    @MainActor func testNewMigrationContentCanExtendExistingPrivatePinboard() async throws {
        let initial = try PasteBarFixture(sql: Self.sharedDestinationSQL(addingContent: false))
        let extended = try PasteBarFixture(sql: Self.sharedDestinationSQL(addingContent: true))
        defer { initial.remove(); extended.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LibraryStore(directory: directory)
        try await store.importPasteBarBackup(from: initial.url)
        let original = try XCTUnwrap(store.pinboards.first)
        let result = try await store.importPasteBarBackup(from: extended.url)
        XCTAssertEqual(result.importedSavedClips, 2)
        XCTAssertEqual(result.importedHistory, 1)
        XCTAssertEqual(result.importedPinboards, 1)
        XCTAssertEqual(result.duplicates, 1)
        XCTAssertEqual(try store.sharedGraphItemIDs(original.id).count, 2)
    }

    @MainActor func testSavedTreeOrderFlattensDepthFirstAndPreservesLocalReorder() async throws {
        let backup = try PasteBarFixture(sql: Self.savedSchema + """
        INSERT INTO collections VALUES ('c','Work');
        INSERT INTO tabs VALUES ('t','c','Tab',0,NULL,0);
        INSERT INTO items(item_id,name,is_folder) VALUES ('folder-a','A',1),('folder-b','B',1);
        INSERT INTO items(item_id,name,value,is_text,created_at) VALUES ('a1','A1','A1',1,1700000000000),('a2','A2','A2',1,1600000000000),('b1','B1','B1',1,1800000000000),('b2','B2','B2',1,1900000000000);
        INSERT INTO collection_clips VALUES ('c','t','folder-a',NULL,0),('c','t','folder-b',NULL,1),('c','t','a1','folder-a',0),('c','t','a2','folder-a',1),('c','t','b1','folder-b',0),('c','t','b2','folder-b',1);
        """)
        defer { backup.remove() }
        let store = try LibraryStore(inMemory: true)
        try await store.importPasteBarBackup(from: backup.url)
        let board = try XCTUnwrap(store.pinboards.first)
        let ordered = store.results(boardID: board.id)
        XCTAssertEqual(ordered.map(\.text), ["A1", "A2", "B1", "B2"])
        XCTAssertEqual(ordered.map(\.order), [0, 1, 2, 3])
        var moved = try XCTUnwrap(ordered.first); moved.order = 99
        try store.update(moved)
        try await store.importPasteBarBackup(from: backup.url)
        XCTAssertEqual(store.items.first { $0.id == moved.id }?.order, 99)
    }

    @MainActor func testSavedNamedPaletteColorsAndUnknownFallback() async throws {
        let backup = try PasteBarFixture(sql: Self.savedSchema + """
        INSERT INTO collections VALUES ('c','Work');
        INSERT INTO tabs VALUES ('sky','c','Sky',0,'sky',0),('unknown','c','Unknown',1,'not-a-palette-color',0),('hex','c','Hex',2,'#123ABC',0);
        INSERT INTO items(item_id,name,value,is_text) VALUES ('item','Clip','text',1);
        INSERT INTO collection_clips VALUES ('c','sky','item',NULL,0),('c','unknown','item',NULL,0),('c','hex','item',NULL,0);
        """)
        defer { backup.remove() }
        let store = try LibraryStore(inMemory: true)
        try await store.importPasteBarBackup(from: backup.url)
        XCTAssertEqual(store.pinboards.first { $0.name == "Work / Sky" }?.colorHex, "0EA5E9")
        XCTAssertEqual(store.pinboards.first { $0.name == "Work / Unknown" }?.colorHex, "30B7A8")
        XCTAssertEqual(store.pinboards.first { $0.name == "Work / Hex" }?.colorHex, "123ABC")
    }

    static func sharedDestinationSQL(addingContent: Bool) -> String {
        savedSchema + """
        INSERT INTO collections VALUES ('c','Existing');
        INSERT INTO tabs VALUES ('t','c','Tab',0,NULL,0);
        INSERT INTO items(item_id,name,value,is_text) VALUES ('old','Old','already imported',1);
        INSERT INTO collection_clips VALUES ('c','t','old',NULL,0);
        """ + (addingContent ? """
        INSERT INTO clipboard_history(history_id,value,is_text) VALUES ('new-history','private new history',1);
        INSERT INTO collections VALUES ('a','New');
        INSERT INTO tabs VALUES ('new-tab','a','New tab',0,NULL,0);
        INSERT INTO items(item_id,name,value,is_text) VALUES ('new','New clip','private new clip',1),('other','Other','private other board',1);
        INSERT INTO collection_clips VALUES ('c','t','new',NULL,1),('a','new-tab','other',NULL,0);
        """ : "")
    }

    static let savedSchema = """
    CREATE TABLE collections(collection_id TEXT PRIMARY KEY,title TEXT);
    CREATE TABLE tabs(tab_id TEXT PRIMARY KEY,collection_id TEXT,tab_name TEXT,tab_order_number INTEGER,tab_color TEXT,tab_is_protected INTEGER);
    CREATE TABLE items(item_id TEXT PRIMARY KEY,name TEXT,value TEXT,is_text INTEGER,is_code INTEGER,is_link INTEGER,is_image INTEGER,is_file INTEGER,is_path INTEGER,is_protected INTEGER,is_masked INTEGER,has_masked_words INTEGER,is_command INTEGER,is_form INTEGER,is_template INTEGER,is_web_request INTEGER,is_web_scraping INTEGER,is_deleted INTEGER,is_folder INTEGER,is_board INTEGER,is_separator INTEGER,is_menu INTEGER,created_at INTEGER,image_path_full_res TEXT,image_data_url TEXT);
    CREATE TABLE collection_clips(collection_id TEXT,tab_id TEXT,item_id TEXT,parent_id TEXT,order_number INTEGER);
    CREATE TABLE collection_menu(collection_id TEXT,item_id TEXT,parent_id TEXT,order_number INTEGER);
    """

    @MainActor func testMediaProtectedRecordsAndExternalReferences() async throws {
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aL1sAAAAASUVORK5CYII=")!
        let backup = try PasteBarFixture(sql: "INSERT INTO clipboard_history(history_id,is_image,image_path_full_res) VALUES ('image',1,'{{base_folder}}/clipboard-images/a.png'),('missing',1,'{{base_folder}}/clipboard-images/missing.png'); INSERT INTO clipboard_history(history_id,value,is_masked) VALUES ('secret','sensitive fixture',1),('masked-markup','[mask]hidden fixture[/mask]',0); INSERT INTO clipboard_history(history_id,value) VALUES ('file','/a/nonexistent/pastebar-fixture.txt'),('empty','');", images: ["clipboard-images/a.png": png])
        defer { backup.remove() }
        let store = try LibraryStore(inMemory: true)
        let result = try await store.importPasteBarBackup(from: backup.url)
        XCTAssertEqual(result.importedHistory, 2)
        XCTAssertEqual(result.protectedRecords, 2)
        XCTAssertEqual(result.missingImages, 1)
        XCTAssertEqual(result.unsupportedRecords, 1)
        XCTAssertEqual(result.unresolvedFiles, 1)
        let image = try XCTUnwrap(store.items.first { $0.kind == .image })
        XCTAssertEqual(try store.materialized(image).data, png)
        XCTAssertEqual(image.imageWidth, 1)
        XCTAssertNotNil(image.thumbnail)
        XCTAssertEqual(store.items.first { $0.kind == .file }?.fileURLs, ["file:///a/nonexistent/pastebar-fixture.txt"])
        XCTAssertFalse(store.items.contains { $0.text == "sensitive fixture" })
    }

    @MainActor func testFailedSaveRollsBackEntireHistoryAndCanRetry() async throws {
        let backup = try PasteBarFixture(sql: "INSERT INTO clipboard_history(history_id,value,is_text) VALUES ('new-1','one',1),('new-2','two',1);")
        defer { backup.remove() }
        let store = try LibraryStore(inMemory: true)
        let original = ClipItem(kind: .text, text: "existing")
        try store.add(original)
        store.persistenceSaveCheck = { throw CocoaError(.fileWriteNoPermission) }
        do { try await store.importPasteBarBackup(from: backup.url); XCTFail("Expected import failure") } catch {}
        XCTAssertEqual(store.items.map(\.id), [original.id])
        XCTAssertFalse(store.context.hasChanges)
        store.persistenceSaveCheck = nil
        let retry = try await store.importPasteBarBackup(from: backup.url)
        XCTAssertEqual(retry.importedHistory, 2)
    }

    @MainActor func testInvalidArchiveAndUnsafeEntryFailWithoutChangingLibrary() async throws {
        let backup = try PasteBarFixture(sql: "")
        defer { backup.remove() }
        let store = try LibraryStore(inMemory: true)
        let original = ClipItem(kind: .text, text: "existing")
        try store.add(original)
        var data = try Data(contentsOf: backup.url)
        let name = Data("pastebar-db.data".utf8)
        while let range = data.range(of: name) { data.replaceSubrange(range, with: Data("../pastebar.data".utf8)) }
        try data.write(to: backup.url)
        do { try await store.importPasteBarBackup(from: backup.url); XCTFail("Expected import failure") } catch {}
        try Data("not a ZIP".utf8).write(to: backup.url)
        do { try await store.importPasteBarBackup(from: backup.url); XCTFail("Expected import failure") } catch {}
        XCTAssertEqual(store.items.map(\.id), [original.id])
    }

    @MainActor func testEmbeddedNULAndWindowsReferencesSurvive() async throws {
        let backup = try PasteBarFixture(sql: "INSERT INTO clipboard_history(history_id,value,is_text) VALUES ('nul',CAST(X'68656c6c6f00776f726c64' AS TEXT),1),('windows','C:\\Users\\example\\note.txt',1),('unc','\\\\server\\share\\note.txt',1);")
        defer { backup.remove() }
        let store = try LibraryStore(inMemory: true)
        let result = try await store.importPasteBarBackup(from: backup.url)
        XCTAssertEqual(result.unresolvedFiles, 2)
        XCTAssertTrue(store.items.contains { $0.text == "hello\0world" })
        XCTAssertEqual(store.items.filter { $0.kind == .file }.count, 2)
        XCTAssertTrue(store.items.flatMap(\.fileURLs).contains("file:///C:/Users/example/note.txt"))
    }

    @MainActor func testSourceViewsAreRejectedBeforeExecutingTheirQueries() async throws {
        let backup = try PasteBarFixture(sql: "DROP TABLE clipboard_history; CREATE VIEW clipboard_history AS WITH RECURSIVE x(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM x) SELECT sum(n) AS history_id, '' AS value, 1 AS is_text, 0 AS is_code, 0 AS is_link, 0 AS is_image FROM x;")
        defer { backup.remove() }
        let store = try LibraryStore(inMemory: true)
        do { try await store.importPasteBarBackup(from: backup.url); XCTFail("Expected unsupported schema") } catch {}
        XCTAssertTrue(store.items.isEmpty)
    }

    @MainActor func testRepeatedLargeImageReferencesRespectTotalPayloadBudget() async throws {
        var png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aL1sAAAAASUVORK5CYII=")!
        png.append(Data(count: 16 * 1024 * 1024))
        let rows = (0..<32).map { "('image-\($0)',1,'{{base_folder}}/clipboard-images/a.png')" }.joined(separator: ",")
        let backup = try PasteBarFixture(sql: "INSERT INTO clipboard_history(history_id,is_image,image_path_full_res) VALUES " + rows + ";", images: ["clipboard-images/a.png": png])
        defer { backup.remove() }
        let store = try LibraryStore(inMemory: true)
        do { try await store.importPasteBarBackup(from: backup.url); XCTFail("Expected payload limit") } catch {}
        XCTAssertTrue(store.items.isEmpty)
    }

    @MainActor func testUnpaddedImageDataURL() async throws {
        let encoded = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aL1sAAAAASUVORK5CYII"
        let backup = try PasteBarFixture(sql: "INSERT INTO clipboard_history(history_id,is_image,image_data_url) VALUES ('inline',1,'data:image/png;base64," + encoded + "');")
        defer { backup.remove() }
        let store = try LibraryStore(inMemory: true)
        let result = try await store.importPasteBarBackup(from: backup.url)
        XCTAssertEqual(result.importedHistory, 1)
        let image = try XCTUnwrap(store.items.first)
        XCTAssertEqual(image.kind, .image)
        XCTAssertEqual(try store.materialized(image).data, Data(base64Encoded: encoded + "="))
    }

    @MainActor func testExistingOriginalAndBackupStayUnchanged() async throws {
        let original = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        let originalData = Data("external original".utf8)
        try originalData.write(to: original)
        defer { try? FileManager.default.removeItem(at: original) }
        let backup = try PasteBarFixture(sql: "INSERT INTO clipboard_history(history_id,value,is_text) VALUES ('original','" + original.absoluteString + "',1);")
        defer { backup.remove() }
        let backupData = try Data(contentsOf: backup.url)
        let store = try LibraryStore(inMemory: true)
        let result = try await store.importPasteBarBackup(from: backup.url)
        XCTAssertEqual(result.unresolvedFiles, 0)
        XCTAssertEqual(store.items.first?.fileURLs, [original.absoluteString])
        XCTAssertEqual(try Data(contentsOf: original), originalData)
        XCTAssertEqual(try Data(contentsOf: backup.url), backupData)
        XCTAssertNil(try store.materialized(XCTUnwrap(store.items.first)).data)
    }

    @MainActor func testMigrationAccepts360MiBOfSourceData() async throws {
        let backup = try PasteBarFixture(sql: "ALTER TABLE clipboard_history ADD COLUMN unused BLOB GENERATED ALWAYS AS (zeroblob(2097152)) VIRTUAL; WITH RECURSIVE rows(n) AS (VALUES(1) UNION ALL SELECT n + 1 FROM rows WHERE n < 180) INSERT INTO clipboard_history(history_id,value,is_text) SELECT printf('large-source-%d',n),'imported text',1 FROM rows;")
        defer { backup.remove() }
        let store = try LibraryStore(inMemory: true)
        let original = ClipItem(kind: .text, text: "existing")
        try store.add(original)

        let result = try await store.importPasteBarBackup(from: backup.url)

        XCTAssertEqual(result.importedHistory, 180)
        XCTAssertEqual(store.items.filter { $0.text == "imported text" }.count, 180)
        XCTAssertEqual(store.items.first { $0.id == original.id }?.text, "existing")
    }

    @MainActor func testStored360MiBBackupImportsLargeDatabase() async throws {
        let backup = try PasteBarFixture(sql: "ALTER TABLE clipboard_history ADD COLUMN unused BLOB; WITH RECURSIVE rows(n) AS (VALUES(1) UNION ALL SELECT n + 1 FROM rows WHERE n < 6) INSERT INTO clipboard_history(history_id,value,is_text,unused) SELECT printf('large-database-%d',n),'large backup text',1,zeroblob(62914560) FROM rows;", stored: true)
        defer { backup.remove() }
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: backup.url.path)[.size] as? NSNumber).int64Value
        XCTAssertGreaterThan(size, 360 * 1024 * 1024)
        XCTAssertLessThan(size, 361 * 1024 * 1024)
        let store = try LibraryStore(inMemory: true)

        let result = try await store.importPasteBarBackup(from: backup.url)

        XCTAssertEqual(result.importedHistory, 6)
        XCTAssertEqual(store.items.map(\.text), Array(repeating: "large backup text", count: 6))
    }

    @MainActor func testGeneratedMetadataRespectsAggregateReadBudgetBeforePersistence() async throws {
        let backup = try PasteBarFixture(sql: "ALTER TABLE clipboard_history DROP COLUMN title; ALTER TABLE clipboard_history ADD COLUMN title TEXT GENERATED ALWAYS AS (hex(zeroblob(1048576))) VIRTUAL; WITH RECURSIVE rows(n) AS (VALUES(1) UNION ALL SELECT n + 1 FROM rows WHERE n < 251) INSERT INTO clipboard_history(history_id,value,is_text) SELECT printf('generated-%d',n),'small value',1 FROM rows;")
        defer { backup.remove() }
        XCTAssertLessThan(try Data(contentsOf: backup.url).count, 64 * 1024)
        let store = try LibraryStore(inMemory: true)
        let original = ClipItem(kind: .text, text: "existing")
        try store.add(original)
        store.persistenceSaveCheck = { throw CocoaError(.fileWriteNoPermission) }
        do { try await store.importPasteBarBackup(from: backup.url); XCTFail("Expected aggregate read limit") }
        catch let error as PasteBarImportError {
            guard case .archiveLimit = error else { return XCTFail("Expected aggregate read limit") }
        } catch { XCTFail("The source must be rejected before persistence: \(error)") }
        XCTAssertEqual(store.items.map(\.id), [original.id])
        XCTAssertFalse(store.context.hasChanges)
    }

    @MainActor func testUnusedGeneratedBlobRespectsAggregateReadBudget() async throws {
        let backup = try PasteBarFixture(sql: "ALTER TABLE clipboard_history ADD COLUMN unused BLOB GENERATED ALWAYS AS (zeroblob(2097152)) VIRTUAL; WITH RECURSIVE rows(n) AS (VALUES(1) UNION ALL SELECT n + 1 FROM rows WHERE n < 251) INSERT INTO clipboard_history(history_id,value,is_text) SELECT printf('generated-%d',n),'small value',1 FROM rows;")
        defer { backup.remove() }
        XCTAssertLessThan(try Data(contentsOf: backup.url).count, 64 * 1024)
        let store = try LibraryStore(inMemory: true)
        do { try await store.importPasteBarBackup(from: backup.url); XCTFail("Expected aggregate read limit") }
        catch let error as PasteBarImportError {
            guard case .archiveLimit = error else { return XCTFail("Expected aggregate read limit") }
        }
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertFalse(store.context.hasChanges)
    }

}

struct PasteBarFixture {
    let root: URL
    var url: URL { root.appendingPathComponent("backup.zip") }
    init(sql: String, images: [String: Data] = [:], stored: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open(root.appendingPathComponent("pastebar-db.data").path, &db) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_close(db) }
        let schema = "CREATE TABLE clipboard_history(history_id TEXT PRIMARY KEY, title TEXT, value TEXT, is_text INTEGER, is_code INTEGER, is_link INTEGER, is_image INTEGER, image_path_full_res TEXT, image_data_url TEXT, image_data_low_res BLOB, is_masked INTEGER, has_masked_words INTEGER, history_options TEXT, copied_from_app TEXT, created_at INTEGER, updated_at INTEGER);"
        guard sqlite3_exec(db, schema + sql, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        for (path, data) in images {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = root
        process.arguments = ["-q", "-r"] + (stored ? ["-0"] : []) + [url.path, "pastebar-db.data"] + Array(Set(images.keys.map { $0.components(separatedBy: "/")[0] })).sorted()
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
