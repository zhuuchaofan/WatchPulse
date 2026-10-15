import SwiftUI

@main
struct WatchPulseWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            WatchHomeView(environment: WatchAppEnvironment.shared)
        }
    }
}
