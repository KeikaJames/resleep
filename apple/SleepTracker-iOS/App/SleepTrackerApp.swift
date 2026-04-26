import SwiftUI
import SleepKit

@main
struct SleepTrackerApp: App {
    @StateObject private var appState = AppState.makeDefault()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(appState)
                .task { await appState.restoreLatestSession() }
        }
    }
}

struct RootTabView: View {
    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Home", systemImage: "moon.stars") }
            HistoryView()
                .tabItem { Label("History", systemImage: "list.bullet.rectangle") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gear") }
        }
    }
}
