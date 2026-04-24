import Foundation

/// Local-only trend analysis + rule-based suggestions. Everything here runs
/// on-device — no network calls, no identifiers beyond the opaque user id.
public protocol LocalInsightsServiceProtocol: Sendable {
    func weeklyAverageScore(summaries: [SessionSummary]) -> Double
    func suggestions(from summary: SessionSummary) -> [Suggestion]
}

public struct Suggestion: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let detail: String
    public init(id: String = UUID().uuidString, title: String, detail: String) {
        self.id = id
        self.title = title
        self.detail = detail
    }
}

public final class LocalInsightsService: LocalInsightsServiceProtocol, @unchecked Sendable {
    public init() {}

    public func weeklyAverageScore(summaries: [SessionSummary]) -> Double {
        guard !summaries.isEmpty else { return 0 }
        let total = summaries.reduce(0) { $0 + $1.sleepScore }
        return Double(total) / Double(summaries.count)
    }

    public func suggestions(from summary: SessionSummary) -> [Suggestion] {
        var out: [Suggestion] = []
        if summary.durationSec < 6 * 3600 {
            out.append(Suggestion(title: "Aim for 7–8h",
                                  detail: "Last night you slept under 6h. Try an earlier bedtime tonight."))
        }
        let deepRatio = Double(summary.timeInDeepSec) / Double(max(summary.durationSec, 1))
        if deepRatio < 0.12 {
            out.append(Suggestion(title: "Low deep sleep",
                                  detail: "Deep sleep was under 12%. Avoid late caffeine and screens."))
        }
        let wakeRatio = Double(summary.timeInWakeSec) / Double(max(summary.durationSec, 1))
        if wakeRatio > 0.15 {
            out.append(Suggestion(title: "Restless night",
                                  detail: "Awake time was above 15%. Keep the room cool and dark."))
        }
        return out
    }
}
