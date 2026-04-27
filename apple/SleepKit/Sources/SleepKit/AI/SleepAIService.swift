import Foundation

// MARK: - Public types

/// One turn in a SleepAI conversation. Roles are kept narrow on purpose —
/// system messages live separately in `SleepAISession.systemPreamble`.
public struct SleepAIMessage: Identifiable, Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable { case user, assistant }

    public let id: String
    public let role: Role
    public let text: String
    public let createdAt: Date

    public init(id: String = UUID().uuidString,
                role: Role,
                text: String,
                createdAt: Date = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
    }
}

/// A short, structured summary of the user's most recent night, suitable
/// either for direct display or as part of an LLM prompt context window.
public struct SleepAIContext: Sendable, Equatable {
    public let hasNight: Bool
    public let durationSec: Int
    public let sleepScore: Int
    public let timeInDeepSec: Int
    public let timeInRemSec: Int
    public let timeInLightSec: Int
    public let timeInWakeSec: Int
    public let weeklyAverageScore: Double

    public init(hasNight: Bool,
                durationSec: Int = 0,
                sleepScore: Int = 0,
                timeInDeepSec: Int = 0,
                timeInRemSec: Int = 0,
                timeInLightSec: Int = 0,
                timeInWakeSec: Int = 0,
                weeklyAverageScore: Double = 0) {
        self.hasNight = hasNight
        self.durationSec = durationSec
        self.sleepScore = sleepScore
        self.timeInDeepSec = timeInDeepSec
        self.timeInRemSec = timeInRemSec
        self.timeInLightSec = timeInLightSec
        self.timeInWakeSec = timeInWakeSec
        self.weeklyAverageScore = weeklyAverageScore
    }

    public static let empty = SleepAIContext(hasNight: false)
}

// MARK: - Service protocol

/// Local Sleep AI assistant. Today's default implementation is a
/// **rule-based, on-device template responder** — it's honest about that
/// in `engineKind`. When the real Gemma weights land, a second
/// implementation can replace the template path without touching UI.
///
/// Everything runs on-device; no network calls beyond model download.
public protocol SleepAIServiceProtocol: AnyObject, Sendable {
    var engineKind: SleepAIEngineKind { get }

    /// Synchronous, deterministic morning summary built from the user's
    /// latest stored night. Used as the canonical "one tap" assistant
    /// experience; never mutates state.
    func morningSummary(context: SleepAIContext) -> String

    /// Conversational reply to a free-form user prompt. The default
    /// rule-based engine pattern-matches against the prompt + uses
    /// `context` to fill in values.
    func reply(to prompt: String, context: SleepAIContext) async -> String

    /// Suggestions for canned follow-up taps the UI can offer the user.
    func suggestedFollowUps(context: SleepAIContext) -> [String]
}

public enum SleepAIEngineKind: String, Sendable, Codable, Equatable {
    /// On-device rule-based assistant. Always available, ships zero weights.
    case ruleBased
    /// On-device Gemma weights (downloaded). Not yet wired — placeholder.
    case gemmaLocal
}

// MARK: - Default rule-based service

public final class SleepAIService: SleepAIServiceProtocol, @unchecked Sendable {

    public init() {}

    public var engineKind: SleepAIEngineKind { .ruleBased }

    public func morningSummary(context ctx: SleepAIContext) -> String {
        guard ctx.hasNight else {
            return Self.local("ai.summary.empty")
        }
        let durStr = Self.formatHours(ctx.durationSec)
        let deepStr = Self.formatHours(ctx.timeInDeepSec)
        let remStr  = Self.formatHours(ctx.timeInRemSec)
        let wakeStr = Self.formatMinutes(ctx.timeInWakeSec)

        let template = Self.local("ai.summary.template")
        var body = template
            .replacingOccurrences(of: "{duration}", with: durStr)
            .replacingOccurrences(of: "{score}", with: "\(ctx.sleepScore)")
            .replacingOccurrences(of: "{deep}", with: deepStr)
            .replacingOccurrences(of: "{rem}", with: remStr)
            .replacingOccurrences(of: "{wake}", with: wakeStr)

        // Tail: comparative line vs weekly average if we have one
        if ctx.weeklyAverageScore > 0 {
            let delta = Double(ctx.sleepScore) - ctx.weeklyAverageScore
            let tailKey: String
            if delta >= 5 {
                tailKey = "ai.summary.tail.better"
            } else if delta <= -5 {
                tailKey = "ai.summary.tail.worse"
            } else {
                tailKey = "ai.summary.tail.same"
            }
            body += "\n\n" + Self.local(tailKey)
                .replacingOccurrences(of: "{avg}", with: String(format: "%.0f", ctx.weeklyAverageScore))
        }
        return body
    }

    public func reply(to prompt: String, context ctx: SleepAIContext) async -> String {
        // Rule pattern — very small intent classifier. Localized output
        // strings live in the host bundle.
        let p = prompt.lowercased()

        if Self.matches(p, ["summary", "summarize", "总结", "概括", "summary?"]) {
            return morningSummary(context: ctx)
        }
        if Self.matches(p, ["deep", "深睡", "deep sleep"]) {
            guard ctx.hasNight else { return Self.local("ai.reply.noNight") }
            let pct = Double(ctx.timeInDeepSec) / Double(max(ctx.durationSec, 1)) * 100
            return Self.local("ai.reply.deep")
                .replacingOccurrences(of: "{pct}", with: String(format: "%.0f", pct))
                .replacingOccurrences(of: "{dur}", with: Self.formatHours(ctx.timeInDeepSec))
        }
        if Self.matches(p, ["rem", "rapid eye"]) {
            guard ctx.hasNight else { return Self.local("ai.reply.noNight") }
            let pct = Double(ctx.timeInRemSec) / Double(max(ctx.durationSec, 1)) * 100
            return Self.local("ai.reply.rem")
                .replacingOccurrences(of: "{pct}", with: String(format: "%.0f", pct))
                .replacingOccurrences(of: "{dur}", with: Self.formatHours(ctx.timeInRemSec))
        }
        if Self.matches(p, ["wake", "awake", "醒", "清醒"]) {
            guard ctx.hasNight else { return Self.local("ai.reply.noNight") }
            return Self.local("ai.reply.wake")
                .replacingOccurrences(of: "{dur}", with: Self.formatMinutes(ctx.timeInWakeSec))
        }
        if Self.matches(p, ["score", "评分", "得分", "how did i sleep"]) {
            guard ctx.hasNight else { return Self.local("ai.reply.noNight") }
            return Self.local("ai.reply.score")
                .replacingOccurrences(of: "{score}", with: "\(ctx.sleepScore)")
                .replacingOccurrences(of: "{avg}", with: String(format: "%.0f", ctx.weeklyAverageScore))
        }
        if Self.matches(p, ["tip", "advice", "improve", "建议", "怎么改善"]) {
            return Self.local("ai.reply.advice")
        }
        if Self.matches(p, ["how it works", "how does", "工作", "原理", "怎么工作"]) {
            return Self.local("ai.reply.howItWorks")
        }
        if Self.matches(p, ["track", "tracked", "追踪", "都追踪", "what tracked"]) {
            return Self.local("ai.reply.whatTracked")
        }
        if Self.matches(p, ["hello", "hi", "你好", "嗨"]) {
            return Self.local("ai.reply.hello")
        }
        // Fallback
        return Self.local("ai.reply.fallback")
    }

    public func suggestedFollowUps(context ctx: SleepAIContext) -> [String] {
        if !ctx.hasNight {
            return [
                Self.local("ai.suggestion.howItWorks"),
                Self.local("ai.suggestion.whatTracked"),
                Self.local("ai.suggestion.advice")
            ]
        }
        return [
            Self.local("ai.suggestion.summarize"),
            Self.local("ai.suggestion.deep"),
            Self.local("ai.suggestion.rem"),
            Self.local("ai.suggestion.advice")
        ]
    }

    // MARK: Helpers

    private static func matches(_ haystack: String, _ needles: [String]) -> Bool {
        for n in needles where haystack.contains(n.lowercased()) { return true }
        return false
    }

    private static func formatHours(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    private static func formatMinutes(_ seconds: Int) -> String {
        let m = max(seconds / 60, 0)
        return "\(m)m"
    }

    private static func local(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: key, table: nil)
    }
}
