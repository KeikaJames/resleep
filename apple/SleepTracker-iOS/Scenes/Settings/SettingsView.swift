import SwiftUI
import UIKit
import SleepKit

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var vm = SettingsViewModel()
    @State private var showDeleteConfirm: Bool = false
    @State private var deleteError: String?
    @State private var deletedAt: Date?
    @State private var diagSummary: String = "—"  // legacy; no longer rendered.
    @State private var clearedDiagAt: Date?

    var body: some View {
        NavigationStack {
            Form {
                Section("settings.section.permissions") {
                    HealthAuthorizationRow()
                    Toggle("settings.shareWithHealth", isOn: $vm.shareWithHealthKit)
                }

                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "mic.slash.fill")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("settings.privacy.audio.title")
                                .font(.subheadline.weight(.medium))
                            Text("settings.privacy.audio.body")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Toggle("settings.cloudSync", isOn: $vm.cloudSyncEnabled).disabled(true)
                } header: {
                    Text("settings.section.privacy")
                }

                Section {
                    Toggle("settings.snoreDetection", isOn: $vm.snoreDetectionEnabled)
                    Toggle("settings.personalization", isOn: $vm.personalizationEnabled)
                } header: {
                    Text("settings.section.insights")
                } footer: {
                    Text("settings.insights.footer")
                }

                Section {
                    Toggle("settings.bedtimeReminder", isOn: $vm.bedtimeReminderEnabled)
                    if vm.bedtimeReminderEnabled {
                        DatePicker("settings.bedtimeTime",
                                   selection: $vm.bedtimeReminderTime,
                                   displayedComponents: [.hourAndMinute])
                    }
                } header: {
                    Text("settings.section.reminders")
                }
                .onChange(of: vm.bedtimeReminderEnabled) { _, on in
                    Task { await applyBedtime(on: on, at: vm.bedtimeReminderTime) }
                }
                .onChange(of: vm.bedtimeReminderTime) { _, t in
                    if vm.bedtimeReminderEnabled {
                        Task { await applyBedtime(on: true, at: t) }
                    }
                }
                .onChange(of: vm.personalizationEnabled) { _, on in
                    appState.inferencePipeline.personalizationEnabled = on
                }

                Section("settings.section.watch") {
                    LabeledContent("card.deviceSync.reachable",
                                   value: appState.router.watchReachable
                                        ? NSLocalizedString("card.deviceSync.yes", comment: "")
                                        : NSLocalizedString("card.deviceSync.no", comment: ""))
                    LabeledContent("card.deviceSync.lastSync",
                                   value: relativeDate(appState.router.lastBatchAt))
                }

                Section("settings.section.model") {
                    LabeledContent("settings.model.backend",
                                   value: appState.inferencePipeline.descriptor.isRealModel
                                            ? NSLocalizedString("settings.model.coreml", comment: "")
                                            : NSLocalizedString("settings.model.heuristic", comment: ""))
                    LabeledContent("settings.model.name", value: appState.inferencePipeline.descriptor.name)
                    if let v = appState.inferencePipeline.descriptor.version {
                        LabeledContent("settings.model.version", value: v)
                    }
                    if let reason = appState.inferenceFallbackReason {
                        Text(reason).font(.footnote).foregroundStyle(.orange)
                    }
                }

                Section {
                    LabeledContent("settings.ai.modelPath",
                                   value: aiModelStatusValue)
                    NavigationLink {
                        LegalDocumentView(titleKey: "settings.ai.eula",
                                          text: aiEulaText())
                    } label: {
                        Label("settings.ai.eula", systemImage: "doc.text")
                    }
                    Text("settings.ai.disclaimer")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Text("settings.section.aiAssistant")
                }

                Section {
                    NavigationLink {
                        DiagnosticsView()
                    } label: {
                        Label("settings.diag.view", systemImage: "doc.text.magnifyingglass")
                    }
                    Button(role: .destructive) {
                        Task { await clearDiagnostics() }
                    } label: {
                        Label("settings.diag.clear", systemImage: "trash")
                    }
                    if let clearedDiagAt {
                        Text("\(NSLocalizedString("settings.cleared", comment: "")) \(relativeDate(clearedDiagAt))")
                            .font(.footnote).foregroundStyle(.tertiary)
                    }
                } header: {
                    Text("settings.section.diagnostics")
                }

                Section {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("settings.localData.delete", systemImage: "trash")
                    }
                    if let deletedAt {
                        Text("\(NSLocalizedString("settings.cleared", comment: "")) \(relativeDate(deletedAt))")
                            .font(.footnote).foregroundStyle(.tertiary)
                    }
                    if let err = deleteError {
                        Text(err).font(.footnote).foregroundStyle(.red)
                    }
                } header: {
                    Text("settings.section.localData")
                } footer: {
                    Text("settings.localData.footer")
                }

                Section("settings.section.developer") {
                    LabeledContent("settings.dev.runtime",
                                   value: appState.runtimeMode == .simulated
                                        ? NSLocalizedString("settings.dev.simulated", comment: "")
                                        : NSLocalizedString("settings.dev.live", comment: ""))
                    Text("settings.dev.note")
                        .font(.footnote).foregroundStyle(.tertiary)
                }

                Section {
                    NavigationLink {
                        AboutView()
                    } label: {
                        Label("settings.section.about", systemImage: "info.circle")
                    }
                }
            }
            .navigationTitle("settings.title")
            .confirmationDialog(
                "settings.localData.confirmTitle",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("settings.localData.confirmDelete", role: .destructive) {
                    Task { await deleteAllLocalData() }
                }
                Button("settings.localData.confirmCancel", role: .cancel) {}
            } message: {
                Text("settings.localData.confirmMessage")
            }
        }
    }

    private func relativeDate(_ d: Date?) -> String {
        guard let d else { return "—" }
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .abbreviated
        return fmt.localizedString(for: d, relativeTo: Date())
    }

    private func deleteAllLocalData() async {
        do {
            try await appState.localStore.clearAllLocalData()
            appState.latestSummary = nil
            deletedAt = Date()
            deleteError = nil
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            deleteError = NSLocalizedString("settings.localData.deleteError", comment: "")
        }
    }

    private func refreshDiagSummary() async {
        // No-op kept for backwards compatibility with code that still calls
        // it; the inline summary cell was removed from the production form
        // because raw field names (sessionId, hrSampleCount, …) shouldn't
        // surface to end users. The DiagnosticsView screen renders the
        // full report on demand.
    }

    private func clearDiagnostics() async {
        await appState.diagnostics.clear()
        clearedDiagAt = Date()
        await refreshDiagSummary()
    }

    private func applyBedtime(on: Bool, at time: Date) async {
        let svc = BedtimeReminderService()
        if on {
            _ = await svc.requestAuthorization()
            let comps = Calendar.current.dateComponents([.hour, .minute], from: time)
            await svc.schedule(at: comps.hour ?? 22, minute: comps.minute ?? 30)
        } else {
            await svc.cancel()
        }
    }

    private static var versionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private static var buildString: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    private var aiModelStatusValue: String {
        // Honest one-liner about which engine the AI tab is currently using.
        // MLX cannot run on the iOS Simulator (Metal driver gap), so on the
        // simulator we transparently fall back to the rule-based engine.
        #if targetEnvironment(simulator)
        return NSLocalizedString("settings.ai.engineRuleBased", comment: "")
        #else
        return NSLocalizedString("settings.ai.engineGemma", comment: "")
        #endif
    }

    private func aiEulaText() -> String {
        let preferred = Bundle.main.preferredLocalizations.first ?? "en"
        let candidate = preferred.hasPrefix("zh") ? "EULA.zh-Hans" : "EULA.en"
        if let url = Bundle.main.url(forResource: candidate, withExtension: "md"),
           let s = try? String(contentsOf: url, encoding: .utf8) {
            return s
        }
        return NSLocalizedString("ai.eula.short", comment: "")
    }
}

// MARK: - Legal document viewer

private struct LegalDocumentView: View {
    let titleKey: LocalizedStringKey
    let text: String
    var eyebrow: LocalizedStringKey? = nil

    var body: some View {
        MarkdownDocumentView(titleKey: titleKey, text: text, eyebrow: eyebrow)
    }
}

// MARK: - Health authorization status row

/// Shows the live HealthKit read-access state and offers a one-tap path
/// to either re-prompt the user (when not yet asked) or to open iOS
/// Settings.app on the Circadia → Health entry (when the user denied).
///
/// Important: HealthKit's `authorizationStatus(for:)` only reflects WRITE
/// permission. The *real* read state is determined by a one-shot probe
/// query in `HealthPermissionService.probeHeartRateReadAccess()`. We
/// re-run that probe on every appearance of this row so users who
/// just granted access in Settings.app and switched back see the
/// updated state immediately.
private struct HealthAuthorizationRow: View {
    @EnvironmentObject private var appState: AppState
    @State private var rechecking: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("settings.health.title")
                        .font(.body)
                    Text(statusKey)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if rechecking {
                    ProgressView().controlSize(.small)
                }
            }

            HStack(spacing: 10) {
                Button {
                    Task { await recheck() }
                } label: {
                    Text("settings.health.recheck")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if appState.healthAuthorization == .sharingDenied
                    || appState.healthAuthorization == .unknown {
                    Button {
                        openSettings()
                    } label: {
                        Text("settings.health.openSettings")
                            .font(.footnote.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 4)
        .task { await recheck() }
    }

    private var icon: String {
        switch appState.healthAuthorization {
        case .sharingAuthorized: return "checkmark.seal.fill"
        case .sharingDenied:     return "exclamationmark.triangle.fill"
        case .notDetermined:     return "questionmark.circle.fill"
        case .unknown:           return "minus.circle.fill"
        }
    }
    private var tint: Color {
        switch appState.healthAuthorization {
        case .sharingAuthorized: return .green
        case .sharingDenied:     return .orange
        case .notDetermined:     return .blue
        case .unknown:           return .secondary
        }
    }
    private var statusKey: LocalizedStringKey {
        switch appState.healthAuthorization {
        case .sharingAuthorized: return "settings.health.status.granted"
        case .sharingDenied:     return "settings.health.status.denied"
        case .notDetermined:     return "settings.health.status.notDetermined"
        case .unknown:           return "settings.health.status.unknown"
        }
    }

    private func recheck() async {
        rechecking = true
        await appState.health.probeHeartRateReadAccess()
        appState.refreshHealthAuthorization()
        rechecking = false
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}

extension Locale {
    static var preferred: Locale {
        Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
    }
    var isChinese: Bool {
        (language.languageCode?.identifier ?? identifier).hasPrefix("zh")
    }
}

// MARK: - About

private struct AboutView: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("settings.about.appVersion", value: Self.versionString)
                LabeledContent("settings.about.build", value: Self.buildString)
                LabeledContent("settings.about.copyright", value: "© 2026 BIRI GA")
            }

            Section {
                NavigationLink("settings.about.terms") {
                    LegalDocumentView(titleKey: "settings.about.terms",
                                      text: LegalCopy.terms(),
                                      eyebrow: "settings.about.notMedicalDevice")
                }
                NavigationLink("settings.about.privacy") {
                    LegalDocumentView(titleKey: "settings.about.privacy",
                                      text: LegalCopy.privacy())
                }
                NavigationLink("settings.ai.eula") {
                    LegalDocumentView(titleKey: "settings.ai.eula",
                                      text: LegalCopy.aiEula(),
                                      eyebrow: "settings.about.notMedicalDevice")
                }
                NavigationLink("settings.about.license") {
                    LegalDocumentView(titleKey: "settings.about.license",
                                      text: LegalCopy.license())
                }
            } header: {
                Text("settings.about.legalHeader")
            } footer: {
                Text("settings.about.legalFooter")
            }

            Section {
                // Short Acknowledgments blurb is rendered inline so the user
                // sees who Circadia thanks without leaving the About screen.
                MarkdownBody(text: LegalCopy.acknowledgments())
                    .padding(.vertical, 4)
                NavigationLink("settings.about.thirdParty") {
                    LegalDocumentView(titleKey: "settings.about.thirdParty",
                                      text: LegalCopy.thirdParty())
                }
            } header: {
                Text("settings.about.acknowledgmentsHeader")
            }
        }
        .navigationTitle("settings.section.about")
        .navigationBarTitleDisplayMode(.inline)
    }

    private static var versionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }
    private static var buildString: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }
}

private enum LegalCopy {
    /// Pick the localised resource for the current preferred language.
    /// Loads the Markdown file from the bundle and falls back to a small
    /// inline notice if the resource is missing — so the row never shows
    /// blank in case of a packaging error.
    private static func loadLocalised(base: String, fallback: String) -> String {
        let preferred = Bundle.main.preferredLocalizations.first ?? "en"
        let suffix = preferred.hasPrefix("zh") ? "zh-Hans" : "en"
        let primary = "\(base).\(suffix)"
        if let url = Bundle.main.url(forResource: primary, withExtension: "md"),
           let s = try? String(contentsOf: url, encoding: .utf8) {
            return s
        }
        // Try the other locale before giving up.
        let other = preferred.hasPrefix("zh") ? "\(base).en" : "\(base).zh-Hans"
        if let url = Bundle.main.url(forResource: other, withExtension: "md"),
           let s = try? String(contentsOf: url, encoding: .utf8) {
            return s
        }
        return fallback
    }

    static func aiEula() -> String {
        loadLocalised(base: "EULA",
                      fallback: NSLocalizedString("ai.eula.short", comment: ""))
    }

    static func privacy() -> String {
        loadLocalised(base: "PrivacyNotice",
                      fallback: "# Privacy Notice\n\nNo content available.")
    }

    static func terms() -> String {
        loadLocalised(base: "Terms",
                      fallback: "# Terms of Use\n\nNo content available.")
    }

    static func acknowledgments() -> String {
        loadLocalised(base: "Acknowledgments",
                      fallback: "Circadia thanks Apple, Google DeepMind and the open-source community.")
    }

    static func thirdParty() -> String {
        loadLocalised(base: "THIRD_PARTY_NOTICES",
                      fallback: "# Third-Party Notices\n\nSee the source repository for the full list.")
    }

    /// MIT License text — sourced from the bundled `LICENSE` file when
    /// available, with an inline fallback so the row never shows blank.
    static func license() -> String {
        if let url = Bundle.main.url(forResource: "LICENSE", withExtension: nil),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        return """
        # MIT License

        Copyright (c) 2026 BIRI GA

        Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

        The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
        """
    }
}

// MARK: - Diagnostics view

private struct DiagnosticsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var text: String = "Loading…"

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(.footnote, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .textSelection(.enabled)
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    UIPasteboard.general.string = text
                } label: {
                    Image(systemName: "doc.on.doc")
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        if let report = await appState.generateLatestUnattendedReport() {
            text = UnattendedReportBuilder.renderText(report)
        } else {
            text = "No diagnostic events recorded yet."
        }
    }
}
