import XCTest
import CoreData
@testable import StashCore

final class ReviewRegressionTests:XCTestCase {
    @MainActor func testExplicitAssetReplacementClearsOldRichRepresentation() throws {
        let store = try LibraryStore(inMemory:true)
        var item = ClipItem(kind:.richText,text:"old secret"); item.richData = Data("old rich secret".utf8); try store.add(item)
        var edited = try store.materialized(store.items[0]); edited.text = "new text"; edited.kind = .text; edited.richData = nil
        try store.update(edited,replacingAssets:true)
        let restored = try store.materialized(store.items[0]); XCTAssertNil(restored.richData); XCTAssertEqual(restored.text,"new text")
    }
    @MainActor func testReloadReflectsUpdatesFromAnotherStoreInstance() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer {try? FileManager.default.removeItem(at:folder)}
        let first = try LibraryStore(directory:folder); let item = ClipItem(kind:.text,text:"before"); try first.add(item)
        let second = try LibraryStore(directory:folder); var changed = second.items[0]; changed.text = "after"; try second.update(changed)
        try first.reload(); XCTAssertEqual(first.items.first?.text,"after")
    }
    @MainActor func testRemoteBoardDeletionCannotLeaveUnexportableOrphan() throws {
        let store = try LibraryStore(inMemory:true); let board = try store.createBoard(name:"Removed remotely"); let item = ClipItem(kind:.text,text:"keep original")
        try store.add(item); try store.pin([item.id],to:board.id)
        let request = NSFetchRequest<NSManagedObject>(entityName:"BoardRecord"); request.predicate = NSPredicate(format:"id == %@",board.id.uuidString)
        for object in try store.context.fetch(request) {store.context.delete(object)}
        try store.context.save(); try store.reload()
        XCTAssertNil(store.items.first?.pinboardID); XCTAssertTrue(store.items.first?.isInHistory == true)
        XCTAssertNoThrow(try LibraryArchive.decode(store.archive()))
    }
    func testBookmarkFailuresPreserveURLPositions() {
        let urls = [URL(fileURLWithPath:"/first"),URL(fileURLWithPath:"/second")]
        let bookmarks = FileBookmarks.capture(urls:urls) { url in url == urls[0] ? nil : Data([2]) }
        XCTAssertEqual(bookmarks.count,2); XCTAssertNil(FileBookmarks.bookmark(at:0,in:bookmarks)); XCTAssertEqual(FileBookmarks.bookmark(at:1,in:bookmarks),Data([2]))
    }
    func testFocusedWindowMatchingRejectsBackgroundAndAmbiguity() {
        let focused = CGRect(x:10,y:20,width:400,height:200)
        let candidates = [WindowDescriptor(id:1,pid:12,frame:focused,title:"Draft"),WindowDescriptor(id:2,pid:12,frame:CGRect(x:0,y:0,width:1200,height:900),title:"Private background")]
        XCTAssertEqual(FocusedWindowMatch.select(candidates, pid:12,frame:focused,title:"Draft"),1)
        XCTAssertNil(FocusedWindowMatch.select(candidates + [WindowDescriptor(id:3,pid:12,frame:focused,title:"Draft")],pid:12,frame:focused,title:"Draft"))
    }
    func testExactHexRejectsTrailingNewline() { XCTAssertEqual(ContentClassifier.kind(for:"ABCDEF\n"),.text); XCTAssertEqual(ContentClassifier.kind(for:"#AABBCC\n"),.text) }
    func testImportedFileSurvivesProviderURLDisappearing() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
        let temporary=root.appendingPathComponent("provider.txt");try Data("durable file".utf8).write(to:temporary)
        let item=try FileAssets.importFile(from:temporary,name:"notes.txt",type:"public.plain-text",directory:root.appendingPathComponent("library"))
        try FileManager.default.removeItem(at:temporary)
        let url=try FileAssets.resolve(item,directory:root.appendingPathComponent("library"))
        XCTAssertEqual(try String(contentsOf:url,encoding:.utf8),"durable file")
        XCTAssertEqual(item.fileName,"notes.txt")
    }

    @MainActor func testCloudPreferencesCannotEnableDevicePermissions() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:root)}
        let first=try LibraryStore(directory:root.appendingPathComponent("first"));var settings=first.settings;settings.mcpEnabled=true;settings.suggestionsEnabled=true;try first.updateSettings(settings)
        let request=NSFetchRequest<NSManagedObject>(entityName:"PreferenceRecord");let payload=try XCTUnwrap(first.context.fetch(request).first?.value(forKey:"payload") as? Data)
        let second=try LibraryStore(directory:root.appendingPathComponent("second"));let object=NSEntityDescription.insertNewObject(forEntityName:"PreferenceRecord",into:second.context);object.setValue("settings",forKey:"id");object.setValue(payload,forKey:"payload");try second.context.save();try second.reload()
        XCTAssertFalse(second.settings.mcpEnabled);XCTAssertFalse(second.settings.suggestionsEnabled)
        let reopened=try LibraryStore(directory:root.appendingPathComponent("first"));XCTAssertTrue(reopened.settings.mcpEnabled)
    }

}
