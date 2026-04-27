import SwiftUI
import SleepKit

@main
struct SleepTrackerApp: App {
    @StateObject private var appState = AppState.makeDefault()
    @Environment(\.scenePhase) private var scenePhase
    @State private var hasOnboarded: Bool = OnboardingGate.hasCompleted

    var body: some Scene {
        WindowGroup {
            Group {
                if hasOnboarded {
                    RootTabView()
                } else {
                    OnboardingFlow {
                        hasOnboarded = true
                    }
                }
            }
            .environmentObject(appState)
            .preferredColorScheme(appState.workout.isTracking ? .dark : nil)
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
                .tabItem { Label("tab.home", systemImage: "moon.stars") }
            TrendsView()
                .tabItem { Label("tab.trends", systemImage: "chart.bar.xaxis") }
            SleepAIView()
                .tabItem { Label("tab.ai", systemImage: "sparkles") }
            HistoryView()
                .tabItem { Label("tab.history", systemImage: "list.bullet.rectangle") }
            SettingsView()
                .tabItem { Label("tab.settings", systemImage: "gear") }
        }
    }
}
