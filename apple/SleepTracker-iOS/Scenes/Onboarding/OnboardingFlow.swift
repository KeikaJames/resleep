import SwiftUI
import SleepKit

/// 5-screen onboarding shown the first time the app launches.
///
/// Pages:
///   1. Consent — accept Terms of Use + Privacy Notice (gates Next)
///   2. Welcome — value proposition (Apple-style hero with quiet typography)
///   3. Profile — optional gender selection for local personalization
///   4. Privacy — explicit on-device promise (no audio recording, no cloud)
///   5. Permissions — HealthKit ask + finish
struct OnboardingFlow: View {
    let onFinish: () -> Void

    @EnvironmentObject private var appState: AppState
    @State private var page: Int = 0
    @State private var termsAccepted: Bool = false
    @State private var privacyAccepted: Bool = false
    @State private var selectedGender: UserProfileGender = UserDefaults.standard
        .string(forKey: UserProfileGender.storageKey)
        .flatMap(UserProfileGender.init(rawValue:)) ?? .notDisclosed

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                ConsentPage(termsAccepted: $termsAccepted,
                            privacyAccepted: $privacyAccepted).tag(0)
                WelcomePage().tag(1)
                GenderSelectionPage(selection: $selectedGender).tag(2)
                PrivacyPage().tag(3)
                PermissionsPage(onFinish: finish).tag(4)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            HStack(spacing: 12) {
                if page > 0 {
                    Button("onboarding.back") { withAnimation { page -= 1 } }
                        .buttonStyle(.bordered)
                }
                Spacer()
                if page < 4 {
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
        defaults.set(selectedGender.rawValue, forKey: UserProfileGender.storageKey)
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

private struct GenderSelectionPage: View {
    @Binding var selection: UserProfileGender
    @Namespace private var liquidNamespace

    var body: some View {
        GeometryReader { proxy in
            let portraitSide = min(max(proxy.size.height * 0.30, 200), 280)

            VStack(spacing: 0) {
                Spacer(minLength: 20)

                VStack(spacing: 10) {
                    Text("onboarding.gender.title")
                        .font(.largeTitle.weight(.bold))
                        .multilineTextAlignment(.center)
                    Text("onboarding.gender.body")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 30)

                Spacer(minLength: 16)

                GenderPortraitStage(selection: selection, side: portraitSide)

                Spacer(minLength: 18)

                VStack(spacing: 10) {
                    ForEach(UserProfileGender.allCases, id: \.self) { gender in
                        LiquidGenderOptionCard(kind: gender,
                                               selection: $selection,
                                               namespace: liquidNamespace)
                    }
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: 450)

                Text("onboarding.gender.footer")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 12)
                    .padding(.horizontal, 30)

                Spacer(minLength: 18)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.smooth(duration: 0.26), value: selection)
        }
    }
}

private struct GenderPortraitStage: View {
    let selection: UserProfileGender
    let side: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .overlay {
                    Circle()
                        .stroke(
                            LinearGradient(colors: [
                                .white.opacity(0.72),
                                .white.opacity(0.16),
                                Color(.separator).opacity(0.12)
                            ], startPoint: .topLeading, endPoint: .bottomTrailing),
                            lineWidth: 1
                        )
                }
                .shadow(color: .black.opacity(0.07), radius: 28, y: 14)

            Circle()
                .fill(
                    RadialGradient(colors: [
                        Color.accentColor.opacity(0.14),
                        Color.accentColor.opacity(0.03),
                        .clear
                    ], center: .topLeading, startRadius: 8, endRadius: side * 0.74)
                )
                .blur(radius: 10)
                .padding(8)

            ZStack {
                ForEach(UserProfileGender.allCases, id: \.self) { gender in
                    if gender == selection {
                        Image(gender.onboardingAssetName)
                            .resizable()
                            .scaledToFit()
                            .frame(width: side * 0.88, height: side * 0.88)
                            .transition(
                                .asymmetric(
                                    insertion: .opacity.combined(with: .scale(scale: 1.035)),
                                    removal: .opacity.combined(with: .scale(scale: 0.965))
                                )
                            )
                    }
                }
            }
            .animation(.smooth(duration: 0.28), value: selection)
            .shadow(color: .black.opacity(0.10), radius: 14, y: 8)
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}

private struct LiquidGenderOptionCard: View {
    let kind: UserProfileGender
    @Binding var selection: UserProfileGender
    let namespace: Namespace.ID

    private var isSelected: Bool { selection == kind }

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                selection = kind
            }
        } label: {
            ZStack {
                if isSelected {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                        .matchedGeometryEffect(id: "genderLiquidSelection", in: namespace)
                }

                HStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(.thinMaterial)
                        Image(kind.onboardingAssetName)
                            .resizable()
                            .scaledToFit()
                            .padding(8)
                    }
                    .frame(width: 48, height: 48)
                    .overlay {
                        Circle()
                            .stroke(.white.opacity(isSelected ? 0.60 : 0.34), lineWidth: 1)
                    }

                    Text(LocalizedStringKey(kind.titleKey))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)

                    Spacer()

                    ZStack {
                        Circle()
                            .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.06))
                            .frame(width: 26, height: 26)
                        Image(systemName: isSelected ? "checkmark" : "circle")
                            .font(isSelected ? .footnote.weight(.bold) : .caption2.weight(.semibold))
                            .foregroundStyle(isSelected ? .white : Color.secondary.opacity(0.42))
                    }
                }
                .padding(.horizontal, 14)
            }
            .frame(height: 70)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(alignment: .topLeading) {
                Capsule()
                    .fill(
                        LinearGradient(colors: [
                            .white.opacity(isSelected ? 0.58 : 0.34),
                            .white.opacity(0.02)
                        ], startPoint: .leading, endPoint: .trailing)
                    )
                    .frame(width: 122, height: 22)
                    .blur(radius: 12)
                    .offset(x: 16, y: 4)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(
                        LinearGradient(colors: [
                            .white.opacity(isSelected ? 0.78 : 0.44),
                            Color(.separator).opacity(isSelected ? 0.22 : 0.12),
                            .white.opacity(0.08)
                        ], startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1
                    )
            }
            .shadow(color: .black.opacity(isSelected ? 0.12 : 0.06),
                    radius: isSelected ? 20 : 10,
                    y: isSelected ? 10 : 5)
            .scaleEffect(isSelected ? 1.018 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(LocalizedStringKey(kind.titleKey)))
    }
}

private extension UserProfileGender {
    var onboardingAssetName: String {
        switch self {
        case .male:
            return "OnboardingGenderMale"
        case .female:
            return "OnboardingGenderFemale"
        case .notDisclosed:
            return "OnboardingGenderUndisclosed"
        }
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
