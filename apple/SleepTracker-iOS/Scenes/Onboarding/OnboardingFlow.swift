import SwiftUI
import SleepKit

/// 3-screen onboarding shown the first time the app launches.
///
/// Pages:
///   1. Welcome — value proposition (Apple-style hero with quiet typography)
///   2. Privacy — explicit on-device promise (no audio recording, no cloud)
///   3. Permissions — HealthKit ask + finish
struct OnboardingFlow: View {
    let onFinish: () -> Void

    @EnvironmentObject private var appState: AppState
    @State private var page: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                WelcomePage().tag(0)
                PrivacyPage().tag(1)
                PermissionsPage(onFinish: finish).tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            HStack(spacing: 12) {
                if page > 0 {
                    Button("onboarding.back") { withAnimation { page -= 1 } }
                        .buttonStyle(.bordered)
                }
                Spacer()
                if page < 2 {
                    Button("onboarding.next") { withAnimation { page += 1 } }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
        .background(Color(.systemBackground))
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: OnboardingGate.completedKey)
        onFinish()
    }
}

enum OnboardingGate {
    static let completedKey = "onboarding.completed.v1"
    static var hasCompleted: Bool {
        UserDefaults.standard.bool(forKey: completedKey)
    }
}

private struct WelcomePage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            Image(systemName: "moon.stars")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.tint)
            Text("onboarding.welcome.title")
                .font(.largeTitle.weight(.bold))
                .multilineTextAlignment(.leading)
            Text("onboarding.welcome.body")
                .font(.body)
                .foregroundStyle(.secondary)
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PrivacyPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Spacer()
            Image(systemName: "lock.shield")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.tint)
            Text("onboarding.privacy.title")
                .font(.largeTitle.weight(.bold))
            VStack(alignment: .leading, spacing: 14) {
                Bullet(symbol: "iphone", textKey: "onboarding.privacy.b1")
                Bullet(symbol: "mic.slash", textKey: "onboarding.privacy.b2")
                Bullet(symbol: "wifi.slash", textKey: "onboarding.privacy.b3")
                Bullet(symbol: "trash", textKey: "onboarding.privacy.b4")
            }
            Spacer()
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct Bullet: View {
    let symbol: String
    let textKey: LocalizedStringKey
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
            Text(textKey)
                .font(.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct PermissionsPage: View {
    let onFinish: () -> Void
    @EnvironmentObject private var appState: AppState
    @State private var requesting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            Image(systemName: "heart.text.square")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.tint)
            Text("onboarding.perms.title")
                .font(.largeTitle.weight(.bold))
            Text("onboarding.perms.body")
                .font(.body)
                .foregroundStyle(.secondary)
            Spacer()
            VStack(spacing: 10) {
                Button {
                    Task {
                        requesting = true
                        _ = try? await appState.health.requestAuthorization()
                        requesting = false
                        onFinish()
                    }
                } label: {
                    HStack {
                        if requesting { ProgressView().padding(.trailing, 4) }
                        Text("onboarding.perms.allow")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(requesting)

                Button("onboarding.perms.skip", action: onFinish)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
