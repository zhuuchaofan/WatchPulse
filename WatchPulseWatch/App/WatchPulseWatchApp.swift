import SwiftUI

@main
struct WatchPulseWatchApp: App {
    @State private var workoutManager = WatchWorkoutManager()

    var body: some Scene {
        WindowGroup {
            WatchHomeView(workoutManager: workoutManager)
        }
    }
}
