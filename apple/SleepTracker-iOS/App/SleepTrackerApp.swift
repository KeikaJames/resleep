import SwiftUI
import SleepKit
import UIKit

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
    @State private var selectedTab: Int = 0

    init() {
        let appearance = UITabBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.backgroundEffect = nil
        appearance.backgroundColor = .clear
        appearance.shadowColor = .clear
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView()
                .tabItem { Label("tab.home", systemImage: "moon.stars") }
                .tag(0)
            TrendsView()
                .tabItem { Label("tab.trends", systemImage: "chart.bar.xaxis") }
                .tag(1)
            SleepAIView()
                .tabItem { Label("tab.ai", systemImage: "sparkles") }
                .tag(2)
            HistoryView()
                .tabItem { Label("tab.history", systemImage: "list.bullet.rectangle") }
                .tag(3)
            SettingsView()
                .tabItem { Label("tab.settings", systemImage: "gear") }
                .tag(4)
        }
        .toolbarBackground(.hidden, for: .tabBar)
        .sensoryFeedback(.selection, trigger: selectedTab)
    }
}
