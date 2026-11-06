import SwiftUI
import UIKit
import Observation
import StashCore
import CloudKit

/// UIKit owns invitation delivery; every screen shares one long-lived SwiftUI model.
@main @MainActor final class IOSDelegate:UIResponder,UIApplicationDelegate {
    func application(_ application:UIApplication,configurationForConnecting session:UISceneSession,options:UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name:"Stash",sessionRole:session.role); configuration.delegateClass = IOSSceneDelegate.self; return configuration
    }
    func application(_ application:UIApplication,userDidAcceptCloudKitShareWith metadata:CKShare.Metadata) { Task { await IOSLibrarySession.shared.accept(metadata) } }
}
@MainActor final class IOSSceneDelegate:UIResponder,UIWindowSceneDelegate {
    var window:UIWindow?
    func scene(_ scene:UIScene,willConnectTo session:UISceneSession,options:UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else {return}
        let window = UIWindow(windowScene:scene); window.rootViewController = UIHostingController(rootView:RootView()); window.makeKeyAndVisible(); self.window = window
        if let metadata = options.cloudKitShareMetadata { Task { await IOSLibrarySession.shared.accept(metadata) } }
    }
    func windowScene(_ windowScene:UIWindowScene,userDidAcceptCloudKitShareWith metadata:CKShare.Metadata) { Task { await IOSLibrarySession.shared.accept(metadata) } }
}
@MainActor @Observable final class IOSLibrarySession {
    static let shared = IOSLibrarySession()
    var store:LibraryStore?
    var error:String?
    func open() {
        guard store == nil else {return}
        do {store = try LibraryStore(syncEnabled:LibraryStore.syncRequested);try store?.applyRetention()} catch {self.error = error.localizedDescription}
    }
    func accept(_ metadata:CKShare.Metadata) async {
        do {
            open(); guard let existing = store else {return}
            if !existing.settings.syncEnabled {var settings = existing.settings;settings.syncEnabled = true;try existing.updateSettings(settings);store = try LibraryStore(syncEnabled:true)}
            try await store?.acceptShare(metadata)
        } catch {self.error = error.localizedDescription}
    }
}
struct RootView:View {
    @State private var session = IOSLibrarySession.shared
    var body:some View { Group { if let store = session.store { LibraryView(store:store) } else if let error = session.error { ContentUnavailableView("Library unavailable",systemImage:"externaldrive.badge.exclamationmark",description:Text(error)) } else { ProgressView("Opening Stash…") } }.task {session.open()} }
}
