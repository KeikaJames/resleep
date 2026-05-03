import Foundation
import SwiftUI
import SleepKit

// MARK: - Persistent chat history

/// One saved conversation. Persisted as JSON in `UserDefaults` (small data,
/// foreground feature — fine without a real DB table).
struct StoredChat: Identifiable, Codable, Equatable {
    let id: UUID
    var createdAt: Date
    var title: String
    var messages: [PersistableMessage]

    static func make(from messages: [SleepAIMessage]) -> StoredChat {
        StoredChat(
            id: UUID(),
            createdAt: Date(),
            title: titleFrom(messages: messages),
            messages: messages.map(PersistableMessage.init(from:))
        )
    }

    static func titleFrom(messages: [SleepAIMessage]) -> String {
        let firstUser = messages.first { $0.role == .user }?.text
            ?? messages.first?.text
            ?? ""
        let trimmed = firstUser.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return NSLocalizedString("ai.history.empty", comment: "") }
        let cap = 28
        return trimmed.count > cap
            ? String(trimmed.prefix(cap)) + "…"
            : trimmed
    }
}

struct PersistableMessage: Codable, Equatable {
    enum Role: String, Codable { case user, assistant }
    var id: String
    var role: Role
    var text: String
    var createdAt: Date

    init(from m: SleepAIMessage) {
        self.id = m.id
        self.role = (m.role == .user) ? .user : .assistant
        self.text = m.text
        self.createdAt = m.createdAt
    }

    func toMessage() -> SleepAIMessage {
        SleepAIMessage(
            id: id,
            role: role == .user ? .user : .assistant,
            text: text,
            createdAt: createdAt
        )
    }
}

@MainActor
final class SleepAIViewModel: ObservableObject {

    enum Phase {
        case needsEULA
        case ready
        case chatting
        /// Legacy state retained for migration. The current release does
        /// not region-block the formal model.
        case regionBlocked
    }

    struct SuggestionCard {
        let text: String
        let symbol: String
        let tint: Color
    }

    // MARK: Published

    @Published var phase: Phase = .needsEULA
    @Published var messages: [SleepAIMessage] = []
    @Published var suggestions: [String] = []
    @Published var draft: String = ""
    @Published var isReplying: Bool = false

    @Published var summaryText: String = ""
    @Published private(set) var lastPerformanceMetrics: SleepAIPerformanceMetrics?

    @Published var history: [StoredChat] = []

    /// Currently selected model tier. Drives the picker badge and the
    /// underlying MLX service. Persisted across launches.
    @Published private(set) var selectedTier: SleepAIModelTier
    /// Formal model descriptor offered to the user.
    @Published private(set) var availableTiers: [SleepAIModelTier] = []
    /// True when the persisted selection is not authorised in the current
    /// region — used to drive the `.regionBlocked` phase + banner copy.
    @Published private(set) var regionBlocksSelection: Bool = false

    /// Suggestion cards rendered as a 2x2 grid on the idle screen.
    var suggestionCards: [SuggestionCard] {
        let glyphs: [String: (String, Color)] = [
            local("ai.suggestion.summarize"):   ("moon.stars",          .purple),
            local("ai.suggestion.deep"):        ("waveform.path",       .indigo),
            local("ai.suggestion.rem"):         ("eye",                 .pink),
            local("ai.suggestion.trend"):       ("chart.line.uptrend.xyaxis", .blue),
            local("ai.suggestion.factors"):     ("tag",                 .green),
            local("ai.suggestion.advice"):      ("lightbulb",           .orange),
            local("ai.suggestion.jetLag"):       ("airplane.departure",  .cyan),
            local("ai.suggestion.memory"):       ("brain.head.profile",  .mint),
            local("ai.suggestion.howItWorks"):  ("sparkles",            .blue),
            local("ai.suggestion.whatTracked"): ("heart.text.square",   .red)
        ]
        return suggestions.map { text in
            let g = glyphs[text] ?? ("sparkles", .gray)
            return SuggestionCard(text: text, symbol: g.0, tint: g.1)
        }
    }

    /// Greeting key based on current local time.
    var timeBasedGreetingKey: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12:  return "ai.hero.greeting.morning"
        case 12..<18: return "ai.hero.greeting.afternoon"
        case 18..<23: return "ai.hero.greeting.evening"
        default:      return "ai.hero.greeting.night"
        }
    }

    // MARK: Deps

    private weak var appState: AppState?
    private var service: SleepAIServiceProtocol
    /// Factory used to (re)build the LLM service on tier changes. Lets us
    /// swap models without dragging MLX types into SleepKit.
    private let serviceFactory: (SleepAIModelTier) -> SleepAIServiceProtocol

    // MARK: Persistence keys

    private static let eulaKey       = "sleep.ai.eula.accepted.v1"
    private static let historyKey    = "sleep.ai.history.v1"
    private static let activeChatKey = "sleep.ai.history.activeId.v1"
    private static let modelKey      = "sleep.ai.selectedModel.v1"     // legacy: raw SleepAIModelKind
    private static let brandKey      = "sleep.ai.selectedBrand.v1"     // current: SleepAIBrandTier

    private var activeChatId: UUID?
    private var pendingSleepPlanDraft: SleepPlanDraft?
    private var pendingProtocolCheckInPlan: SleepProtocolCheckInPlan?

    // MARK: Init

    init(serviceFactory: @escaping (SleepAIModelTier) -> SleepAIServiceProtocol = { _ in SleepAIService() }) {
        self.serviceFactory = serviceFactory

        // Resolve the single formal model. Legacy tier prefs are ignored
        // and rewritten to the formal-model identifier because the app no
        // longer exposes multiple model choices.
        let region = SleepAIRegion.current
        UserDefaults.standard.set(SleepAIBrandTier.pro.rawValue, forKey: Self.brandKey)
        UserDefaults.standard.set(SleepAIModelKind.qwenPro.rawValue, forKey: Self.modelKey)
        let tier = SleepAIModelCatalog.descriptor(for: .qwenPro, in: region)
        let bundled = SleepAIModelCatalog.available(in: region)
        let safeTier = bundled.first ?? tier
        self.selectedTier = safeTier
        self.availableTiers = bundled
        self.regionBlocksSelection = false
        self.service = serviceFactory(safeTier)
        // Initial phase honours the persisted EULA acceptance: without this
        // a fresh install would land on the empty "ready" screen instead of
        // showing the EULA gate, and the user would have to manually tap
        // "new chat" before anything appeared.
        let eulaOK = UserDefaults.standard.bool(forKey: Self.eulaKey)
        self.phase = eulaOK
            ? Self.computePhase(blocked: false, hasMessages: false)
            : .needsEULA
        loadHistory()
    }

    // MARK: Wiring

    func attach(appState: AppState) {
        self.appState = appState
    }

    func refreshContext() async {
        let ctx = await buildContext()
        summaryText = service.morningSummary(context: ctx)
        suggestions = service.suggestedFollowUps(context: ctx)
    }

    // MARK: EULA

    var eulaAccepted: Bool { UserDefaults.standard.bool(forKey: Self.eulaKey) }

    func acceptEULA() {
        UserDefaults.standard.set(true, forKey: Self.eulaKey)
        phase = computePhase()
        Task { await refreshContext() }
        // Now that the user has agreed, kick off the (large) weight load
        // in the background. Without this the user's first message after
        // accepting the EULA would still pay the multi-second cold start.
        prewarmEngine()
    }

    /// Returns localized EULA markdown text, loading the bundled file
    /// matching the user's preferred language. Falls back to English.
    func eulaMarkdown() -> String {
        let preferred = Bundle.main.preferredLocalizations.first ?? "en"
        let candidate = preferred.hasPrefix("zh") ? "EULA.zh-Hans" : "EULA.en"
        if let url = Bundle.main.url(forResource: candidate, withExtension: "md"),
           let s = try? String(contentsOf: url, encoding: .utf8) {
            return s
        }
        if let url = Bundle.main.url(forResource: "EULA.en", withExtension: "md"),
           let s = try? String(contentsOf: url, encoding: .utf8) {
            return s
        }
        return NSLocalizedString("ai.eula.short", comment: "")
    }

    // MARK: Chat

    func send(prompt rawPrompt: String) async {
        let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        guard !regionBlocksSelection else { return } // never invoke a blocked engine
        messages.append(SleepAIMessage(role: .user, text: prompt))
        isReplying = true
        if await handleSleepPlanApplyCommand(prompt: prompt) {
            isReplying = false
            if phase == .ready { phase = .chatting }
            let ctx = await buildContext()
            suggestions = service.suggestedFollowUps(context: ctx)
            persistActiveChat()
            return
        }
        let ctx = await buildContext(prompt: prompt)

        // Streaming path: append an empty assistant bubble up front, then
        // mutate its `text` as deltas arrive. The bubble's identity stays
        // stable so SwiftUI animates only the text change. On `.final` we
        // overwrite with the sanitized answer (which may differ from the
        // streamed concatenation if sanitize swapped to a fallback).
        let assistantId = UUID().uuidString
        messages.append(SleepAIMessage(id: assistantId, role: .assistant, text: ""))

        for await event in service.streamReply(to: prompt, context: ctx) {
            switch event {
            case .planDraft(let draft):
                pendingSleepPlanDraft = draft
            case .checkInPlan(let plan):
                pendingProtocolCheckInPlan = plan
            case .delta(let chunk):
                if let i = messages.firstIndex(where: { $0.id == assistantId }) {
                    messages[i].text += chunk
                }
            case .final(let full):
                if let i = messages.firstIndex(where: { $0.id == assistantId }) {
                    messages[i].text = full
                }
            case .metrics(let metrics):
                lastPerformanceMetrics = metrics
            }
        }

        isReplying = false
        if phase == .ready { phase = .chatting }
        suggestions = service.suggestedFollowUps(context: ctx)
        persistActiveChat()
    }

    /// Off-hot-path warm-up. Idempotent. Called when the AI tab actually
    /// appears so cold-start latency happens in the background instead of
    /// after the user hits Send. Rule-based service has a no-op default,
    /// so this is safe to call regardless of the active tier.
    ///
    /// We intentionally skip prewarm while the EULA gate is up: the user
    /// hasn't agreed to run the on-device model yet, and on a fresh
    /// install the prewarm would otherwise mmap ~2 GB of weights into
    /// memory before they've even seen the disclaimer — which on lower
    /// memory iPhones (no increased-memory-limit entitlement granted yet)
    /// has been observed to push the app past jetsam.
    func prewarmEngine() {
        guard phase != .needsEULA else { return }
        Task.detached(priority: .utility) { [service] in
            await service.prewarm()
        }
    }

    // MARK: History

    func startNewChat() {
        if !messages.isEmpty {
            persistActiveChat() // make sure the current one is saved
        }
        activeChatId = nil
        pendingSleepPlanDraft = nil
        pendingProtocolCheckInPlan = nil
        messages = []
        draft = ""
        phase = computePhase()
        Task { await refreshContext() }
    }

    func openChat(_ chat: StoredChat) {
        if !messages.isEmpty, activeChatId != chat.id {
            persistActiveChat()
        }
        activeChatId = chat.id
        messages = chat.messages.map { $0.toMessage() }
        phase = messages.isEmpty ? .ready : .chatting
    }

    func deleteChat(_ chat: StoredChat) {
        history.removeAll { $0.id == chat.id }
        if activeChatId == chat.id { startNewChat() }
        saveHistory()
    }

    func clearAllHistory() {
        history = []
        saveHistory()
        startNewChat()
    }

    // MARK: Internals

    private func computePhase() -> Phase {
        guard eulaAccepted else { return .needsEULA }
        return Self.computePhase(blocked: regionBlocksSelection,
                                 hasMessages: !messages.isEmpty)
    }

    /// Stateless phase computation used by both the initial constructor
    /// (before `self` is fully built) and the live recompute path.
    private static func computePhase(blocked: Bool, hasMessages: Bool) -> Phase {
        if blocked { return .regionBlocked }
        return hasMessages ? .chatting : .ready
    }

    // MARK: Model switching

    /// Legacy API retained for old call sites. The product now has one AI
    /// model, so any selection request resolves to the formal model.
    func selectBrand(_ brand: SleepAIBrandTier) {
        _ = brand
        let region = SleepAIRegion.current
        UserDefaults.standard.set(SleepAIBrandTier.pro.rawValue, forKey: Self.brandKey)
        UserDefaults.standard.set(SleepAIModelKind.qwenPro.rawValue, forKey: Self.modelKey)
        let tier = SleepAIModelCatalog.descriptor(for: .qwenPro, in: region)
        selectedTier = tier
        regionBlocksSelection = false
        service = serviceFactory(tier)
        phase = computePhase()
        Task { await refreshContext() }
    }

    /// Backwards-compatible shim. Maps a raw kind to the corresponding
    /// brand and forwards. Kept only for legacy call sites.
    func selectTier(_ kind: SleepAIModelKind) {
        _ = kind
        selectBrand(.pro)
    }

    /// Localized banner copy shown when the user's selection (or persisted
    /// state) is not authorised in the current region. Today this is the
    /// Legacy banner path; normally unused with the formal model.
    var regionBlockTitle: String { local("ai.region.blocked.title") }
    var regionBlockBody: String  { local("ai.region.blocked.body") }
    var regionBlockSwitchCTA: String { local("ai.region.blocked.switch") }

    /// Suggested fallback tier the user can tap from the banner.
    var regionFallbackTier: SleepAIModelTier {
        let region = SleepAIRegion.current
        return SleepAIModelCatalog.descriptor(
            for: SleepAIModelCatalog.defaultBrand(for: region),
            in: region
        )
    }

    private func local(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: key, table: nil)
    }

    private func persistActiveChat() {
        guard !messages.isEmpty else { return }
        if let id = activeChatId, let idx = history.firstIndex(where: { $0.id == id }) {
            history[idx].messages = messages.map(PersistableMessage.init(from:))
            history[idx].title = StoredChat.titleFrom(messages: messages)
        } else {
            let chat = StoredChat.make(from: messages)
            activeChatId = chat.id
            history.insert(chat, at: 0)
        }
        saveHistory()
    }

    private func loadHistory() {
        guard let data = UserDefaults.standard.data(forKey: Self.historyKey) else { return }
        if let decoded = try? JSONDecoder().decode([StoredChat].self, from: data) {
            history = decoded.sorted { $0.createdAt > $1.createdAt }
        }
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: Self.historyKey)
        }
    }

    private func buildContext(prompt: String? = nil) async -> SleepAIContext {
        guard let appState else { return .empty }
        let records = await recentRecords(via: appState, limit: 7)
        let activeNights = records.compactMap(Self.makeNightContext(from:))
        let passiveNights = appState.passiveNights.compactMap(Self.makeNightContext(from:))
        var nights = Self.mergeNightContexts(active: activeNights, passive: passiveNights)

        // `latestSummary` can be fresher than the async store snapshot just
        // after a session ends. Keep it in the context so the assistant never
        // answers from stale history.
        if let latest = appState.latestSummary,
           nights.first?.id != latest.sessionId {
            nights.insert(Self.makeNightContext(from: latest), at: 0)
        }
        if nights.count > 7 { nights = Array(nights.prefix(7)) }

        let weekly = Self.averageScore(nights)
        let tagInsights = Self.tagInsights(from: nights)
        let sleepPlan = appState.currentSleepPlan()
        let adaptive = await appState.adaptiveSleepModel.recommendation(currentPlan: sleepPlan)
        let adaptivePlan = adaptive.plan
        let baseContext: SleepAIContext
        if let latestNight = nights.first {
            baseContext = SleepAIContext(
                hasNight: true,
                durationSec: latestNight.durationSec,
                sleepScore: latestNight.sleepScore,
                timeInDeepSec: latestNight.timeInDeepSec,
                timeInRemSec: latestNight.timeInRemSec,
                timeInLightSec: latestNight.timeInLightSec,
                timeInWakeSec: latestNight.timeInWakeSec,
                weeklyAverageScore: weekly,
                recentNights: nights,
                tagInsights: tagInsights,
                healthAuthorization: Self.describe(appState.healthAuthorization),
                watchPaired: appState.connectivity.isPaired,
                watchReachable: appState.connectivity.isReachable,
                watchAppInstalled: appState.connectivity.isWatchAppInstalled,
                engineFallbackReason: appState.engineFallbackReason,
                inferenceFallbackReason: appState.inferenceFallbackReason,
                sleepPlanAutoTrackingEnabled: sleepPlan.autoTrackingEnabled,
                sleepPlanBedtimeMinute: Self.minuteOfDay(hour: sleepPlan.bedtimeHour,
                                                         minute: sleepPlan.bedtimeMinute),
                sleepPlanWakeMinute: Self.minuteOfDay(hour: sleepPlan.wakeHour,
                                                      minute: sleepPlan.wakeMinute),
                sleepPlanGoalMinutes: sleepPlan.sleepGoalMinutes,
                sleepPlanSmartWakeWindowMinutes: sleepPlan.smartWakeWindowMinutes,
                adaptivePlanSampleCount: adaptive.sampleCount,
                adaptivePlanConfidence: adaptive.confidence,
                adaptiveSuggestedBedtimeMinute: Self.minuteOfDay(hour: adaptivePlan.bedtimeHour,
                                                                 minute: adaptivePlan.bedtimeMinute),
                adaptiveSuggestedWakeMinute: Self.minuteOfDay(hour: adaptivePlan.wakeHour,
                                                              minute: adaptivePlan.wakeMinute),
                adaptiveSuggestedGoalMinutes: adaptivePlan.sleepGoalMinutes,
                adaptiveSuggestedSmartWakeWindowMinutes: adaptivePlan.smartWakeWindowMinutes,
                adaptivePlanReasons: adaptive.reasons
            )
        } else {
            baseContext = SleepAIContext(
                hasNight: false,
                weeklyAverageScore: weekly,
                recentNights: [],
                tagInsights: tagInsights,
                healthAuthorization: Self.describe(appState.healthAuthorization),
                watchPaired: appState.connectivity.isPaired,
                watchReachable: appState.connectivity.isReachable,
                watchAppInstalled: appState.connectivity.isWatchAppInstalled,
                engineFallbackReason: appState.engineFallbackReason,
                inferenceFallbackReason: appState.inferenceFallbackReason,
                sleepPlanAutoTrackingEnabled: sleepPlan.autoTrackingEnabled,
                sleepPlanBedtimeMinute: Self.minuteOfDay(hour: sleepPlan.bedtimeHour,
                                                         minute: sleepPlan.bedtimeMinute),
                sleepPlanWakeMinute: Self.minuteOfDay(hour: sleepPlan.wakeHour,
                                                      minute: sleepPlan.wakeMinute),
                sleepPlanGoalMinutes: sleepPlan.sleepGoalMinutes,
                sleepPlanSmartWakeWindowMinutes: sleepPlan.smartWakeWindowMinutes,
                adaptivePlanSampleCount: adaptive.sampleCount,
                adaptivePlanConfidence: adaptive.confidence,
                adaptiveSuggestedBedtimeMinute: Self.minuteOfDay(hour: adaptivePlan.bedtimeHour,
                                                                 minute: adaptivePlan.bedtimeMinute),
                adaptiveSuggestedWakeMinute: Self.minuteOfDay(hour: adaptivePlan.wakeHour,
                                                              minute: adaptivePlan.wakeMinute),
                adaptiveSuggestedGoalMinutes: adaptivePlan.sleepGoalMinutes,
                adaptiveSuggestedSmartWakeWindowMinutes: adaptivePlan.smartWakeWindowMinutes,
                adaptivePlanReasons: adaptive.reasons
            )
        }
        return baseContext.withSkillResults(SleepAISkillRunner.run(context: baseContext,
                                                                    prompt: prompt))
    }

    private func handleSleepPlanApplyCommand(prompt: String) async -> Bool {
        guard let appState else { return false }
        if SleepProtocolPlanner.isApplyCommand(prompt) {
            guard let draft = pendingSleepPlanDraft else { return false }
            appState.saveSleepPlan(draft.plan)
            if let pendingProtocolCheckInPlan {
                await appState.activateProtocolCheckInPlan(pendingProtocolCheckInPlan)
            }
            messages.append(SleepAIMessage(role: .assistant, text: Self.appliedText(for: draft.plan)))
            pendingSleepPlanDraft = nil
            pendingProtocolCheckInPlan = nil
            return true
        }
        return false
    }

    private static func appliedText(for plan: SleepPlanConfiguration) -> String {
        let bed = clock(hour: plan.bedtimeHour, minute: plan.bedtimeMinute)
        let wake = clock(hour: plan.wakeHour, minute: plan.wakeMinute)
        return "已更新睡眠计划：\(bed) 入睡，\(wake) 起床。今晚照这个执行。"
    }

    private func recentRecords(via appState: AppState, limit: Int) async -> [StoredSessionRecord] {
        let sessions = (try? await appState.localStore.listSessions(limit: limit)) ?? []
        var records: [StoredSessionRecord] = []
        for s in sessions {
            if let rec = try? await appState.localStore.record(for: s.id),
               rec.summary != nil {
                records.append(rec)
            }
        }
        return records
            .sorted { ($0.endedAt ?? $0.startedAt) > ($1.endedAt ?? $1.startedAt) }
            .prefix(limit)
            .map { $0 }
    }

    private static func makeNightContext(from record: StoredSessionRecord) -> SleepAINightContext? {
        guard let summary = record.summary else { return nil }
        let notes = firstNonEmpty(record.notes, record.survey?.note)
        let evidence = NightEvidence(record: record).assessment
        return SleepAINightContext(
            id: record.id,
            endedAt: record.endedAt,
            durationSec: summary.durationSec,
            sleepScore: summary.sleepScore,
            timeInDeepSec: summary.timeInDeepSec,
            timeInRemSec: summary.timeInRemSec,
            timeInLightSec: summary.timeInLightSec,
            timeInWakeSec: summary.timeInWakeSec,
            tags: record.tags?.filter { !$0.isEmpty } ?? [],
            noteSnippet: notes.map { truncate($0, limit: 160) },
            surveyQuality: record.survey?.quality,
            alarmFeltGood: record.survey?.alarmFeltGood,
            snoreEventCount: record.snoreEventCount,
            sourceRaw: record.sourceRaw,
            runtimeModeRaw: record.runtimeModeRaw,
            evidenceQualityRaw: evidence.quality.rawValue,
            evidenceConfidence: evidence.confidence,
            missingSignals: evidence.missingSignals.map(\.rawValue),
            isEstimated: evidence.isEstimated
        )
    }

    private static func makeNightContext(from night: PassiveSleepNight) -> SleepAINightContext? {
        let evidence = NightEvidence(passiveNight: night).assessment
        let score = SleepScoreEstimator.estimate(
            durationSec: night.durationSec,
            asleepSec: night.asleepSec,
            wakeSec: night.awakeSec,
            deepSec: night.deepSec,
            remSec: night.remSec
        )
        return SleepAINightContext(
            id: night.id,
            endedAt: night.endedAt,
            durationSec: night.durationSec,
            sleepScore: score,
            timeInDeepSec: night.deepSec,
            timeInRemSec: night.remSec,
            timeInLightSec: night.coreSec,
            timeInWakeSec: night.awakeSec,
            sourceRaw: "passiveHealthKit",
            evidenceQualityRaw: evidence.quality.rawValue,
            evidenceConfidence: evidence.confidence,
            missingSignals: evidence.missingSignals.map(\.rawValue),
            isEstimated: true
        )
    }

    private static func makeNightContext(from summary: SessionSummary) -> SleepAINightContext {
        SleepAINightContext(
            id: summary.sessionId,
            endedAt: nil,
            durationSec: summary.durationSec,
            sleepScore: summary.sleepScore,
            timeInDeepSec: summary.timeInDeepSec,
            timeInRemSec: summary.timeInRemSec,
            timeInLightSec: summary.timeInLightSec,
            timeInWakeSec: summary.timeInWakeSec
        )
    }

    private static func tagInsights(from nights: [SleepAINightContext]) -> [SleepAITagInsight] {
        let tags = Set(nights.flatMap(\.tags))
        return tags.compactMap { tag -> SleepAITagInsight? in
            let tagged = nights.filter { $0.tags.contains(tag) }.map(\.sleepScore)
            let untagged = nights.filter { !$0.tags.contains(tag) }.map(\.sleepScore)
            guard !tagged.isEmpty, !untagged.isEmpty else { return nil }
            let taggedAvg = average(tagged)
            let untaggedAvg = average(untagged)
            return SleepAITagInsight(
                tag: tag,
                count: tagged.count,
                averageScore: taggedAvg,
                comparisonAverageScore: untaggedAvg,
                scoreDelta: taggedAvg - untaggedAvg
            )
        }
        .sorted {
            if abs($0.scoreDelta) == abs($1.scoreDelta) { return $0.count > $1.count }
            return abs($0.scoreDelta) > abs($1.scoreDelta)
        }
        .prefix(5)
        .map { $0 }
    }

    private static func mergeNightContexts(active: [SleepAINightContext],
                                           passive: [SleepAINightContext]) -> [SleepAINightContext] {
        var merged: [SleepAINightContext] = []
        for night in (active + passive).sorted(by: sortNightDescending) {
            let key = nightKey(night)
            if let existing = merged.firstIndex(where: { nightKey($0) == key }) {
                let current = merged[existing]
                if current.isEstimated && !night.isEstimated {
                    merged[existing] = night
                }
            } else {
                merged.append(night)
            }
        }
        return merged
    }

    private static func sortNightDescending(_ lhs: SleepAINightContext,
                                            _ rhs: SleepAINightContext) -> Bool {
        (lhs.endedAt ?? .distantPast) > (rhs.endedAt ?? .distantPast)
    }

    private static func nightKey(_ night: SleepAINightContext) -> String {
        guard let endedAt = night.endedAt else { return night.id }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let comps = calendar.dateComponents([.year, .month, .day], from: endedAt)
        return "\(comps.year ?? 0)-\(comps.month ?? 0)-\(comps.day ?? 0)"
    }

    private static func averageScore(_ nights: [SleepAINightContext]) -> Double {
        average(nights.map(\.sleepScore))
    }

    private static func average(_ values: [Int]) -> Double {
        guard !values.isEmpty else { return 0 }
        return Double(values.reduce(0, +)) / Double(values.count)
    }

    private static func minuteOfDay(hour: Int, minute: Int) -> Int {
        (max(0, min(23, hour)) * 60) + max(0, min(59, minute))
    }

    private static func clock(hour: Int, minute: Int) -> String {
        String(format: "%02d:%02d", max(0, min(23, hour)), max(0, min(59, minute)))
    }

    private static func describe(_ status: HealthAuthorizationStatus) -> String {
        switch status {
        case .unknown: return "unknown"
        case .notDetermined: return "notDetermined"
        case .sharingDenied: return "deniedOrNoReadableData"
        case .sharingAuthorized: return "authorized"
        }
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private static func truncate(_ text: String, limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "…"
    }
}
