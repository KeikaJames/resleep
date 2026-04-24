import SwiftUI
import SleepKit

@main
struct SleepTrackerWatchApp: App {
    @StateObject private var state = WatchAppState.makeDefault()

    var body: some Scene {
        WindowGroup {
            WatchHomeView()
                .environmentObject(state)
        }
    }
}
