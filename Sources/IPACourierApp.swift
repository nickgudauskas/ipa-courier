import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: CourierModel?
    var android: AndroidModel?

    /// IPAs and APKs opened from Finder ("Open With → IPA Courier").
    func application(_ application: NSApplication, open urls: [URL]) {
        let ipas = urls.filter { $0.pathExtension.lowercased() == "ipa" }
        let apks = urls.filter { APKKind(url: $0) != nil }
        Task { @MainActor in
            if !ipas.isEmpty { self.model?.add(ipas) }
            if !apks.isEmpty { self.android?.add(apks) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model?.cleanupAll() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct IPACourierApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = CourierModel()
    @StateObject private var discover = DiscoverModel()
    @StateObject private var android = AndroidModel()

    var body: some Scene {
        Window("IPA Courier", id: "main") {
            ContentView()
                .environmentObject(model)
                .environmentObject(discover)
                .environmentObject(android)
                .onAppear {
                    delegate.model = model
                    delegate.android = android
                    discover.courier = model
                    discover.android = android
                    android.courier = model
                }
        }
        .windowResizability(.contentMinSize)
    }
}
