import Foundation
import SwiftUI
import SleepKit

@MainActor
final class SleepAIViewModel: ObservableObject {

    enum Phase {
        case needsConsent
        case needsModel
        case ready
        case chatting
    }

    struct SuggestionCard {
        let text: String
        let symbol: String
        let tint: Color
    }

    // MARK: Published

    @Published var phase: Phase = .needsConsent
    @Published var messages: [SleepAIMessage] = []
    @Published var suggestions: [String] = []
    @Published var draft: String = ""
    @Published var isReplying: Bool = false

    @Published var modelStatus: SleepAIModelStatus = .notInstalled
    @Published private(set) var modelDescriptor: SleepAIModelDescriptor =
        SleepAIModelManager.defaultDescriptor

    @Published var summaryText: String = ""

    /// Suggestion cards rendered as a 2x2 grid on the idle screen.
    var suggestionCards: [SuggestionCard] {
        let glyphs: [String: (String, Color)] = [
            local("ai.suggestion.summarize"):  ("moon.stars",                .purple),
            local("ai.suggestion.deep"):       ("waveform.path",             .indigo),
            local("ai.suggestion.rem"):        ("eye",                       .pink),
            local("ai.suggestion.advice"):     ("lightbulb",                 .orange),
            local("ai.suggestion.howItWorks"): ("sparkles",                  .blue),
            local("ai.suggestion.whatTracked"):("heart.text.square",         .red)
        ]
        return suggestions.map { text in
            let g = glyphs[text] ?? ("sparkles", .gray)
            return SuggestionCard(text: text, symbol: g.0, tint: g.1)
        }
    }

    /// Picks a greeting key based on current local time. Mirrors the
    /// Apple Intelligence "Good morning / afternoon / evening" feel.
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
    private let service: SleepAIServiceProtocol
    private let modelManager: SleepAIModelManager
    private var statusObservation: Task<Void, Never>?

    // MARK: Persistence keys

    private static let consentKey   = "sleep.ai.consent.granted"

    // MARK: Init

    init(service: SleepAIServiceProtocol = SleepAIService(),
         modelManager: SleepAIModelManager? = nil) {
        self.service = service
        let mm = modelManager ?? SleepAIModelManager()
        self.modelManager = mm
        self.modelStatus = mm.status
        self.modelDescriptor = mm.descriptor
        self.phase = computePhase()
        // Mirror manager status into our @Published so the view re-renders.
        statusObservation = Task { [weak self] in
            guard let self else { return }
            // Naive polling — manager exposes @Published but it's MainActor;
            // Combine bridging would also work. Polling is fine for a small,
            // foreground-only sheet.
            while !Task.isCancelled {
                let st = self.modelManager.status
                if self.modelStatus != st {
                    self.modelStatus = st
                    self.phase = self.computePhase()
                }
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }
    }

    deinit { statusObservation?.cancel() }

    // MARK: Wiring

    func attach(appState: AppState) {
        self.appState = appState
    }

    func refreshContext() async {
        let ctx = await buildContext()
        summaryText = service.morningSummary(context: ctx)
        suggestions = service.suggestedFollowUps(context: ctx)
    }

    // MARK: Consent / model

    func grantConsent() {
        UserDefaults.standard.set(true, forKey: Self.consentKey)
        phase = computePhase()
        Task { await refreshContext() }
    }

    func resetChat() {
        messages = []
        draft = ""
        phase = computePhase()
        Task { await refreshContext() }
    }

    func startDownload() { modelManager.startDownload() }
    func cancelDownload() { modelManager.cancelDownload() }

    // MARK: Chat

    func send(prompt rawPrompt: String) async {
        let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        messages.append(SleepAIMessage(role: .user, text: prompt))
        isReplying = true
        let ctx = await buildContext()
        let reply = await service.reply(to: prompt, context: ctx)
        // Tiny delay so the typing indicator is visible — purely cosmetic.
        try? await Task.sleep(nanoseconds: 250_000_000)
        messages.append(SleepAIMessage(role: .assistant, text: reply))
        isReplying = false
        if phase == .ready { phase = .chatting }
        suggestions = service.suggestedFollowUps(context: ctx)
    }

    // MARK: Internals

    private func computePhase() -> Phase {
        let consented = UserDefaults.standard.bool(forKey: Self.consentKey)
        guard consented else { return .needsConsent }
        // Lightweight rule-based assistant is always available — model
        // download is a separate, optional Settings concern.
        return messages.isEmpty ? .ready : .chatting
    }

    private func local(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: key, table: nil)
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
