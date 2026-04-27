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

/// One persisted night compressed for AI grounding. This deliberately stores
/// only sleep aggregates and user-entered labels/notes; no raw sensor streams
/// or audio are included in the assistant context.
public struct SleepAINightContext: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let endedAt: Date?
    public let durationSec: Int
    public let sleepScore: Int
    public let timeInDeepSec: Int
    public let timeInRemSec: Int
    public let timeInLightSec: Int
    public let timeInWakeSec: Int
    public let tags: [String]
    public let noteSnippet: String?
    public let surveyQuality: Int?
    public let alarmFeltGood: Bool?
    public let snoreEventCount: Int?
    public let sourceRaw: String?
    public let runtimeModeRaw: String?

    public init(id: String,
                endedAt: Date? = nil,
                durationSec: Int,
                sleepScore: Int,
                timeInDeepSec: Int,
                timeInRemSec: Int,
                timeInLightSec: Int,
                timeInWakeSec: Int,
                tags: [String] = [],
                noteSnippet: String? = nil,
                surveyQuality: Int? = nil,
                alarmFeltGood: Bool? = nil,
                snoreEventCount: Int? = nil,
                sourceRaw: String? = nil,
                runtimeModeRaw: String? = nil) {
        self.id = id
        self.endedAt = endedAt
        self.durationSec = durationSec
        self.sleepScore = sleepScore
        self.timeInDeepSec = timeInDeepSec
        self.timeInRemSec = timeInRemSec
        self.timeInLightSec = timeInLightSec
        self.timeInWakeSec = timeInWakeSec
        self.tags = tags
        self.noteSnippet = noteSnippet
        self.surveyQuality = surveyQuality
        self.alarmFeltGood = alarmFeltGood
        self.snoreEventCount = snoreEventCount
        self.sourceRaw = sourceRaw
        self.runtimeModeRaw = runtimeModeRaw
    }
}

/// Lightweight correlation hint for a user tag such as caffeine or stress.
/// `scoreDelta` is tagged average minus untagged average, so negative means
/// nights with that tag tended to score lower in the local sample.
public struct SleepAITagInsight: Codable, Equatable, Sendable, Identifiable {
    public var id: String { tag }
    public let tag: String
    public let count: Int
    public let averageScore: Double
    public let comparisonAverageScore: Double
    public let scoreDelta: Double

    public init(tag: String,
                count: Int,
                averageScore: Double,
                comparisonAverageScore: Double,
                scoreDelta: Double) {
        self.tag = tag
        self.count = count
        self.averageScore = averageScore
        self.comparisonAverageScore = comparisonAverageScore
        self.scoreDelta = scoreDelta
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
    public let recentNights: [SleepAINightContext]
    public let tagInsights: [SleepAITagInsight]
    public let healthAuthorization: String?
    public let watchPaired: Bool?
    public let watchReachable: Bool?
    public let watchAppInstalled: Bool?
    public let engineFallbackReason: String?
    public let inferenceFallbackReason: String?

    public init(hasNight: Bool,
                durationSec: Int = 0,
                sleepScore: Int = 0,
                timeInDeepSec: Int = 0,
                timeInRemSec: Int = 0,
                timeInLightSec: Int = 0,
                timeInWakeSec: Int = 0,
                weeklyAverageScore: Double = 0,
                recentNights: [SleepAINightContext] = [],
                tagInsights: [SleepAITagInsight] = [],
                healthAuthorization: String? = nil,
                watchPaired: Bool? = nil,
                watchReachable: Bool? = nil,
                watchAppInstalled: Bool? = nil,
                engineFallbackReason: String? = nil,
                inferenceFallbackReason: String? = nil) {
        self.hasNight = hasNight
        self.durationSec = durationSec
        self.sleepScore = sleepScore
        self.timeInDeepSec = timeInDeepSec
        self.timeInRemSec = timeInRemSec
        self.timeInLightSec = timeInLightSec
        self.timeInWakeSec = timeInWakeSec
        self.weeklyAverageScore = weeklyAverageScore
        self.recentNights = recentNights
        self.tagInsights = tagInsights
        self.healthAuthorization = healthAuthorization
        self.watchPaired = watchPaired
        self.watchReachable = watchReachable
        self.watchAppInstalled = watchAppInstalled
        self.engineFallbackReason = engineFallbackReason
        self.inferenceFallbackReason = inferenceFallbackReason
    }

    public static let empty = SleepAIContext(hasNight: false)

    public var latestNight: SleepAINightContext? { recentNights.first }

    public var averageDurationSec: Int {
        guard !recentNights.isEmpty else { return 0 }
        let total = recentNights.reduce(0) { $0 + $1.durationSec }
        return total / recentNights.count
    }

    /// Latest score compared with the average of the older nights in the
    /// context window. Positive means the latest night improved.
    public var scoreTrendDelta: Double? {
        guard let latest = recentNights.first, recentNights.count >= 2 else { return nil }
        let older = recentNights.dropFirst().map(\.sleepScore)
        let avg = Double(older.reduce(0, +)) / Double(older.count)
        return Double(latest.sleepScore) - avg
    }

    public var strongestTagInsight: SleepAITagInsight? { tagInsights.first }

    /// True only when there is a tracked night with non-trivial duration.
    /// A 30-second start/stop test session leaves `hasNight=true` with all
    /// zero stage durations — that's not real data and the assistant must
    /// not report on it. Threshold is 5 minutes; below that we treat the
    /// context as effectively empty.
    public var hasUsableNight: Bool {
        hasNight && durationSec >= 300
    }

    /// Compact, deterministic context block for local LLM calls. The prompt
    /// explicitly says these are the only facts the model may use.
    public func llmContextPack(maxNights: Int = 7) -> String {
        var lines: [String] = []
        lines.append("CIRCADIA_LOCAL_CONTEXT")
        lines.append("Rules: use only these facts for personal claims; say data is limited when counts are small; do not diagnose.")

        if hasUsableNight {
            lines.append("Latest: duration=\(Self.formatHours(durationSec)); score=\(sleepScore); deep=\(Self.formatHours(timeInDeepSec)); REM=\(Self.formatHours(timeInRemSec)); light=\(Self.formatHours(timeInLightSec)); awake=\(Self.formatMinutes(timeInWakeSec)).")
        } else {
            lines.append("Latest: NO_NIGHT_RECORDED.")
            lines.append("If the user asks about last night, sleep score, deep/REM/wake, trends, or factors: tell them no night has been tracked yet on this device and suggest starting a session tonight. NEVER invent numbers, percentages, durations, or trends. Do not echo the user's question back as your reply.")
        }

        if weeklyAverageScore > 0 {
            lines.append(String(format: "7-night average score=%.0f.", weeklyAverageScore))
        }
        if let delta = scoreTrendDelta {
            lines.append(String(format: "Latest-vs-prior-trend delta=%+.1f score points.", delta))
        }

        if !recentNights.isEmpty {
            lines.append("Recent nights newest-first:")
            for (idx, night) in recentNights.prefix(maxNights).enumerated() {
                var parts: [String] = [
                    "#\(idx + 1)",
                    "date=\(Self.dayString(night.endedAt))",
                    "score=\(night.sleepScore)",
                    "duration=\(Self.formatHours(night.durationSec))",
                    "deep=\(Self.formatHours(night.timeInDeepSec))",
                    "REM=\(Self.formatHours(night.timeInRemSec))",
                    "awake=\(Self.formatMinutes(night.timeInWakeSec))"
                ]
                if !night.tags.isEmpty { parts.append("tags=\(night.tags.joined(separator: ","))") }
                if let q = night.surveyQuality { parts.append("surveyQuality=\(q)/5") }
                if let alarm = night.alarmFeltGood { parts.append("alarmFeltGood=\(alarm)") }
                if let snore = night.snoreEventCount { parts.append("snoreEvents=\(snore)") }
                if let note = night.noteSnippet, !note.isEmpty { parts.append("note=\"\(note)\"") }
                if let source = night.sourceRaw { parts.append("source=\(source)") }
                if let mode = night.runtimeModeRaw { parts.append("mode=\(mode)") }
                lines.append(parts.joined(separator: "; "))
            }
        }

        if !tagInsights.isEmpty {
            lines.append("Tag correlations (weak observational signals, not causation):")
            for insight in tagInsights.prefix(5) {
                lines.append(String(
                    format: "%@: n=%d; taggedAvg=%.0f; untaggedAvg=%.0f; delta=%+.1f",
                    insight.tag,
                    insight.count,
                    insight.averageScore,
                    insight.comparisonAverageScore,
                    insight.scoreDelta
                ))
            }
        }

        var status: [String] = []
        if let healthAuthorization { status.append("HealthKit=\(healthAuthorization)") }
        if let watchPaired { status.append("watchPaired=\(watchPaired)") }
        if let watchReachable { status.append("watchReachable=\(watchReachable)") }
        if let watchAppInstalled { status.append("watchAppInstalled=\(watchAppInstalled)") }
        if let engineFallbackReason { status.append("engineFallback=\(engineFallbackReason)") }
        if let inferenceFallbackReason { status.append("stageModelFallback=\(inferenceFallbackReason)") }
        if !status.isEmpty { lines.append("Data status: " + status.joined(separator: "; ")) }

        return lines.joined(separator: "\n")
    }

    private static func dayString(_ date: Date?) -> String {
        guard let date else { return "unknown" }
        let cal = Calendar(identifier: .gregorian)
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private static func formatHours(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        if h > 0 { return "\(h)h\(m)m" }
        return "\(m)m"
    }

    private static func formatMinutes(_ seconds: Int) -> String {
        "\(max(seconds / 60, 0))m"
    }
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
        guard ctx.hasUsableNight else {
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
        // Pre-flight topic gate — same behavior as the LLM-backed service
        // so simulator (rule-based fallback) and device behave identically.
        switch SleepTopicGate.classify(prompt) {
        case .refuse(let reason):
            return SleepTopicGate.refusal(for: reason)
        case .allow, .borderline:
            break
        }
        return skillReply(to: prompt, context: ctx) ?? Self.local("ai.reply.fallback")
    }

    /// Skill router used by both the rule-based service (as the body of
    /// `reply`) and the LLM-backed service (as a deterministic shortcut
    /// before invoking the model). Returns `nil` only when no skill
    /// pattern matched — callers escalate to the LLM in that case.
    public func skillReply(to prompt: String, context ctx: SleepAIContext) -> String? {
        let p = prompt.lowercased()
        let trimmed = p.trimmingCharacters(in: .whitespacesAndNewlines)

        // Single-word affirmations / fillers that have nothing to ground on.
        // Without this guard the LLM treats them as translation requests
        // ("可以" → 'I can translate "you can"…') or generic chitchat.
        // Reply with a *varied* natural line so it doesn't feel like the
        // bot is reading from a card every time.
        if Self.isTrivialFiller(trimmed) {
            return Self.fillerReply(for: trimmed, context: ctx)
        }

        // "Look at my recent sleep" family. People rarely use the word
        // "summary" in natural Chinese; they say 看 / 看看 / 最近 / 这几晚.
        if Self.matches(p, [
            "summary", "summarize", "summary?",
            "总结", "概括",
            "看一下", "看看", "看下", "瞧瞧",
            "最近", "这几晚", "这几天", "我的睡眠", "我睡眠"
        ]) {
            return morningSummary(context: ctx)
        }
        if Self.matches(p, ["deep", "深睡", "deep sleep"]) {
            guard ctx.hasUsableNight else { return Self.local("ai.reply.noNight") }
            let pct = Double(ctx.timeInDeepSec) / Double(max(ctx.durationSec, 1)) * 100
            return Self.local("ai.reply.deep")
                .replacingOccurrences(of: "{pct}", with: String(format: "%.0f", pct))
                .replacingOccurrences(of: "{dur}", with: Self.formatHours(ctx.timeInDeepSec))
        }
        if Self.matches(p, ["rem", "rapid eye"]) {
            guard ctx.hasUsableNight else { return Self.local("ai.reply.noNight") }
            let pct = Double(ctx.timeInRemSec) / Double(max(ctx.durationSec, 1)) * 100
            return Self.local("ai.reply.rem")
                .replacingOccurrences(of: "{pct}", with: String(format: "%.0f", pct))
                .replacingOccurrences(of: "{dur}", with: Self.formatHours(ctx.timeInRemSec))
        }
        if Self.matches(p, ["wake", "awake", "醒", "清醒"]) {
            guard ctx.hasUsableNight else { return Self.local("ai.reply.noNight") }
            return Self.local("ai.reply.wake")
                .replacingOccurrences(of: "{dur}", with: Self.formatMinutes(ctx.timeInWakeSec))
        }
        if Self.matches(p, ["score", "评分", "得分", "几分", "多少分", "how did i sleep"]) {
            guard ctx.hasUsableNight else { return Self.local("ai.reply.noNight") }
            return Self.local("ai.reply.score")
                .replacingOccurrences(of: "{score}", with: "\(ctx.sleepScore)")
                .replacingOccurrences(of: "{avg}", with: String(format: "%.0f", ctx.weeklyAverageScore))
        }
        if Self.matches(p, ["trend", "change", "changed", "better", "worse", "趋势", "变化", "变好", "变差"]) {
            return Self.trendReply(context: ctx, chinese: Self.isChinese(p))
        }
        if Self.matches(p, [
            "why", "affect", "factor", "caffeine", "coffee", "alcohol", "stress", "screen",
            "exercise", "late meal", "travel", "medication",
            "为什么", "原因", "影响", "咖啡", "咖啡因", "酒", "压力", "屏幕", "运动", "夜宵", "旅行", "药"
        ]) {
            return Self.tagInsightReply(context: ctx, chinese: Self.isChinese(p))
        }
        if Self.matches(p, [
            "data", "missing", "accuracy", "accurate", "healthkit", "watch", "sensor",
            "数据", "缺失", "准确", "准吗", "健康", "手表", "传感器"
        ]) {
            return Self.dataStatusReply(context: ctx, chinese: Self.isChinese(p))
        }
        if Self.matches(p, ["tip", "advice", "improve", "建议", "怎么改善", "怎么睡得", "睡得更好"]) {
            return Self.local("ai.reply.advice")
        }
        if Self.matches(p, ["how it works", "how does", "工作", "原理", "怎么工作"]) {
            return Self.local("ai.reply.howItWorks")
        }
        if Self.matches(p, ["track", "tracked", "追踪", "都追踪", "what tracked"]) {
            return Self.local("ai.reply.whatTracked")
        }
        if Self.matches(p, ["hello", "hi", "你好", "嗨", "在吗", "在不在"]) {
            return Self.local("ai.reply.hello")
        }
        // No skill matched — caller decides whether to escalate.
        return nil
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
            Self.local("ai.suggestion.trend"),
            Self.local("ai.suggestion.factors"),
            Self.local("ai.suggestion.advice")
        ]
    }

    // MARK: Helpers

    private static func matches(_ haystack: String, _ needles: [String]) -> Bool {
        for n in needles where haystack.contains(n.lowercased()) { return true }
        return false
    }

    /// One- or two-character affirmations / fillers that have no semantic
    /// content for a sleep coach to act on. Without this guard a Gemma-class
    /// model latches onto them as translation requests ("可以" → "I can
    /// translate that to English…") or generic chitchat. We answer with the
    /// canonical idle copy instead.
    static func isTrivialFiller(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return true }
        let fillers: Set<String> = [
            "可以", "好", "好的", "嗯", "哦", "对", "是", "是的", "行", "ok", "okay",
            "yes", "no", "sure", "thanks", "thx", "thank you", "谢谢", "多谢", "了解", "知道", "明白"
        ]
        if fillers.contains(t) { return true }
        // Catch single-CJK answers that aren't covered above.
        if t.unicodeScalars.count <= 2,
           t.range(of: #"\p{Han}"#, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    /// Conversational replies for one/two-word fillers. Picks from a small
    /// rotating pool so the bot doesn't sound like it's reading from the
    /// same card every time the user types "可以" or "ok". Branches on:
    ///   - thanks vs affirmative vs negative
    ///   - whether there's a usable night to talk about
    /// Stays short (one sentence, one offer) so it feels like a friend
    /// answering, not a menu.
    static func fillerReply(for text: String, context ctx: SleepAIContext) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isChinese = t.range(of: #"\p{Han}"#, options: .regularExpression) != nil

        let thanks: Set<String> = ["thanks", "thx", "thank you", "谢谢", "多谢"]
        let negatives: Set<String> = ["no", "nope", "不用", "不", "没事"]
        let isThanks = thanks.contains(t)
        let isNegative = negatives.contains(t)

        if isThanks {
            let zh = ["不客气，睡得稳是大事。", "随时找我。", "举手之劳——好梦。"]
            let en = ["Anytime — sleep well.", "Glad to help. Rest easy.", "You got it. Good night."]
            return (isChinese ? zh : en).randomElement()!
        }

        if isNegative {
            let zh = ["好嘞，那不打扰。需要的时候喊我。", "OK，先这样。"]
            let en = ["Got it — I'll be here if you change your mind.", "Sounds good, no problem."]
            return (isChinese ? zh : en).randomElement()!
        }

        // Affirmatives ("可以 / 好 / 嗯 / ok"). Offer one concrete next step,
        // grounded in whether the user actually has a night recorded.
        if ctx.hasUsableNight {
            let zh = [
                "那我先帮你看看昨晚？",
                "嗯，那从昨晚说起好不好？",
                "好，先看看你昨晚的睡眠？",
                "行——要不我先讲讲昨晚怎么样？",
            ]
            let en = [
                "Cool — want me to start with last night?",
                "Sure. Want a quick read on last night?",
                "Alright — shall I walk you through last night?",
                "Got it. Want me to look at last night first?",
            ]
            return (isChinese ? zh : en).randomElement()!
        } else {
            let zh = [
                "嗯——还没有可看的记录。今晚试一下追踪？",
                "好啊。等你跑一晚，我就能讲细节了。",
                "行。先记录一晚，明早咱们再聊？",
                "可以呀——不过得先有一晚的数据，我才好下嘴。",
            ]
            let en = [
                "Mm — nothing tracked yet. Want to try a night?",
                "Sure. Once we have a night logged I can dig in.",
                "Sounds good — track a night and I'll have something to say tomorrow.",
                "Alright — I'll need at least one night before I can be specific.",
            ]
            return (isChinese ? zh : en).randomElement()!
        }
    }

    private static func trendReply(context ctx: SleepAIContext, chinese: Bool) -> String {
        guard ctx.hasNight else {
            return chinese
                ? "还没有可比较的睡眠记录。至少记录 2 晚后，我才能看趋势。"
                : "No comparable sleep history yet. Track at least 2 nights and I can read the trend."
        }
        guard let delta = ctx.scoreTrendDelta else {
            return chinese
                ? "目前只有 1 晚记录。昨晚得分 **\(ctx.sleepScore)**；再记录几晚后趋势会更可靠。"
                : "I only have 1 tracked night. Last night scored **\(ctx.sleepScore)**; a few more nights will make trend reads more reliable."
        }
        let absDelta = abs(delta)
        let direction: String
        if absDelta < 3 {
            direction = chinese ? "基本持平" : "about flat"
        } else if delta > 0 {
            direction = chinese ? "更好" : "better"
        } else {
            direction = chinese ? "更低" : "lower"
        }

        if chinese {
            return String(
                format: "最近趋势：昨晚 **%d**，相比前几晚平均 **%@ %.1f 分**。7 晚均分是 **%.0f**。样本还少时，把它当作方向信号，不要当成结论。",
                ctx.sleepScore,
                direction,
                absDelta,
                ctx.weeklyAverageScore
            )
        }
        return String(
            format: "Trend: last night scored **%d**, **%@ by %.1f points** versus the prior nights in the local window. Your 7-night average is **%.0f**. Treat this as a directional signal, not a conclusion.",
            ctx.sleepScore,
            direction,
            absDelta,
            ctx.weeklyAverageScore
        )
    }

    private static func tagInsightReply(context ctx: SleepAIContext, chinese: Bool) -> String {
        guard ctx.hasNight else {
            return chinese
                ? "还没有睡眠记录。记录几晚并添加咖啡因、酒精、压力等标签后，我才能比较影响。"
                : "No sleep history yet. Add tags like caffeine, alcohol, or stress for a few nights and I can compare patterns."
        }
        guard let insight = ctx.strongestTagInsight else {
            return chinese
                ? "目前标签数据还不够。建议连续几晚记录咖啡因、酒精、压力、屏幕时间等标签，我会比较带标签和不带标签的夜晚。"
                : "I do not have enough tagged nights yet. Tag caffeine, alcohol, stress, or screen time for a few nights and I will compare tagged versus untagged nights."
        }

        let tag = displayTag(insight.tag, chinese: chinese)
        let caution = insight.count < 3
            ? (chinese ? "样本很少，只能当作线索。" : "The sample is small, so treat this as a clue.")
            : (chinese ? "这仍然是相关性，不代表因果。" : "This is still correlation, not causation.")
        let direction = insight.scoreDelta < 0
            ? (chinese ? "低" : "lower")
            : (chinese ? "高" : "higher")

        if chinese {
            return String(
                format: "目前最明显的线索是 **%@**：出现 %d 晚，平均分 %.0f；未出现时平均 %.0f，约%@ %.1f 分。%@",
                tag,
                insight.count,
                insight.averageScore,
                insight.comparisonAverageScore,
                direction,
                abs(insight.scoreDelta),
                caution
            )
        }
        return String(
            format: "The clearest local signal is **%@**: %d tagged nights averaged %.0f versus %.0f without it, about %.1f points %@. %@",
            tag,
            insight.count,
            insight.averageScore,
            insight.comparisonAverageScore,
            abs(insight.scoreDelta),
            direction,
            caution
        )
    }

    private static func dataStatusReply(context ctx: SleepAIContext, chinese: Bool) -> String {
        var facts: [String] = []
        if let health = ctx.healthAuthorization {
            facts.append(chinese ? "健康权限：\(health)" : "HealthKit: \(health)")
        }
        if let paired = ctx.watchPaired {
            facts.append(chinese ? "Apple Watch 配对：\(paired ? "是" : "否")" : "Watch paired: \(paired)")
        }
        if let installed = ctx.watchAppInstalled {
            facts.append(chinese ? "手表 App：\(installed ? "已安装" : "未安装")" : "Watch app installed: \(installed)")
        }
        if let reachable = ctx.watchReachable {
            facts.append(chinese ? "手表可达：\(reachable ? "是" : "否")" : "Watch reachable now: \(reachable)")
        }
        if let reason = ctx.inferenceFallbackReason {
            facts.append(chinese ? "分期模型 fallback：\(reason)" : "Stage model fallback: \(reason)")
        }
        if let reason = ctx.engineFallbackReason {
            facts.append(chinese ? "引擎 fallback：\(reason)" : "Engine fallback: \(reason)")
        }
        if facts.isEmpty {
            return chinese
                ? "我没有看到明显的数据状态问题。若阶段缺失，通常是心率、手表连接或记录时长不足。"
                : "I do not see a clear data-status issue. Missing stages usually come from sparse heart-rate, Watch connectivity, or a short recording."
        }
        let joined = facts.map { "• \($0)" }.joined(separator: "\n")
        return chinese
            ? "我能看到这些数据状态：\n\(joined)\n\n如果结果不准，优先检查 HealthKit 心率权限、手表佩戴和整晚记录时长。"
            : "Here is the current data status:\n\(joined)\n\nIf results look off, first check HealthKit heart-rate permission, Watch wear/connection, and whether the session covered the full night."
    }

    private static func displayTag(_ raw: String, chinese: Bool) -> String {
        let normalized = raw.replacingOccurrences(of: "_", with: " ")
        guard chinese else { return normalized }
        switch raw {
        case "caffeine": return "咖啡因"
        case "alcohol": return "酒精"
        case "exercise": return "运动"
        case "stress": return "压力"
        case "late_meal": return "夜宵/晚餐过晚"
        case "travel": return "旅行"
        case "medication": return "药物"
        case "screen_time": return "屏幕时间"
        default: return normalized
        }
    }

    private static func isChinese(_ text: String) -> Bool {
        text.range(of: #"\p{Han}"#, options: .regularExpression) != nil
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
