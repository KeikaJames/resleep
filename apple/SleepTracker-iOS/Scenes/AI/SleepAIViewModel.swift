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
        self.selectedTier = tier
        self.availableTiers = SleepAIModelCatalog.available(in: region)
        // With the brand-tier model the picker is region-stable: Instant /
        // Pro both exist everywhere, so a persisted selection can never be
        // out of region.
        self.regionBlocksSelection = false
        self.service = serviceFactory(tier)
        self.phase = Self.computePhase(blocked: false, hasMessages: false)
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
        let summary = appState.latestSummary
        let weekly = await weeklyAverageScore(via: appState)
        guard let s = summary else {
            return SleepAIContext(hasNight: false, weeklyAverageScore: weekly)
        }
        return SleepAIContext(
            hasNight: true,
            durationSec: s.durationSec,
            sleepScore: s.sleepScore,
            timeInDeepSec: s.timeInDeepSec,
            timeInRemSec: s.timeInRemSec,
            timeInLightSec: s.timeInLightSec,
            timeInWakeSec: s.timeInWakeSec,
            weeklyAverageScore: weekly
        )
    }

    private func weeklyAverageScore(via appState: AppState) async -> Double {
        let sessions = (try? await appState.localStore.listSessions(limit: 7)) ?? []
        var scores: [Int] = []
        for s in sessions {
            if let sm = try? await appState.localStore.summary(for: s.id) {
                scores.append(sm.sleepScore)
            }
        }
        guard !scores.isEmpty else { return 0 }
        return Double(scores.reduce(0, +)) / Double(scores.count)
    }
}
