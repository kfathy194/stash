import AppKit
import SwiftUI

/// Real production controls with generated content and no application startup services.
@main @MainActor struct EditorSmoke {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
        guard root.deletingLastPathComponent() == URL(fileURLWithPath: "/private/tmp", isDirectory: true).resolvingSymlinksInPath(),
              root.lastPathComponent.hasPrefix("stash-editor-smoke."),
              try String(contentsOf: root.appendingPathComponent("fixture-marker"), encoding: .utf8) == "generated-editor-fixture\n",
              LibraryStore.defaultDirectory().resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else {
            fatalError("The editor fixture requires its generated root and isolated home.")
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let launcher = EditorFixtureLauncher(root: root)
        app.delegate = launcher
        withExtendedLifetime(launcher) { app.run() }
    }
}

@MainActor final class EditorFixtureLauncher: NSObject, NSApplicationDelegate {
    let root: URL
    var fixture: EditorFixture?
    var keys: Any?
    init(root: URL) { self.root = root }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let menu = NSMenu()
            let applicationMenu = NSMenuItem()
            applicationMenu.submenu = NSMenu(title: "Stash Editor Smoke")
            menu.addItem(applicationMenu)
            let editMenu = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
            editMenu.submenu = NSMenu(title: "Edit")
            editMenu.submenu?.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
            menu.addItem(editMenu)
            NSApp.mainMenu = menu
            let fixture = try EditorFixture(root: root)
            self.fixture = fixture
            keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let handled = MainActor.assumeIsolated {
                    fixture.window.isKeyWindow && NSApp.modalWindow == nil &&
                        PanelController.handleNewTextShortcut(event, model: fixture.model)
                }
                return handled ? nil : event
            }
            fixture.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } catch {
            fatalError("Could not open generated editor fixture: \(error.localizedDescription)")
        }
    }
    func applicationWillTerminate(_ notification: Notification) { if let keys { NSEvent.removeMonitor(keys) } }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@MainActor final class EditorFixture: NSObject {
    let root: URL
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 520), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    var model: AppModel

    init(root: URL) throws {
        self.root = root
        let store = try LibraryStore(directory: root.appendingPathComponent("Library"), syncEnabled: false)
        let board = try store.createBoard(name: "Generated Work")
        _ = try store.createBoard(name: "Generated Empty")
        var note = ClipItem(kind: .richText, text: "Generated formatted note")
        let rich = NSAttributedString(string: note.text, attributes: [.font: NSFont.boldSystemFont(ofSize: 18)])
        note.richData = try rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        try store.add(note)
        try store.pin([note.id], to: board.id)
        model = AppModel(store: store)
        model.currentBoard = board.id
        super.init()
        precondition(model.capture == nil && model.paste == nil && model.hotkeys == nil && model.mcp == nil)
        window.title = "Stash Editor Smoke — generated data only"
        window.isReleasedWhenClosed = false
        showLibrary()
        window.center()
    }

    private func showLibrary() {
        window.contentView = NSHostingView(rootView: VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Disposable generated library").font(.headline)
                Button("Reopen generated library") { self.reopen() }
                Button("Delete current destination") {
                    if let id = self.model.currentBoard { self.model.perform { try self.model.store.deleteBoard(id) } }
                }
            }.padding(.horizontal)
            PanelView(model: model)
        }.padding(.top, 12))
    }

    private func reopen() {
        guard !EditorWindow.editors.contains(where: { $0.window.isVisible }) else {
            let alert = NSAlert()
            alert.messageText = "Close the generated editors before reopening the library."
            alert.runModal()
            return
        }
        do {
            let selected = model.currentBoard
            let store = try LibraryStore(directory: root.appendingPathComponent("Library"), syncEnabled: false)
            model = AppModel(store: store)
            model.currentBoard = selected
            showLibrary()
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }
}
