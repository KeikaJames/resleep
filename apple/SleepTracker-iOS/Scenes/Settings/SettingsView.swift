import SwiftUI
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
                NavigationLink("settings.about.license") {
                    LegalDocumentView(titleKey: "settings.about.license",
                                      text: LegalCopy.license())
                }
                NavigationLink("settings.about.privacy") {
                    LegalDocumentView(titleKey: "settings.about.privacy",
                                      text: LegalCopy.privacy(for: Locale.preferred))
                }
                NavigationLink("settings.about.terms") {
                    LegalDocumentView(titleKey: "settings.about.terms",
                                      text: LegalCopy.terms(for: Locale.preferred),
                                      eyebrow: "settings.about.notMedicalDevice")
                }
                NavigationLink("settings.ai.eula") {
                    LegalDocumentView(titleKey: "settings.ai.eula",
                                      text: Self.eulaText(),
                                      eyebrow: "settings.about.notMedicalDevice")
                }
                NavigationLink("settings.about.thirdParty") {
                    LegalDocumentView(titleKey: "settings.about.thirdParty",
                                      text: LegalCopy.thirdParty())
                }
            } header: {
                Text("settings.about.legalHeader")
            } footer: {
                Text("settings.about.legalFooter")
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

    private static func eulaText() -> String {
        let preferred = Bundle.main.preferredLocalizations.first ?? "en"
        let candidate = preferred.hasPrefix("zh") ? "EULA.zh-Hans" : "EULA.en"
        if let url = Bundle.main.url(forResource: candidate, withExtension: "md"),
           let s = try? String(contentsOf: url, encoding: .utf8) {
            return s
        }
        return NSLocalizedString("ai.eula.short", comment: "")
    }
}

private enum LegalCopy {
    static func privacy(for locale: Locale) -> String {
        locale.isChinese ? privacyZh : privacyEn
    }
    static func terms(for locale: Locale) -> String {
        locale.isChinese ? termsZh : termsEn
    }
    static func thirdParty() -> String {
        if let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES",
                                     withExtension: "md"),
           let s = try? String(contentsOf: url, encoding: .utf8) {
            return s
        }
        return thirdPartyFallback
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

    private static let privacyEn = """
    # Privacy Notice

    *Effective: 2026 · Operator: BIRI GA*

    Circadia is an **offline-first** general wellness app. We designed it so that everything you record stays on your device by default. We do not run a backend for your data, and we do not include any third-party analytics, advertising, or tracking SDKs.

    ## 1. What we process locally

    - Heart rate, heart-rate variability, and motion samples from Apple Watch or HealthKit.
    - Derived sleep stages, session timeline, score, and personal labels you enter.
    - Snore / breathing event counts (boolean events only — no audio is stored).
    - Diagnostic events such as session start/stop and Watch reachability.

    ## 2. What we never do

    - We do **not** upload raw audio. The microphone, when enabled, runs on-device only and the audio buffer is discarded after analysis.
    - We do **not** transmit your sleep data, chat history, or HealthKit data off the device.
    - We do **not** sell, rent, or share your personal information with any third party.

    ## 3. HealthKit

    If you allow it, Circadia reads heart rate / HRV from HealthKit and writes a sleep-analysis sample back. You can revoke either permission at any time in iOS **Settings → Health → Data Access & Devices**. Health data is treated as sensitive personal information and is never copied off the device by Circadia.

    ## 4. Sleep AI assistant

    The Sleep AI assistant runs a language model **on this iPhone**. Your prompts and the model's replies are processed locally. Replies are clearly labeled as AI-generated content. They are produced by a generative model, may be inaccurate, and **must not** be used as medical advice.

    ## 5. Your rights

    You can at any time:

    - View, export, or copy the data Circadia stores (Settings → Local Data).
    - Delete a single session or all local data (Settings → Local Data → Delete all).
    - Revoke HealthKit, Microphone, Notifications, or Motion permissions in iOS Settings.
    - Withdraw consent for the AI assistant (Settings → AI Assistant Terms → reset).

    Because Circadia does not transmit your data, requests for access, correction, or deletion are fulfilled directly on your device by the controls above.

    ## 6. Children

    Circadia is a general wellness product and is **not directed at children under 13** (or under 14 in mainland China). Please do not use Circadia to record a minor's data without a parent or legal guardian's consent.

    ## 7. Changes

    If we materially change how Circadia handles personal information, we will update this notice and surface the change in-app before the new version takes effect.

    ## 8. Contact

    Questions or complaints: contact the developer through the App Store listing for **Circadia**, or write to **support@biriga.app**.

    ---

    *© 2026 BIRI GA. Circadia is a general wellness product, not a medical device.*
    """

    private static let privacyZh = """
    # 隐私政策

    *生效日期：2026 年 · 运营者：BIRI GA*

    Circadia 是一款**离线优先**的健康类应用。我们的设计原则是：你记录的一切默认都留在你的设备上。我们不为你的数据运行任何后端，也不集成任何第三方统计、广告或追踪 SDK。

    ## 一、本地处理的信息

    - 来自 Apple Watch 或 HealthKit 的心率、心率变异性（HRV）、运动数据；
    - 由上述数据推算出的睡眠阶段、会话时间线、评分，以及你主动输入的个性化标签；
    - 打鼾 / 呼吸事件计数（仅事件计数，**不保存任何音频**）；
    - 会话开始/结束、Watch 连接状态等诊断事件。

    ## 二、我们绝不做的事

    - 我们**不会**上传任何原始音频。麦克风（在你启用时）只在本机运行，音频帧分析完即被丢弃；
    - 我们**不会**将你的睡眠数据、对话记录或 HealthKit 数据传出本设备；
    - 我们**不会**向任何第三方出售、出租或共享你的个人信息。

    ## 三、HealthKit

    在你授权后，Circadia 会从 HealthKit 读取心率 / HRV 数据，并写入一条"睡眠分析"样本。你可以随时在 iOS **设置 → 健康 → 数据访问与设备** 中撤销授权。健康数据属于敏感个人信息，Circadia 不会将其复制出本设备。

    ## 四、Sleep AI 助手

    Sleep AI 助手在你的 iPhone 上**本地运行**一个语言模型。你的提问与模型的回复均在本机处理。回复内容会被显著标识为"由 AI 生成"。该内容由生成式模型产出，可能存在错误，**不构成医疗建议**。

    ## 五、你的权利

    依据《中华人民共和国个人信息保护法》以及其他适用法律，你可以随时：

    - 查阅、导出或复制 Circadia 在本机存储的数据（设置 → 本地数据）；
    - 删除单条会话或全部本地数据（设置 → 本地数据 → 删除全部数据）；
    - 在 iOS 系统设置中撤销 HealthKit、麦克风、通知、运动与体能等权限；
    - 撤回对 AI 助手的同意（设置 → AI 使用条款 → 重置）。

    由于 Circadia 不会将你的数据传出本设备，所有查阅、更正、删除请求均通过上述入口在本机直接完成。

    ## 六、未成年人

    Circadia 属于一般健康类产品，**不面向 13 周岁以下儿童**（在中国大陆为 14 周岁以下）。请勿在未取得未成年人监护人同意的情况下使用 Circadia 记录未成年人的数据。

    ## 七、政策变更

    如果我们对个人信息处理方式作出重大调整，我们会更新本政策，并在新版本生效前通过应用内显著方式告知你。

    ## 八、联系方式

    如有任何疑问或投诉，请通过 App Store 中 **Circadia** 的应用页面联系开发者，或发送邮件至 **support@biriga.app**。

    ---

    *© 2026 BIRI GA。Circadia 为一般健康类产品，**非医疗器械**。*
    """

    private static let termsEn = """
    # Terms of Use

    *Effective: 2026 · Provider: BIRI GA*

    > **Important — Not a medical device.** Circadia is a general wellness product. It is **not** intended to diagnose, treat, cure, mitigate, or prevent any disease or medical condition, including any sleep disorder. Sleep stages, score, snore counts, and the smart alarm are estimates based on consumer-grade sensors and an on-device model.

    ## 1. Acceptance

    By installing or using Circadia you agree to these Terms. If you do not agree, do not use the app.

    ## 2. Wellness use only

    Circadia is provided for personal wellness and self-tracking. Do not use Circadia in place of professional medical advice, diagnosis, or treatment. If you have or suspect a sleep disorder or any other health concern, consult a qualified clinician. **In an emergency, contact your local emergency services immediately.**

    ## 3. Estimates, not measurements

    Sleep stages, score, snore detection, and HRV-derived metrics are statistical estimates and may be inaccurate. The smart alarm is best-effort and may misfire or fail to fire. **Do not rely on the smart alarm if missing a wake-up could cause harm.**

    ## 4. Sleep AI assistant

    The Sleep AI assistant uses a generative language model that runs on your device. Its replies are AI-generated, may be inaccurate, incomplete, or misleading, and **must not** be used as a basis for any medical, financial, legal, or safety decision. Do not enter another person's medical or other sensitive information into the assistant.

    ## 5. Your data

    Circadia stores data locally on your device. You are responsible for backing up your device and for the data you enter. If you delete the app or your device, your local data is lost. See the **Privacy Notice** for details.

    ## 6. Intellectual property

    Circadia, its name, logo, source code, model assets, and content are owned by BIRI GA or its licensors and are protected by copyright, trademark, and other applicable laws. Open-source components are governed by their own licenses; see **Third-Party Notices** in this About screen.

    ## 7. Disclaimer of warranties

    To the maximum extent permitted by law, Circadia is provided **"AS IS" and "AS AVAILABLE"**, without warranties of any kind, whether express, implied, or statutory, including warranties of merchantability, fitness for a particular purpose, accuracy, and non-infringement.

    ## 8. Limitation of liability

    To the maximum extent permitted by law, in no event will BIRI GA, its affiliates, or its licensors be liable for any indirect, incidental, special, consequential, or punitive damages, or for any loss of data, profits, or goodwill, arising out of or in connection with your use of, or inability to use, Circadia.

    ## 9. Changes

    We may update these Terms in future versions of Circadia. Material changes will be surfaced in-app. Continued use after an update means you accept the updated Terms.

    ## 10. Contact

    BIRI GA · support@biriga.app

    ---

    *© 2026 BIRI GA. All rights reserved.*
    """

    private static let termsZh = """
    # 用户协议

    *生效日期：2026 年 · 提供方：BIRI GA*

    > **重要提示 — 非医疗器械。**Circadia 属于一般健康类产品，**不用于**诊断、治疗、治愈、缓解或预防任何疾病或健康状况，包括任何睡眠障碍。睡眠阶段、评分、打鼾计数、智能闹钟等结果均为基于消费级传感器和本机模型的估计值。

    ## 一、接受条款

    安装或使用 Circadia 即表示你接受本协议。如不同意，请勿使用本应用。

    ## 二、仅供健康追踪

    Circadia 仅供个人健康追踪与自我管理之用。请勿将 Circadia 作为专业医疗建议、诊断或治疗的替代。如你存在或怀疑存在睡眠障碍或其他健康问题，请咨询合格的临床医生。**在紧急情况下，请立即联系当地急救服务。**

    ## 三、估计值，非测量值

    睡眠阶段、评分、打鼾检测以及 HRV 相关指标均为统计估计值，可能存在误差。智能闹钟为尽力而为机制，可能误触发或未触发。**如果错过起床会带来伤害风险，请勿依赖智能闹钟。**

    ## 四、Sleep AI 助手

    Sleep AI 助手使用在你设备上本地运行的生成式语言模型。其回复为**由 AI 生成**的内容，可能存在错误、遗漏或误导，**不得**作为任何医疗、金融、法律或人身安全决策的依据。请勿向助手输入他人的医疗信息或其他敏感信息。

    ## 五、你的数据

    Circadia 将数据存储在你的设备本地。你应自行备份设备并对你所输入的内容负责。删除应用或设备会导致本地数据丢失。详情参见**《隐私政策》**。

    ## 六、知识产权

    Circadia 的名称、标识、源代码、模型资源及内容由 BIRI GA 或其许可方拥有，受著作权、商标及其他适用法律保护。开源组件适用其各自许可证，详见"关于"页面中的**第三方声明**。

    ## 七、免责声明

    在适用法律允许的最大范围内，Circadia 按"**现状**"和"**可用状态**"提供，不附带任何明示、默示或法定的担保，包括但不限于适销性、特定用途适用性、准确性及非侵权担保。

    ## 八、责任限制

    在适用法律允许的最大范围内，BIRI GA 及其关联方与许可方均不对你因使用或无法使用 Circadia 而产生的任何间接的、偶发的、特殊的、后果性或惩罚性损失，或任何数据、利润或商誉损失承担责任。

    ## 九、协议变更

    我们可能在 Circadia 的后续版本中更新本协议。重大变更会在应用内显著告知。更新后继续使用即表示你接受更新后的条款。

    ## 十、联系方式

    BIRI GA · support@biriga.app

    ---

    *© 2026 BIRI GA。保留一切权利。*
    """

    private static let thirdPartyFallback = """
    # Third-Party Notices

    Circadia is built on open-source software. The following notices apply to components included in this app.

    ## MLX-Swift · Apache License 2.0

    Copyright © Apple Inc. Distributed under the Apache License, Version 2.0. See <https://www.apache.org/licenses/LICENSE-2.0>.

    ## MLX Swift Examples (MLXLLM, MLXLMCommon) · MIT License

    Copyright © Apple Inc. and contributors. Distributed under the MIT License.

    ## Google Gemma model weights · Gemma Terms of Use

    Use of Gemma model weights is subject to the **Gemma Terms of Use** and the **Gemma Prohibited Use Policy**. See <https://ai.google.dev/gemma/terms>.

    ## SQLite · Public Domain

    SQLite is in the public domain. See <https://www.sqlite.org/copyright.html>.

    ## SF Symbols · Apple Inc.

    SF Symbols are provided by Apple Inc. for use in Apple platform apps under the SF Symbols license terms.

    ---

    *Components above retain their original copyright. The remainder of Circadia is © 2026 BIRI GA.*
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
