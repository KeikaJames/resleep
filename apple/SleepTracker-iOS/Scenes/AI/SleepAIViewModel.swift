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
        /// Region forbids the currently selected model (e.g. Gemma in
        /// Mainland China). Composer is hidden and a banner explains it.
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

    @Published var history: [StoredChat] = []

    /// Currently selected model tier. Drives the picker badge and the
    /// underlying MLX service. Persisted across launches.
    @Published private(set) var selectedTier: SleepAIModelTier
    /// All tiers offered to the user *in this region*. Hides Gemma in
    /// Mainland China.
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

    // MARK: Init

    init(serviceFactory: @escaping (SleepAIModelTier) -> SleepAIServiceProtocol = { _ in SleepAIService() }) {
        self.serviceFactory = serviceFactory

        // Resolve the user's preferred brand tier. Persistence migrated:
        // first prefer a stored brand tier, then fall back to a stored raw
        // model kind (legacy, pre-brand-tier installs), then default.
        let region = SleepAIRegion.current
        let storedBrand = UserDefaults.standard.string(forKey: Self.brandKey)
            .flatMap(SleepAIBrandTier.init(rawValue:))
        let legacyKind = UserDefaults.standard.string(forKey: Self.modelKey)
            .flatMap(SleepAIModelKind.init(rawValue:))
        let resolvedBrand: SleepAIBrandTier = {
            if let b = storedBrand { return b }
            if let k = legacyKind {
                return k == .qwenPro ? .pro : .instant
            }
            return SleepAIModelCatalog.defaultBrand(for: region)
        }()
        let tier = SleepAIModelCatalog.descriptor(for: resolvedBrand, in: region)
        let bundled = SleepAIModelCatalog.available(in: region)
        // If the persisted brand's weights are no longer in the bundle
        // (e.g. user picked Pro on a build that didn't ship Pro weights,
        // or the App Store build dropped a tier to stay under 4 GB), fall
        // back to the first available tier instead of erroring on first
        // message with `notFound(...)`.
        let safeTier: SleepAIModelTier = {
            if bundled.contains(where: { $0.brand == tier.brand }) { return tier }
            return bundled.first ?? tier
        }()
        self.selectedTier = safeTier
        self.availableTiers = bundled
        // With the brand-tier model the picker is region-stable: Instant /
        // Pro both exist everywhere, so a persisted selection can never be
        // out of region.
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
        let ctx = await buildContext()
        let reply = await service.reply(to: prompt, context: ctx)
        try? await Task.sleep(nanoseconds: 250_000_000)
        messages.append(SleepAIMessage(role: .assistant, text: reply))
        isReplying = false
        if phase == .ready { phase = .chatting }
        suggestions = service.suggestedFollowUps(context: ctx)
        persistActiveChat()
    }

    // MARK: History

    func startNewChat() {
        if !messages.isEmpty {
            persistActiveChat() // make sure the current one is saved
        }
        activeChatId = nil
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

    /// User-driven model swap from the picker. Persists the choice, drops
    /// any cached LLM state. The brand tier is region-stable, so no region
    /// guard is required.
    func selectBrand(_ brand: SleepAIBrandTier) {
        let region = SleepAIRegion.current
        UserDefaults.standard.set(brand.rawValue, forKey: Self.brandKey)
        // Keep the legacy kind key in sync so older code paths that still
        // read `modelKey` see a consistent value.
        let kind = SleepAIModelCatalog.kind(for: brand, in: region)
        UserDefaults.standard.set(kind.rawValue, forKey: Self.modelKey)
        let tier = SleepAIModelCatalog.descriptor(for: brand, in: region)
        selectedTier = tier
        regionBlocksSelection = false
        service = serviceFactory(tier)
        phase = computePhase()
        Task { await refreshContext() }
    }

    /// Backwards-compatible shim. Maps a raw kind to the corresponding
    /// brand and forwards. Kept only for legacy call sites.
    func selectTier(_ kind: SleepAIModelKind) {
        selectBrand(kind == .qwenPro ? .pro : .instant)
    }

    /// Localized banner copy shown when the user's selection (or persisted
    /// state) is not authorised in the current region. Today this is the
    /// Gemma-in-Mainland-China case.
    var regionBlockTitle: String { local("ai.region.blocked.title") }
    var regionBlockBody: String  { local("ai.region.blocked.body") }
    var regionBlockSwitchCTA: String { local("ai.region.blocked.switch") }

    /// Suggested fallback tier the user can tap from the banner. With the
    /// brand-tier model this is always Instant in the current region.
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

    private func buildContext() async -> SleepAIContext {
        guard let appState else { return .empty }
        let records = await recentRecords(via: appState, limit: 7)
        var nights = records.compactMap(Self.makeNightContext(from:))

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
        guard let latestNight = nights.first else {
            return SleepAIContext(
                hasNight: false,
                weeklyAverageScore: weekly,
                recentNights: [],
                tagInsights: tagInsights,
                healthAuthorization: Self.describe(appState.healthAuthorization),
                watchPaired: appState.connectivity.isPaired,
                watchReachable: appState.connectivity.isReachable,
                watchAppInstalled: appState.connectivity.isWatchAppInstalled,
                engineFallbackReason: appState.engineFallbackReason,
                inferenceFallbackReason: appState.inferenceFallbackReason
            )
        }
        return SleepAIContext(
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
            inferenceFallbackReason: appState.inferenceFallbackReason
        )
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
            runtimeModeRaw: record.runtimeModeRaw
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

    private static func averageScore(_ nights: [SleepAINightContext]) -> Double {
        average(nights.map(\.sleepScore))
    }

    private static func average(_ values: [Int]) -> Double {
        guard !values.isEmpty else { return 0 }
        return Double(values.reduce(0, +)) / Double(values.count)
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
