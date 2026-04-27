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
            out.append(Suggestion(
                id: "duration.short",
                title: Self.local("insight.duration.short.title"),
                detail: Self.local("insight.duration.short.detail")))
        }
        let deepRatio = Double(summary.timeInDeepSec) / Double(max(summary.durationSec, 1))
        if deepRatio < 0.12 {
            out.append(Suggestion(
                id: "deep.low",
                title: Self.local("insight.deep.low.title"),
                detail: Self.local("insight.deep.low.detail")))
        }
        let wakeRatio = Double(summary.timeInWakeSec) / Double(max(summary.durationSec, 1))
        if wakeRatio > 0.15 {
            out.append(Suggestion(
                id: "wake.high",
                title: Self.local("insight.wake.high.title"),
                detail: Self.local("insight.wake.high.detail")))
        }
        return out
    }

    /// Looks up a localized string from the running app's bundle. The
    /// SleepKit package itself ships no `.strings` file — strings live
    /// in the iOS / watchOS app bundle that imports SleepKit.
    private static func local(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: key, table: nil)
    }
}
