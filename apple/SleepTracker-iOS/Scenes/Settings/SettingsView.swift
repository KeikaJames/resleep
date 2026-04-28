import SwiftUI
import UIKit
import PhotosUI
import SleepKit

struct SettingsView: View {
    @StateObject private var vm = SettingsViewModel()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        ProfileDetailsView(vm: vm)
                    } label: {
                        ProfileSummaryRow(
                            avatarData: vm.profileAvatarData,
                            nickname: vm.profileNickname,
                            birthday: vm.profileBirthday
                        )
                    }
                }

                Section {
                    NavigationLink {
                        SleepPlanSettingsView(vm: vm)
                    } label: {
                        SettingsCategoryRow(icon: "bed.double.fill",
                                            tint: .indigo,
                                            title: "settings.section.sleepPlan",
                                            subtitle: "settings.category.sleepPlan.subtitle")
                    }
                }

                Section {
                    NavigationLink {
                        PermissionsSettingsView(vm: vm)
                    } label: {
                        SettingsCategoryRow(icon: "heart.text.square.fill",
                                            tint: .red,
                                            title: "settings.section.permissions",
                                            subtitle: "settings.category.permissions.subtitle")
                    }
                    NavigationLink {
                        PrivacyInsightsSettingsView(vm: vm)
                    } label: {
                        SettingsCategoryRow(icon: "lock.shield.fill",
                                            tint: .blue,
                                            title: "settings.category.privacyInsights",
                                            subtitle: "settings.category.privacyInsights.subtitle")
                    }
                    NavigationLink {
                        ReminderSettingsView(vm: vm)
                    } label: {
                        SettingsCategoryRow(icon: "bell.badge.fill",
                                            tint: .orange,
                                            title: "settings.section.reminders",
                                            subtitle: "settings.category.reminders.subtitle")
                    }
                }

                Section {
                    NavigationLink {
                        DeviceModelSettingsView()
                    } label: {
                        SettingsCategoryRow(icon: "applewatch",
                                            tint: .green,
                                            title: "settings.category.deviceModel",
                                            subtitle: "settings.category.deviceModel.subtitle")
                    }
                    NavigationLink {
                        AIAssistantSettingsView()
                    } label: {
                        SettingsCategoryRow(icon: "sparkles",
                                            tint: .indigo,
                                            title: "settings.section.aiAssistant",
                                            subtitle: "settings.category.aiAssistant.subtitle")
                    }
                    NavigationLink {
                        DataSettingsView()
                    } label: {
                        SettingsCategoryRow(icon: "externaldrive.fill",
                                            tint: .gray,
                                            title: "settings.category.data",
                                            subtitle: "settings.category.data.subtitle")
                    }
                }

                Section {
                    NavigationLink {
                        DeveloperSettingsView()
                    } label: {
                        SettingsCategoryRow(icon: "hammer.fill",
                                            tint: .secondary,
                                            title: "settings.section.developer",
                                            subtitle: "settings.category.developer.subtitle")
                    }
                    NavigationLink {
                        AboutView()
                    } label: {
                        SettingsCategoryRow(icon: "info.circle.fill",
                                            tint: .cyan,
                                            title: "settings.section.about",
                                            subtitle: "settings.category.about.subtitle")
                    }
                }
            }
            .navigationTitle("settings.title")
        }
    }
}

// MARK: - Sleep plan

private struct SleepPlanSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var vm: SettingsViewModel

    var body: some View {
        Form {
            Section {
                Toggle("settings.sleepPlan.autoTracking", isOn: $vm.sleepPlanAutoTrackingEnabled)
                    .tint(.accentColor)
                DatePicker("settings.sleepPlan.bedtime",
                           selection: $vm.sleepPlanBedtime,
                           displayedComponents: [.hourAndMinute])
                DatePicker("settings.sleepPlan.wakeTime",
                           selection: $vm.sleepPlanWakeTime,
                           displayedComponents: [.hourAndMinute])
            } header: {
                Text("settings.section.sleepPlan")
            } footer: {
                Text("settings.sleepPlan.footer")
            }

            Section {
                Stepper(goalText,
                        value: $vm.sleepPlanGoalMinutes,
                        in: 4 * 60...12 * 60,
                        step: 15)
                Stepper(wakeWindowText,
                        value: $vm.sleepPlanSmartWakeWindowMinutes,
                        in: 5...45,
                        step: 5)
            } header: {
                Text("settings.sleepPlan.tuning")
            } footer: {
                Text("settings.sleepPlan.tuning.footer")
            }

            Section {
                Toggle("settings.sleepPlan.nightmareWake", isOn: $vm.sleepPlanNightmareWakeEnabled)
            } footer: {
                Text("settings.sleepPlan.nightmare.footer")
            }
        }
        .navigationTitle("settings.section.sleepPlan")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: vm.sleepPlanAutoTrackingEnabled) { _, _ in syncPlan() }
        .onChange(of: vm.sleepPlanBedtime) { _, _ in syncPlan() }
        .onChange(of: vm.sleepPlanWakeTime) { _, _ in syncPlan() }
        .onChange(of: vm.sleepPlanGoalMinutes) { _, _ in syncPlan() }
        .onChange(of: vm.sleepPlanSmartWakeWindowMinutes) { _, _ in syncPlan() }
        .onChange(of: vm.sleepPlanNightmareWakeEnabled) { _, _ in syncPlan() }
    }

    private var goalText: String {
        String(format: NSLocalizedString("settings.sleepPlan.goalFmt", comment: ""),
               formatMinutes(vm.sleepPlanGoalMinutes))
    }

    private var wakeWindowText: String {
        String(format: NSLocalizedString("settings.sleepPlan.wakeWindowFmt", comment: ""),
               vm.sleepPlanSmartWakeWindowMinutes)
    }

    private func syncPlan() {
        vm.persistCurrentSleepPlan()
        appState.applySleepPlanForTonight()
        appState.publishSnapshot()
    }

    private func formatMinutes(_ minutes: Int) -> String {
        let h = minutes / 60
        let m = minutes % 60
        if m == 0 { return "\(h)h" }
        return "\(h)h \(m)m"
    }
}

// MARK: - Profile

private struct ProfileSummaryRow: View {
    let avatarData: Data?
    let nickname: String
    let birthday: Date?

    var body: some View {
        HStack(spacing: 12) {
            ProfileAvatarImage(avatarData: avatarData, size: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text("settings.section.profile")
                    .foregroundStyle(.primary)
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
        }
        .padding(.vertical, 4)
    }

    private var summary: String {
        let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        let birthdayText = birthday?.formatted(date: .abbreviated, time: .omitted)
        switch (trimmed.isEmpty, birthdayText) {
        case (false, let birthdayText?):
            return "\(trimmed) · \(birthdayText)"
        case (false, nil):
            return trimmed
        case (true, let birthdayText?):
            return birthdayText
        case (true, nil):
            return NSLocalizedString("settings.profile.summary.empty", comment: "")
        }
    }
}

private struct ProfileDetailsView: View {
    @ObservedObject var vm: SettingsViewModel
    @State private var selectedAvatarItem: PhotosPickerItem?

    var body: some View {
        let avatarData = vm.profileAvatarData
        let hasAvatar = avatarData != nil

        Form {
            Section {
                VStack(spacing: 10) {
                    PhotosPicker(selection: $selectedAvatarItem, matching: .images) {
                        ProfileAvatarImage(avatarData: avatarData, size: 96)
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: "camera.circle.fill")
                                    .font(.system(size: 28))
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, Color.accentColor)
                                    .background(Circle().fill(Color(.systemBackground)))
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("settings.profile.avatar"))
                    .accessibilityHint(Text(LocalizedStringKey(!hasAvatar
                                                               ? "settings.profile.avatar.choose"
                                                               : "settings.profile.avatar.change")))

                    Text(LocalizedStringKey(!hasAvatar
                                            ? "settings.profile.avatar.choose"
                                            : "settings.profile.avatar.change"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.tint)

                    if hasAvatar {
                        Button(role: .destructive) {
                            vm.clearProfileAvatar()
                        } label: {
                            Text("settings.profile.avatar.remove")
                                .font(.subheadline)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } footer: {
                Text("settings.profile.avatar.subtitle")
            }

            Section {
                HStack {
                    Text("settings.profile.nickname")
                    TextField("settings.profile.nickname.placeholder", text: $vm.profileNickname)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.words)
                        .disableAutocorrection(true)
                }

                if vm.profileBirthday == nil {
                    Button {
                        vm.profileBirthday = Date()
                    } label: {
                        HStack {
                            Text("settings.profile.birthday")
                                .foregroundStyle(.primary)
                            Spacer()
                            Text("settings.profile.birthday.add")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    DatePicker("settings.profile.birthday",
                               selection: birthdayBinding,
                               in: ...Date(),
                               displayedComponents: [.date])
                    Button(role: .destructive) {
                        vm.profileBirthday = nil
                    } label: {
                        Text("settings.profile.birthday.clear")
                    }
                }
            }
        }
        .navigationTitle("settings.section.profile")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: selectedAvatarItem) { _, item in
            Task { await loadAvatar(from: item) }
        }
    }

    private var birthdayBinding: Binding<Date> {
        Binding {
            vm.profileBirthday ?? Date()
        } set: { newValue in
            vm.profileBirthday = min(newValue, Date())
        }
    }

    private func loadAvatar(from item: PhotosPickerItem?) async {
        guard let item else { return }
        if let data = try? await item.loadTransferable(type: Data.self) {
            await MainActor.run {
                vm.updateProfileAvatar(with: data)
                selectedAvatarItem = nil
            }
        }
    }
}

private struct ProfileAvatarImage: View {
    let avatarData: Data?
    let size: CGFloat

    var body: some View {
        if let avatarData, let image = UIImage(data: avatarData) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
        } else {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: size))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Settings categories

private struct SettingsCategoryRow: View {
    let icon: String
    let tint: Color
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 7).fill(tint))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct PermissionsSettingsView: View {
    @ObservedObject var vm: SettingsViewModel

    var body: some View {
        Form {
            Section("settings.section.permissions") {
                HealthAuthorizationRow()
                Toggle("settings.shareWithHealth", isOn: $vm.shareWithHealthKit)
            }
        }
        .navigationTitle("settings.section.permissions")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PrivacyInsightsSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var vm: SettingsViewModel

    var body: some View {
        Form {
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
        }
        .navigationTitle("settings.category.privacyInsights")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: vm.personalizationEnabled) { _, on in
            appState.inferencePipeline.personalizationEnabled = on
        }
    }
}

private struct ReminderSettingsView: View {
    @ObservedObject var vm: SettingsViewModel

    var body: some View {
        Form {
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
        }
        .navigationTitle("settings.section.reminders")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: vm.bedtimeReminderEnabled) { _, on in
            Task { await applyBedtime(on: on, at: vm.bedtimeReminderTime) }
        }
        .onChange(of: vm.bedtimeReminderTime) { _, time in
            if vm.bedtimeReminderEnabled {
                Task { await applyBedtime(on: true, at: time) }
            }
        }
    }

    private func applyBedtime(on: Bool, at time: Date) async {
        let service = BedtimeReminderService()
        if on {
            _ = await service.requestAuthorization()
            let comps = Calendar.current.dateComponents([.hour, .minute], from: time)
            await service.schedule(at: comps.hour ?? 22, minute: comps.minute ?? 30)
        } else {
            await service.cancel()
        }
    }
}

private struct DeviceModelSettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Form {
            Section("settings.section.watch") {
                LabeledContent("card.deviceSync.reachable",
                               value: appState.router.watchReachable
                                    ? NSLocalizedString("card.deviceSync.yes", comment: "")
                                    : NSLocalizedString("card.deviceSync.no", comment: ""))
                LabeledContent("card.deviceSync.lastSync",
                               value: settingsRelativeDate(appState.router.lastBatchAt))
            }

            Section("settings.section.model") {
                LabeledContent("settings.model.backend",
                               value: appState.inferencePipeline.descriptor.isRealModel
                                        ? NSLocalizedString("settings.model.coreml", comment: "")
                                        : NSLocalizedString("settings.model.heuristic", comment: ""))
                LabeledContent("settings.model.name", value: appState.inferencePipeline.descriptor.name)
                if let version = appState.inferencePipeline.descriptor.version {
                    LabeledContent("settings.model.version", value: version)
                }
                if let reason = appState.inferenceFallbackReason {
                    Text(reason).font(.footnote).foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle("settings.category.deviceModel")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AIAssistantSettingsView: View {
    var body: some View {
        Form {
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
        }
        .navigationTitle("settings.section.aiAssistant")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var aiModelStatusValue: String {
        // MLX cannot run on the iOS Simulator, so simulator builds honestly
        // report the rule-based engine instead of implying the LLM is active.
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
           let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        return NSLocalizedString("ai.eula.short", comment: "")
    }
}

private struct DataSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showDeleteConfirm: Bool = false
    @State private var deleteError: String?
    @State private var deletedAt: Date?
    @State private var clearedDiagAt: Date?

    var body: some View {
        Form {
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
                    Text("\(NSLocalizedString("settings.cleared", comment: "")) \(settingsRelativeDate(clearedDiagAt))")
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
                    Text("\(NSLocalizedString("settings.cleared", comment: "")) \(settingsRelativeDate(deletedAt))")
                        .font(.footnote).foregroundStyle(.tertiary)
                }
                if let deleteError {
                    Text(deleteError).font(.footnote).foregroundStyle(.red)
                }
            } header: {
                Text("settings.section.localData")
            } footer: {
                Text("settings.localData.footer")
            }
        }
        .navigationTitle("settings.category.data")
        .navigationBarTitleDisplayMode(.inline)
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

    private func clearDiagnostics() async {
        await appState.diagnostics.clear()
        clearedDiagAt = Date()
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
}

private struct DeveloperSettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Form {
            Section("settings.section.developer") {
                LabeledContent("settings.dev.runtime",
                               value: appState.runtimeMode == .simulated
                                    ? NSLocalizedString("settings.dev.simulated", comment: "")
                                    : NSLocalizedString("settings.dev.live", comment: ""))
                Text("settings.dev.note")
                    .font(.footnote).foregroundStyle(.tertiary)
            }
        }
        .navigationTitle("settings.section.developer")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private func settingsRelativeDate(_ date: Date?) -> String {
    guard let date else { return "—" }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
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
