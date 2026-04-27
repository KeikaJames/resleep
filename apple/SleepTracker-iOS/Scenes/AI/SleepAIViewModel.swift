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
        switch modelStatus {
        case .installed:
            return messages.isEmpty ? .ready : .chatting
        default:
            // Even without the heavy model, the rule-based assistant is
            // available — we still gate the UI behind the (cosmetic)
            // download step so the product story matches the user's
            // mental model. Skipping download is one step away.
            return .needsModel
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
