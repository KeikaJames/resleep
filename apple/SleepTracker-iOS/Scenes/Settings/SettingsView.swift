import SwiftUI
import SleepKit

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var vm = SettingsViewModel()
    @State private var showDeleteConfirm: Bool = false
    @State private var deleteError: String?
    @State private var deletedAt: Date?
    @State private var diagSummary: String = "—"
    @State private var clearedDiagAt: Date?

    var body: some View {
        NavigationStack {
            Form {
                Section("settings.section.permissions") {
                    Toggle("settings.shareWithHealth", isOn: $vm.shareWithHealthKit)
                }

                Section("settings.section.privacy") {
                    Toggle("settings.saveRawAudio", isOn: $vm.saveRawAudio)
                    Toggle("settings.allowAudioUpload", isOn: $vm.audioUploadEnabled)
                    Toggle("settings.cloudSync", isOn: $vm.cloudSyncEnabled).disabled(true)
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
                } footer: {
                    Text("settings.reminders.footer")
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
                    NavigationLink {
                        DiagnosticsView()
                    } label: {
                        Label("settings.diag.view", systemImage: "doc.text.magnifyingglass")
                    }
                    Button {
                        Task { await refreshDiagSummary() }
                    } label: {
                        Label("settings.diag.refresh", systemImage: "arrow.clockwise")
                    }
                    Text(diagSummary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
                } footer: {
                    Text("settings.diag.footer")
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
                    Text("settings.compliance.l1")
                    Text("settings.compliance.l2")
                    Text("settings.compliance.l3")
                } header: {
                    Text("settings.section.compliance")
                }

                Section("settings.section.about") {
                    LabeledContent("settings.about.appVersion", value: Self.versionString)
                    LabeledContent("settings.about.build", value: Self.buildString)
                    LabeledContent("settings.about.engine", value: "InMemory (rule-based)")
                    NavigationLink("settings.about.privacy") {
                        LegalDocumentView(titleKey: "settings.about.privacy",
                                          text: LegalCopy.privacy(for: Locale.preferred))
                    }
                    NavigationLink("settings.about.terms") {
                        LegalDocumentView(titleKey: "settings.about.terms",
                                          text: LegalCopy.terms(for: Locale.preferred))
                    }
                }
            }
            .navigationTitle("settings.title")
            .task { await refreshDiagSummary() }
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
                Text("Sessions, summaries, and timelines stored on this device will be removed.")
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
        } catch {
            deleteError = "Delete failed: \(error)"
        }
    }

    private func refreshDiagSummary() async {
        if let report = await appState.generateLatestUnattendedReport() {
            diagSummary = "Latest: \(report.sessionId ?? "—") · "
                + "HR \(report.hrSampleCount) · "
                + "accel \(report.accelWindowCount) · "
                + "alarm \(report.alarmFinalState ?? "—")"
        } else {
            diagSummary = "No diagnostic events yet."
        }
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
}

// MARK: - Legal document viewer

private struct LegalDocumentView: View {
    let titleKey: LocalizedStringKey
    let text: String

    var body: some View {
        ScrollView {
            Text(text)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .textSelection(.enabled)
        }
        .navigationTitle(titleKey)
        .navigationBarTitleDisplayMode(.inline)
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

private enum LegalCopy {
    static func privacy(for locale: Locale) -> String {
        locale.isChinese ? privacyZh : privacyEn
    }
    static func terms(for locale: Locale) -> String {
        locale.isChinese ? termsZh : termsEn
    }

    private static let privacyEn = """
    Sleep is offline-first. Everything you record stays on your device by default.

    What stays local
    • Heart rate, motion, and derived sleep stages.
    • Session history and diagnostic logs.
    • Any audio captured for breathing detection.

    What we never do
    • We never upload raw audio. The microphone, when enabled, runs on-device only.
    • We do not include third-party analytics, advertising, or tracking SDKs.
    • We do not run a backend for your data.

    HealthKit
    If you allow it, Sleep can read heart rate and HRV from HealthKit and write a sleep analysis sample back. You can revoke either at any time in the iOS Settings → Health → Data Access & Devices.

    Diagnostics
    A local diagnostic log records events such as session start/stop and Watch reachability so you can review what happened overnight. The log lives in this app's container and can be cleared from Settings → Diagnostics.

    Children
    Sleep is not directed at children under 13.

    Contact
    If you have questions, contact the developer through the App Store listing.
    """

    private static let privacyZh = """
    Sleep 默认完全离线。你记录的一切默认都留在你的设备上。

    本地保存
    • 心率、运动数据，以及由此推断出的睡眠阶段。
    • 会话历史与诊断日志。
    • 用于呼吸检测的所有音频帧（仅在内存中）。

    我们绝不会做的事
    • 我们绝不上传原始音频。麦克风（启用时）只在设备本地运行。
    • 我们不包含任何第三方分析、广告或跟踪 SDK。
    • 我们不为你的数据运行任何后端。

    HealthKit
    如果你授权，Sleep 可以从 HealthKit 读取心率和 HRV，并写入一条睡眠分析样本。你可以随时在 iOS 设置 → 健康 → 数据访问与设备 中撤销。

    诊断
    本地诊断日志会记录会话开始/结束、Watch 可达性等事件，便于你查看夜间发生了什么。日志保存在本应用容器内，可在设置 → 诊断 中清除。

    儿童
    Sleep 并非面向 13 岁以下儿童。

    联系
    如有任何问题，请通过 App Store 列表联系开发者。
    """

    private static let termsEn = """
    Sleep is provided as-is for personal wellness use.

    Not a medical device
    Sleep does not diagnose, treat, cure, or prevent any disease or condition. The sleep stages, score, and alarm features are estimates based on consumer sensors. Do not rely on Sleep for any medical decision. If you have a sleep disorder or any health concern, consult a qualified clinician.

    Use at your own risk
    Sleep may produce inaccurate results, miss alarms, or stop tracking unexpectedly. Do not rely on the smart alarm if missing it would cause harm.

    Your data
    You are responsible for your device and your data. Sleep stores data locally; if you delete the app or your device, that data is lost.

    Changes
    These terms may change in future versions of Sleep. Continued use after an update means you accept the updated terms.
    """

    private static let termsZh = """
    Sleep 按"现状"提供，仅用于个人健康追踪。

    非医疗器械
    Sleep 不诊断、治疗、治愈或预防任何疾病或健康状况。睡眠阶段、评分和闹钟功能均为基于消费级传感器的估计值。请勿将 Sleep 作为任何医疗决策的依据。如有睡眠障碍或健康问题，请咨询合格的临床医生。

    使用风险自负
    Sleep 可能产生不准确的结果、错过闹钟或意外停止追踪。如果错过闹钟会造成伤害，请勿依赖智能闹钟。

    你的数据
    你对自己的设备和数据负责。Sleep 在本地存储数据；删除应用或设备会导致数据丢失。

    条款变更
    这些条款可能在 Sleep 后续版本中更改。更新后继续使用即表示你接受更新后的条款。
    """
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
