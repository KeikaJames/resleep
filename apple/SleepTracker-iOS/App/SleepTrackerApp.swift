import SwiftUI
import SleepKit

@main
struct SleepTrackerApp: App {
    @StateObject private var appState = AppState.makeDefault()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(appState)
                .task {
                    await appState.appLaunch()
                    await appState.restoreLatestSession()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .active:     appState.appForeground()
                    case .background: appState.appBackground()
                    default: break
                    }
                }
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
