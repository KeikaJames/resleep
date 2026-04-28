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

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer(minLength: 18)
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(.tint)
            Text("onboarding.gender.title")
                .font(.largeTitle.weight(.bold))
                .multilineTextAlignment(.leading)
            Text("onboarding.gender.body")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LazyVGrid(columns: columns, spacing: 12) {
                GenderOptionCard(kind: .male, selection: $selection)
                GenderOptionCard(kind: .female, selection: $selection)
            }
            GenderOptionCard(kind: .notDisclosed, selection: $selection, compact: true)

            Text("onboarding.gender.footer")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct GenderOptionCard: View {
    let kind: UserProfileGender
    @Binding var selection: UserProfileGender
    var compact: Bool = false

    private var isSelected: Bool { selection == kind }

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.22)) { selection = kind }
        } label: {
            VStack(spacing: compact ? 8 : 12) {
                if compact {
                    HStack(spacing: 12) {
                        GenderPortraitGlyph(kind: kind)
                            .frame(width: 54, height: 54)
                        Text(LocalizedStringKey(kind.titleKey))
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Spacer()
                        checkmark
                    }
                } else {
                    GenderPortraitGlyph(kind: kind)
                        .frame(height: 108)
                    HStack {
                        Text(LocalizedStringKey(kind.titleKey))
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Spacer()
                        checkmark
                    }
                }
            }
            .padding(compact ? 14 : 16)
            .frame(maxWidth: .infinity, minHeight: compact ? 80 : 170)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : Color(.separator).opacity(0.18),
                            lineWidth: isSelected ? 2 : 1)
            )
            .shadow(color: .black.opacity(isSelected ? 0.08 : 0.035),
                    radius: isSelected ? 14 : 8,
                    y: isSelected ? 8 : 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(LocalizedStringKey(kind.titleKey)))
    }

    @ViewBuilder
    private var checkmark: some View {
        if isSelected {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.tint)
        } else {
            Image(systemName: "circle")
                .font(.title3.weight(.regular))
                .foregroundStyle(.tertiary)
        }
    }
}

private struct GenderPortraitGlyph: View {
    let kind: UserProfileGender

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(.systemBackground))
            switch kind {
            case .male:
                MaleGlyph()
                    .padding(16)
            case .female:
                FemaleGlyph()
                    .padding(14)
            case .notDisclosed:
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.system(size: 34, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.primary)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

private struct MaleGlyph: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                sparkle(in: geo.size)

                Path { p in
                    p.move(to: CGPoint(x: w * 0.42, y: h * 0.25))
                    p.addLine(to: CGPoint(x: w * 0.80, y: h * 0.25))
                    p.addQuadCurve(to: CGPoint(x: w * 0.90, y: h * 0.58),
                                   control: CGPoint(x: w * 0.96, y: h * 0.34))
                    p.addQuadCurve(to: CGPoint(x: w * 0.58, y: h * 0.42),
                                   control: CGPoint(x: w * 0.76, y: h * 0.46))
                    p.addQuadCurve(to: CGPoint(x: w * 0.42, y: h * 0.25),
                                   control: CGPoint(x: w * 0.44, y: h * 0.39))
                }
                .fill(Color.primary)

                Path { p in
                    p.move(to: CGPoint(x: w * 0.47, y: h * 0.34))
                    p.addLine(to: CGPoint(x: w * 0.28, y: h * 0.64))
                    p.addLine(to: CGPoint(x: w * 0.42, y: h * 0.64))
                    p.addLine(to: CGPoint(x: w * 0.42, y: h * 0.80))
                    p.addLine(to: CGPoint(x: w * 0.72, y: h * 0.76))
                    p.addLine(to: CGPoint(x: w * 0.72, y: h * 0.90))
                    p.addLine(to: CGPoint(x: w * 0.46, y: h * 0.94))
                    p.addLine(to: CGPoint(x: w * 0.46, y: h * 0.70))
                    p.addLine(to: CGPoint(x: w * 0.34, y: h * 0.70))
                    p.closeSubpath()
                }
                .fill(Color.primary)

                Path { p in
                    p.move(to: CGPoint(x: w * 0.50, y: h * 0.56))
                    p.addQuadCurve(to: CGPoint(x: w * 0.64, y: h * 0.56),
                                   control: CGPoint(x: w * 0.57, y: h * 0.64))
                }
                .stroke(Color.primary, style: StrokeStyle(lineWidth: max(3, w * 0.045),
                                                          lineCap: .round))
            }
        }
    }
}

private struct FemaleGlyph: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                sparkle(in: geo.size)

                Path { p in
                    p.move(to: CGPoint(x: w * 0.47, y: h * 0.28))
                    p.addQuadCurve(to: CGPoint(x: w * 0.88, y: h * 0.68),
                                   control: CGPoint(x: w * 0.86, y: h * 0.20))
                    p.addQuadCurve(to: CGPoint(x: w * 0.54, y: h * 0.86),
                                   control: CGPoint(x: w * 0.74, y: h * 0.86))
                    p.addQuadCurve(to: CGPoint(x: w * 0.42, y: h * 0.62),
                                   control: CGPoint(x: w * 0.35, y: h * 0.74))
                    p.addLine(to: CGPoint(x: w * 0.35, y: h * 0.36))
                    p.closeSubpath()
                }
                .fill(Color.primary)

                Path { p in
                    p.move(to: CGPoint(x: w * 0.42, y: h * 0.34))
                    p.addLine(to: CGPoint(x: w * 0.72, y: h * 0.62))
                    p.addQuadCurve(to: CGPoint(x: w * 0.53, y: h * 0.74),
                                   control: CGPoint(x: w * 0.67, y: h * 0.74))
                    p.addQuadCurve(to: CGPoint(x: w * 0.44, y: h * 0.58),
                                   control: CGPoint(x: w * 0.42, y: h * 0.70))
                    p.addLine(to: CGPoint(x: w * 0.42, y: h * 0.34))
                }
                .fill(Color(.systemBackground))

                Path { p in
                    p.move(to: CGPoint(x: w * 0.36, y: h * 0.58))
                    p.addQuadCurve(to: CGPoint(x: w * 0.28, y: h * 0.94),
                                   control: CGPoint(x: w * 0.14, y: h * 0.76))
                    p.addQuadCurve(to: CGPoint(x: w * 0.64, y: h * 0.82),
                                   control: CGPoint(x: w * 0.44, y: h * 0.78))
                    p.addQuadCurve(to: CGPoint(x: w * 0.50, y: h * 0.66),
                                   control: CGPoint(x: w * 0.58, y: h * 0.68))
                    p.closeSubpath()
                }
                .fill(Color.primary)

                Path { p in
                    p.move(to: CGPoint(x: w * 0.50, y: h * 0.56))
                    p.addQuadCurve(to: CGPoint(x: w * 0.62, y: h * 0.56),
                                   control: CGPoint(x: w * 0.56, y: h * 0.62))
                }
                .stroke(Color.primary, style: StrokeStyle(lineWidth: max(3, w * 0.043),
                                                          lineCap: .round))
            }
        }
    }
}

private func sparkle(in size: CGSize) -> some View {
    Path { p in
        let cx = size.width * 0.22
        let cy = size.height * 0.22
        let r = size.width * 0.10
        p.move(to: CGPoint(x: cx, y: cy - r))
        p.addQuadCurve(to: CGPoint(x: cx + r, y: cy),
                       control: CGPoint(x: cx + r * 0.22, y: cy - r * 0.22))
        p.addQuadCurve(to: CGPoint(x: cx, y: cy + r),
                       control: CGPoint(x: cx + r * 0.22, y: cy + r * 0.22))
        p.addQuadCurve(to: CGPoint(x: cx - r, y: cy),
                       control: CGPoint(x: cx - r * 0.22, y: cy + r * 0.22))
        p.addQuadCurve(to: CGPoint(x: cx, y: cy - r),
                       control: CGPoint(x: cx - r * 0.22, y: cy - r * 0.22))
    }
    .fill(Color.primary)
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
