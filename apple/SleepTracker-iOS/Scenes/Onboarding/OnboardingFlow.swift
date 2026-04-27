import SwiftUI
import SleepKit

/// 4-screen onboarding shown the first time the app launches.
///
/// Pages:
///   1. Consent — accept Terms of Use + Privacy Notice (gates Next)
///   2. Welcome — value proposition (Apple-style hero with quiet typography)
///   3. Privacy — explicit on-device promise (no audio recording, no cloud)
///   4. Permissions — HealthKit ask + finish
struct OnboardingFlow: View {
    let onFinish: () -> Void

    @EnvironmentObject private var appState: AppState
    @State private var page: Int = 0
    @State private var termsAccepted: Bool = false
    @State private var privacyAccepted: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                ConsentPage(termsAccepted: $termsAccepted,
                            privacyAccepted: $privacyAccepted).tag(0)
                WelcomePage().tag(1)
                PrivacyPage().tag(2)
                PermissionsPage(onFinish: finish).tag(3)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            HStack(spacing: 12) {
                if page > 0 {
                    Button("onboarding.back") { withAnimation { page -= 1 } }
                        .buttonStyle(.bordered)
                }
                Spacer()
                if page < 3 {
                    Button("onboarding.next") { withAnimation { page += 1 } }
                        .buttonStyle(.borderedProminent)
                        .disabled(page == 0 && !(termsAccepted && privacyAccepted))
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
        .background(Color(.systemBackground))
    }

    private func finish() {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: OnboardingGate.completedKey)
        defaults.set(true, forKey: OnboardingGate.termsAcceptedKey)
        defaults.set(true, forKey: OnboardingGate.privacyAcceptedKey)
        defaults.set(Date(), forKey: OnboardingGate.acceptedAtKey)
        onFinish()
    }
}

enum OnboardingGate {
    static let completedKey = "onboarding.completed.v1"
    static let termsAcceptedKey = "consent.terms.accepted.v1"
    static let privacyAcceptedKey = "consent.privacy.accepted.v1"
    static let acceptedAtKey = "consent.accepted.at.v1"
    static var hasCompleted: Bool {
        UserDefaults.standard.bool(forKey: completedKey)
    }
}

private struct ConsentPage: View {
    @Binding var termsAccepted: Bool
    @Binding var privacyAccepted: Bool
    @State private var showingTerms = false
    @State private var showingPrivacy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer(minLength: 12)
            Image(systemName: "doc.text")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.tint)
            Text("onboarding.consent.title")
                .font(.largeTitle.weight(.bold))
            Text("onboarding.consent.subtitle")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 14) {
                ConsentRow(accepted: $termsAccepted,
                           labelKey: "onboarding.consent.terms.accept",
                           linkKey: "onboarding.consent.terms.read") {
                    showingTerms = true
                }
                ConsentRow(accepted: $privacyAccepted,
                           labelKey: "onboarding.consent.privacy.accept",
                           linkKey: "onboarding.consent.privacy.read") {
                    showingPrivacy = true
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )

            Spacer()
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $showingTerms) {
            NavigationStack {
                MarkdownDocumentView(titleKey: "settings.about.terms",
                                     text: LegalCopyBridge.terms())
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("common.done") { showingTerms = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showingPrivacy) {
            NavigationStack {
                MarkdownDocumentView(titleKey: "settings.about.privacy",
                                     text: LegalCopyBridge.privacy())
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("common.done") { showingPrivacy = false }
                        }
                    }
            }
        }
    }
}

private struct ConsentRow: View {
    @Binding var accepted: Bool
    let labelKey: LocalizedStringKey
    let linkKey: LocalizedStringKey
    let onTapLink: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { accepted.toggle() }
            } label: {
                Image(systemName: accepted ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(accepted ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                Text(labelKey)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: onTapLink) {
                    Text(linkKey)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Bridge so Onboarding can reuse the same loaders as Settings without
/// exposing the private `LegalCopy` enum.
enum LegalCopyBridge {
    static func terms() -> String {
        loadLocalised(base: "Terms",
                      fallback: "# Terms of Use\n\nNo content available.")
    }
    static func privacy() -> String {
        loadLocalised(base: "PrivacyNotice",
                      fallback: "# Privacy Notice\n\nNo content available.")
    }

    private static func loadLocalised(base: String, fallback: String) -> String {
        let preferred = Bundle.main.preferredLocalizations.first ?? "en"
        let suffix = preferred.hasPrefix("zh") ? "zh-Hans" : "en"
        if let url = Bundle.main.url(forResource: "\(base).\(suffix)",
                                     withExtension: "md"),
           let s = try? String(contentsOf: url, encoding: .utf8) {
            return s
        }
        let other = preferred.hasPrefix("zh") ? "\(base).en" : "\(base).zh-Hans"
        if let url = Bundle.main.url(forResource: other, withExtension: "md"),
           let s = try? String(contentsOf: url, encoding: .utf8) {
            return s
        }
        return fallback
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
                        await appState.health.probeHeartRateReadAccess()
                        appState.refreshHealthAuthorization()
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
