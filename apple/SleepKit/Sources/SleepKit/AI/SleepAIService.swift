import Foundation

// MARK: - Public types

/// One turn in a SleepAI conversation. Roles are kept narrow on purpose —
/// system messages live separately in `SleepAISession.systemPreamble`.
public struct SleepAIMessage: Identifiable, Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable { case user, assistant }

    public let id: String
    public let role: Role
    public var text: String
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
    public let evidenceQualityRaw: String?
    public let evidenceConfidence: Double?
    public let missingSignals: [String]
    public let isEstimated: Bool

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
                runtimeModeRaw: String? = nil,
                evidenceQualityRaw: String? = nil,
                evidenceConfidence: Double? = nil,
                missingSignals: [String] = [],
                isEstimated: Bool = false) {
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
        self.evidenceQualityRaw = evidenceQualityRaw
        self.evidenceConfidence = evidenceConfidence
        self.missingSignals = missingSignals
        self.isEstimated = isEstimated
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case endedAt
        case durationSec
        case sleepScore
        case timeInDeepSec
        case timeInRemSec
        case timeInLightSec
        case timeInWakeSec
        case tags
        case noteSnippet
        case surveyQuality
        case alarmFeltGood
        case snoreEventCount
        case sourceRaw
        case runtimeModeRaw
        case evidenceQualityRaw
        case evidenceConfidence
        case missingSignals
        case isEstimated
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        self.durationSec = try c.decode(Int.self, forKey: .durationSec)
        self.sleepScore = try c.decode(Int.self, forKey: .sleepScore)
        self.timeInDeepSec = try c.decode(Int.self, forKey: .timeInDeepSec)
        self.timeInRemSec = try c.decode(Int.self, forKey: .timeInRemSec)
        self.timeInLightSec = try c.decode(Int.self, forKey: .timeInLightSec)
        self.timeInWakeSec = try c.decode(Int.self, forKey: .timeInWakeSec)
        self.tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        self.noteSnippet = try c.decodeIfPresent(String.self, forKey: .noteSnippet)
        self.surveyQuality = try c.decodeIfPresent(Int.self, forKey: .surveyQuality)
        self.alarmFeltGood = try c.decodeIfPresent(Bool.self, forKey: .alarmFeltGood)
        self.snoreEventCount = try c.decodeIfPresent(Int.self, forKey: .snoreEventCount)
        self.sourceRaw = try c.decodeIfPresent(String.self, forKey: .sourceRaw)
        self.runtimeModeRaw = try c.decodeIfPresent(String.self, forKey: .runtimeModeRaw)
        self.evidenceQualityRaw = try c.decodeIfPresent(String.self, forKey: .evidenceQualityRaw)
        self.evidenceConfidence = try c.decodeIfPresent(Double.self, forKey: .evidenceConfidence)
        self.missingSignals = try c.decodeIfPresent([String].self, forKey: .missingSignals) ?? []
        self.isEstimated = try c.decodeIfPresent(Bool.self, forKey: .isEstimated) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(endedAt, forKey: .endedAt)
        try c.encode(durationSec, forKey: .durationSec)
        try c.encode(sleepScore, forKey: .sleepScore)
        try c.encode(timeInDeepSec, forKey: .timeInDeepSec)
        try c.encode(timeInRemSec, forKey: .timeInRemSec)
        try c.encode(timeInLightSec, forKey: .timeInLightSec)
        try c.encode(timeInWakeSec, forKey: .timeInWakeSec)
        try c.encode(tags, forKey: .tags)
        try c.encodeIfPresent(noteSnippet, forKey: .noteSnippet)
        try c.encodeIfPresent(surveyQuality, forKey: .surveyQuality)
        try c.encodeIfPresent(alarmFeltGood, forKey: .alarmFeltGood)
        try c.encodeIfPresent(snoreEventCount, forKey: .snoreEventCount)
        try c.encodeIfPresent(sourceRaw, forKey: .sourceRaw)
        try c.encodeIfPresent(runtimeModeRaw, forKey: .runtimeModeRaw)
        try c.encodeIfPresent(evidenceQualityRaw, forKey: .evidenceQualityRaw)
        try c.encodeIfPresent(evidenceConfidence, forKey: .evidenceConfidence)
        try c.encode(missingSignals, forKey: .missingSignals)
        try c.encode(isEstimated, forKey: .isEstimated)
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
    public let sleepPlanAutoTrackingEnabled: Bool?
    public let sleepPlanBedtimeMinute: Int?
    public let sleepPlanWakeMinute: Int?
    public let sleepPlanGoalMinutes: Int?
    public let sleepPlanSmartWakeWindowMinutes: Int?
    public let adaptivePlanSampleCount: Int
    public let adaptivePlanConfidence: Double?
    public let adaptiveSuggestedBedtimeMinute: Int?
    public let adaptiveSuggestedWakeMinute: Int?
    public let adaptiveSuggestedGoalMinutes: Int?
    public let adaptiveSuggestedSmartWakeWindowMinutes: Int?
    public let adaptivePlanReasons: [String]
    public let skillResults: [SleepAISkillResult]

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
                inferenceFallbackReason: String? = nil,
                sleepPlanAutoTrackingEnabled: Bool? = nil,
                sleepPlanBedtimeMinute: Int? = nil,
                sleepPlanWakeMinute: Int? = nil,
                sleepPlanGoalMinutes: Int? = nil,
                sleepPlanSmartWakeWindowMinutes: Int? = nil,
                adaptivePlanSampleCount: Int = 0,
                adaptivePlanConfidence: Double? = nil,
                adaptiveSuggestedBedtimeMinute: Int? = nil,
                adaptiveSuggestedWakeMinute: Int? = nil,
                adaptiveSuggestedGoalMinutes: Int? = nil,
                adaptiveSuggestedSmartWakeWindowMinutes: Int? = nil,
                adaptivePlanReasons: [String] = [],
                skillResults: [SleepAISkillResult] = []) {
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
        self.sleepPlanAutoTrackingEnabled = sleepPlanAutoTrackingEnabled
        self.sleepPlanBedtimeMinute = sleepPlanBedtimeMinute
        self.sleepPlanWakeMinute = sleepPlanWakeMinute
        self.sleepPlanGoalMinutes = sleepPlanGoalMinutes
        self.sleepPlanSmartWakeWindowMinutes = sleepPlanSmartWakeWindowMinutes
        self.adaptivePlanSampleCount = max(0, adaptivePlanSampleCount)
        self.adaptivePlanConfidence = adaptivePlanConfidence.map { min(max($0, 0), 1) }
        self.adaptiveSuggestedBedtimeMinute = adaptiveSuggestedBedtimeMinute
        self.adaptiveSuggestedWakeMinute = adaptiveSuggestedWakeMinute
        self.adaptiveSuggestedGoalMinutes = adaptiveSuggestedGoalMinutes
        self.adaptiveSuggestedSmartWakeWindowMinutes = adaptiveSuggestedSmartWakeWindowMinutes
        self.adaptivePlanReasons = adaptivePlanReasons
        self.skillResults = skillResults
    }

    public static let empty = SleepAIContext(hasNight: false)

    public var latestNight: SleepAINightContext? { recentNights.first }

    public var currentSleepPlanConfiguration: SleepPlanConfiguration {
        SleepPlanConfiguration(
            autoTrackingEnabled: sleepPlanAutoTrackingEnabled ?? SleepPlanConfiguration.default.autoTrackingEnabled,
            bedtimeHour: (sleepPlanBedtimeMinute ?? SleepPlanConfiguration.default.bedtimeHour * 60) / 60,
            bedtimeMinute: (sleepPlanBedtimeMinute ?? SleepPlanConfiguration.default.bedtimeMinute) % 60,
            wakeHour: (sleepPlanWakeMinute ?? SleepPlanConfiguration.default.wakeHour * 60) / 60,
            wakeMinute: (sleepPlanWakeMinute ?? SleepPlanConfiguration.default.wakeMinute) % 60,
            sleepGoalMinutes: sleepPlanGoalMinutes ?? SleepPlanConfiguration.default.sleepGoalMinutes,
            smartWakeWindowMinutes: sleepPlanSmartWakeWindowMinutes
                ?? SleepPlanConfiguration.default.smartWakeWindowMinutes,
            nightmareWakeEnabled: SleepPlanConfiguration.default.nightmareWakeEnabled
        )
    }

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

    public func withSkillResults(_ skillResults: [SleepAISkillResult]) -> SleepAIContext {
        SleepAIContext(
            hasNight: hasNight,
            durationSec: durationSec,
            sleepScore: sleepScore,
            timeInDeepSec: timeInDeepSec,
            timeInRemSec: timeInRemSec,
            timeInLightSec: timeInLightSec,
            timeInWakeSec: timeInWakeSec,
            weeklyAverageScore: weeklyAverageScore,
            recentNights: recentNights,
            tagInsights: tagInsights,
            healthAuthorization: healthAuthorization,
            watchPaired: watchPaired,
            watchReachable: watchReachable,
            watchAppInstalled: watchAppInstalled,
            engineFallbackReason: engineFallbackReason,
            inferenceFallbackReason: inferenceFallbackReason,
            sleepPlanAutoTrackingEnabled: sleepPlanAutoTrackingEnabled,
            sleepPlanBedtimeMinute: sleepPlanBedtimeMinute,
            sleepPlanWakeMinute: sleepPlanWakeMinute,
            sleepPlanGoalMinutes: sleepPlanGoalMinutes,
            sleepPlanSmartWakeWindowMinutes: sleepPlanSmartWakeWindowMinutes,
            adaptivePlanSampleCount: adaptivePlanSampleCount,
            adaptivePlanConfidence: adaptivePlanConfidence,
            adaptiveSuggestedBedtimeMinute: adaptiveSuggestedBedtimeMinute,
            adaptiveSuggestedWakeMinute: adaptiveSuggestedWakeMinute,
            adaptiveSuggestedGoalMinutes: adaptiveSuggestedGoalMinutes,
            adaptiveSuggestedSmartWakeWindowMinutes: adaptiveSuggestedSmartWakeWindowMinutes,
            adaptivePlanReasons: adaptivePlanReasons,
            skillResults: skillResults
        )
    }

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
            var latest = "Latest: duration=\(Self.formatHours(durationSec)); score=\(sleepScore); deep=\(Self.formatHours(timeInDeepSec)); REM=\(Self.formatHours(timeInRemSec)); light=\(Self.formatHours(timeInLightSec)); awake=\(Self.formatMinutes(timeInWakeSec))"
            if let night = latestNight {
                if let quality = night.evidenceQualityRaw {
                    latest += "; dataQuality=\(quality)"
                }
                if let confidence = night.evidenceConfidence {
                    latest += "; confidence=\(Self.formatPercent(confidence))"
                }
                if night.isEstimated {
                    latest += "; estimated=true"
                }
                if !night.missingSignals.isEmpty {
                    latest += "; missingSignals=\(night.missingSignals.joined(separator: ","))"
                }
            }
            lines.append(latest + ".")
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
                if let quality = night.evidenceQualityRaw { parts.append("dataQuality=\(quality)") }
                if let confidence = night.evidenceConfidence { parts.append("confidence=\(Self.formatPercent(confidence))") }
                if night.isEstimated { parts.append("estimated=true") }
                if !night.missingSignals.isEmpty {
                    parts.append("missingSignals=\(night.missingSignals.joined(separator: ","))")
                }
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

        if !skillResults.isEmpty {
            lines.append("LOCAL_SLEEP_SKILLS_AVAILABLE")
            for skill in SleepAISkillRunner.availableSkills {
                lines.append("skill=\(skill.id); input=\(skill.inputContract); output=\(skill.outputContract); description=\(skill.description)")
            }
            lines.append("LOCAL_SLEEP_SKILL_RESULTS")
            lines.append("These are on-device MCP-style tool results. Use them for advice and planning; do not claim raw audio or health data left the device.")
            for result in skillResults {
                lines.append("tool=\(result.id); confidence=\(Self.formatPercent(result.confidence))")
                if !result.facts.isEmpty {
                    lines.append("facts=\(result.facts.joined(separator: "; "))")
                }
                if !result.findings.isEmpty {
                    lines.append("findings=\(result.findings.joined(separator: ","))")
                }
                if !result.adviceInputs.isEmpty {
                    lines.append("adviceInputs=\(result.adviceInputs.joined(separator: ","))")
                }
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

        var plan: [String] = []
        if let sleepPlanAutoTrackingEnabled { plan.append("autoTracking=\(sleepPlanAutoTrackingEnabled)") }
        if let sleepPlanBedtimeMinute { plan.append("bedtime=\(Self.formatClockMinute(sleepPlanBedtimeMinute))") }
        if let sleepPlanWakeMinute { plan.append("wake=\(Self.formatClockMinute(sleepPlanWakeMinute))") }
        if let sleepPlanGoalMinutes { plan.append("goal=\(sleepPlanGoalMinutes)m") }
        if let sleepPlanSmartWakeWindowMinutes { plan.append("smartWakeWindow=\(sleepPlanSmartWakeWindowMinutes)m") }
        if !plan.isEmpty { lines.append("Current Sleep Plan: " + plan.joined(separator: "; ")) }

        var adaptivePlan: [String] = ["samples=\(adaptivePlanSampleCount)"]
        if let adaptivePlanConfidence {
            adaptivePlan.append("confidence=\(Self.formatPercent(adaptivePlanConfidence))")
        }
        if let adaptiveSuggestedBedtimeMinute {
            adaptivePlan.append("suggestedBedtime=\(Self.formatClockMinute(adaptiveSuggestedBedtimeMinute))")
        }
        if let adaptiveSuggestedWakeMinute {
            adaptivePlan.append("suggestedWake=\(Self.formatClockMinute(adaptiveSuggestedWakeMinute))")
        }
        if let adaptiveSuggestedGoalMinutes {
            adaptivePlan.append("suggestedGoal=\(adaptiveSuggestedGoalMinutes)m")
        }
        if let adaptiveSuggestedSmartWakeWindowMinutes {
            adaptivePlan.append("suggestedSmartWakeWindow=\(adaptiveSuggestedSmartWakeWindowMinutes)m")
        }
        if !adaptivePlanReasons.isEmpty {
            adaptivePlan.append("reasons=\(adaptivePlanReasons.joined(separator: ","))")
        }
        lines.append("Adaptive Sleep Model: " + adaptivePlan.joined(separator: "; "))

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

    private static func formatClockMinute(_ minute: Int) -> String {
        let normalized = ((minute % (24 * 60)) + (24 * 60)) % (24 * 60)
        return String(format: "%02d:%02d", normalized / 60, normalized % 60)
    }

    private static func formatPercent(_ value: Double) -> String {
        "\(Int((min(max(value, 0), 1) * 100).rounded()))%"
    }
}

// MARK: - Service protocol

/// Local Sleep AI assistant. Today's default implementation is a
/// **rule-based, on-device template responder** — it's honest about that
/// in `engineKind`. The MLX-backed formal model can replace the template
/// path without touching UI.
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

    /// Optional streaming variant. The default returns the whole reply as
    /// a single chunk via the non-streaming `reply` so existing rule-based
    /// services keep working. Conforming LLM-backed services should
    /// override to yield tokens as they're generated, which dramatically
    /// reduces apparent latency.
    func streamReply(to prompt: String,
                     context: SleepAIContext) -> AsyncStream<SleepAIStreamEvent>

    /// Optional warm-up: load weights, build the chat session, and prime
    /// any KV cache off the user's hot path. Idempotent. The default is a
    /// no-op so rule-based services can ignore it.
    func prewarm() async
}

/// Streaming events emitted by `SleepAIServiceProtocol.streamReply`. The
/// UI appends `.delta` text to the live assistant bubble and replaces it
/// wholesale on `.final` (which carries the post-processed, sanitized
/// answer — what the model actually produced may have included thinking
/// tokens or translation artefacts that we want to swallow).
public enum SleepAIStreamEvent: Sendable {
    case planDraft(SleepPlanDraft)
    case checkInPlan(SleepProtocolCheckInPlan)
    case delta(String)
    case final(String)
    case metrics(SleepAIPerformanceMetrics)
}

public enum SleepAIPerformanceRoute: String, Codable, Sendable, Equatable {
    case topicGate
    case deterministicSkill
    case localLLM
    case ruleBased
    case fallback
}

public struct SleepAIPerformanceMetrics: Codable, Sendable, Equatable {
    public let engineKind: SleepAIEngineKind
    public let route: SleepAIPerformanceRoute
    public let promptCharacters: Int
    public let contextCharacters: Int
    public let skillResultCount: Int
    public let startedAt: Date
    public let totalMs: Double
    public let firstVisibleTokenMs: Double?
    public let generatedCharacters: Int
    public let visibleCharacters: Int
    public let finalCharacters: Int
    public let hiddenBlockCount: Int
    public let planDraftDetected: Bool
    public let usedFallback: Bool
    public let fallbackReason: String?

    public init(engineKind: SleepAIEngineKind,
                route: SleepAIPerformanceRoute,
                promptCharacters: Int,
                contextCharacters: Int,
                skillResultCount: Int,
                startedAt: Date,
                totalMs: Double,
                firstVisibleTokenMs: Double? = nil,
                generatedCharacters: Int = 0,
                visibleCharacters: Int = 0,
                finalCharacters: Int = 0,
                hiddenBlockCount: Int = 0,
                planDraftDetected: Bool = false,
                usedFallback: Bool = false,
                fallbackReason: String? = nil) {
        self.engineKind = engineKind
        self.route = route
        self.promptCharacters = promptCharacters
        self.contextCharacters = contextCharacters
        self.skillResultCount = skillResultCount
        self.startedAt = startedAt
        self.totalMs = max(0, totalMs)
        self.firstVisibleTokenMs = firstVisibleTokenMs.map { max(0, $0) }
        self.generatedCharacters = max(0, generatedCharacters)
        self.visibleCharacters = max(0, visibleCharacters)
        self.finalCharacters = max(0, finalCharacters)
        self.hiddenBlockCount = max(0, hiddenBlockCount)
        self.planDraftDetected = planDraftDetected
        self.usedFallback = usedFallback
        self.fallbackReason = fallbackReason
    }
}

public extension SleepAIServiceProtocol {
    func streamReply(to prompt: String,
                     context: SleepAIContext) -> AsyncStream<SleepAIStreamEvent> {
        AsyncStream { continuation in
            Task {
                let startedAt = Date()
                let answer = await self.reply(to: prompt, context: context)
                continuation.yield(.final(answer))
                continuation.yield(.metrics(SleepAIPerformanceMetrics(
                    engineKind: self.engineKind,
                    route: .ruleBased,
                    promptCharacters: prompt.count,
                    contextCharacters: context.llmContextPack().count,
                    skillResultCount: context.skillResults.count,
                    startedAt: startedAt,
                    totalMs: Self.elapsedMs(since: startedAt),
                    finalCharacters: answer.count
                )))
                continuation.finish()
            }
        }
    }

    func prewarm() async { /* no-op default */ }

    static func elapsedMs(since startedAt: Date, now: Date = Date()) -> Double {
        now.timeIntervalSince(startedAt) * 1000
    }
}

public enum SleepAIEngineKind: String, Sendable, Codable, Equatable {
    /// On-device rule-based assistant. Always available, ships zero weights.
    case ruleBased
    /// On-device formal model weights.
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
        if let optimization = SleepProtocolOptimizer.optimize(prompt: prompt, context: ctx) {
            return optimization.visibleText
        }
        return skillReply(to: prompt, context: ctx) ?? Self.local("ai.reply.fallback")
    }

    public func streamReply(to prompt: String,
                            context ctx: SleepAIContext) -> AsyncStream<SleepAIStreamEvent> {
        AsyncStream { continuation in
            Task {
                let startedAt = Date()
                let contextCharacters = ctx.llmContextPack().count
                switch SleepTopicGate.classify(prompt) {
                case .refuse(let reason):
                    let refusal = SleepTopicGate.refusal(for: reason)
                    continuation.yield(.final(refusal))
                    continuation.yield(.metrics(SleepAIPerformanceMetrics(
                        engineKind: self.engineKind,
                        route: .topicGate,
                        promptCharacters: prompt.count,
                        contextCharacters: contextCharacters,
                        skillResultCount: ctx.skillResults.count,
                        startedAt: startedAt,
                        totalMs: Self.elapsedMs(since: startedAt),
                        finalCharacters: refusal.count
                    )))
                    continuation.finish()
                    return
                case .allow, .borderline:
                    break
                }

                if let optimization = SleepProtocolOptimizer.optimize(prompt: prompt, context: ctx) {
                    if let draft = optimization.draft {
                        continuation.yield(.planDraft(draft))
                    }
                    if let checkIn = SleepProtocolCheckInFactory.makePlan(from: optimization,
                                                                          prompt: prompt,
                                                                          now: startedAt) {
                        continuation.yield(.checkInPlan(checkIn))
                    }
                    continuation.yield(.final(optimization.visibleText))
                    continuation.yield(.metrics(SleepAIPerformanceMetrics(
                        engineKind: self.engineKind,
                        route: .deterministicSkill,
                        promptCharacters: prompt.count,
                        contextCharacters: contextCharacters,
                        skillResultCount: ctx.skillResults.count,
                        startedAt: startedAt,
                        totalMs: Self.elapsedMs(since: startedAt),
                        finalCharacters: optimization.visibleText.count,
                        planDraftDetected: optimization.draft != nil
                    )))
                    continuation.finish()
                    return
                }

                let answer = await self.reply(to: prompt, context: ctx)
                continuation.yield(.final(answer))
                continuation.yield(.metrics(SleepAIPerformanceMetrics(
                    engineKind: self.engineKind,
                    route: .ruleBased,
                    promptCharacters: prompt.count,
                    contextCharacters: contextCharacters,
                    skillResultCount: ctx.skillResults.count,
                    startedAt: startedAt,
                    totalMs: Self.elapsedMs(since: startedAt),
                    finalCharacters: answer.count
                )))
                continuation.finish()
            }
        }
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

        // Meta-conversation: user is calling out the bot's tone. Don't
        // try to skill-answer ("为什么这么说" alone used to land on the
        // tag-insights matcher and dump unrelated advice). Apologize and
        // pivot to a useful offer.
        if Self.isMetaComplaint(p) {
            return Self.metaApologyReply(chinese: Self.isChinese(p))
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
        if Self.matches(p, [
            "tired", "fatigue", "exhausted", "drowsy", "sleepy",
            "困", "困倦", "累", "疲劳", "疲惫", "没精神"
        ]) {
            return Self.tiredReply(context: ctx, chinese: Self.isChinese(p))
        }
        if Self.matches(p, ["trend", "change", "changed", "better", "worse", "趋势", "变化", "变好", "变差"]) {
            return Self.trendReply(context: ctx, chinese: Self.isChinese(p))
        }
        // Tag-insight: split into "strong" tag-name triggers (auto-match)
        // and "weak" wh-style triggers ("why", "为什么", "原因", "影响")
        // which only count when paired with a sleep-context word. Bare
        // "为什么" used to grab unrelated meta questions like "你为什么
        //这么说 这很不礼貌" → tag advice. Now those fall through to the
        // LLM (or the meta-apology branch above, when detected).
        let strongTagTriggers = [
            "caffeine", "coffee", "alcohol", "stress", "screen",
            "exercise", "late meal", "travel", "medication",
            "咖啡", "咖啡因", "酒", "压力", "屏幕", "运动", "夜宵", "旅行", "药"
        ]
        let weakWhyTriggers = ["why", "affect", "factor", "为什么", "原因", "影响"]
        let sleepContextWords = [
            "sleep", "score", "night", "last night", "deep", "rem", "wake",
            "睡", "睡眠", "睡觉", "得分", "评分", "昨晚", "今晚", "深睡", "浅睡", "醒"
        ]
        if Self.matches(p, strongTagTriggers)
            || (Self.matches(p, weakWhyTriggers) && Self.matches(p, sleepContextWords)) {
            return Self.tagInsightReply(context: ctx, chinese: Self.isChinese(p))
        }
        if Self.matches(p, [
            "data", "missing", "accuracy", "accurate", "healthkit", "watch", "sensor",
            "数据", "缺失", "准确", "准吗", "健康", "手表", "传感器"
        ]) {
            return Self.dataStatusReply(context: ctx, chinese: Self.isChinese(p))
        }
        if Self.isAdaptivePlanIntent(p) {
            return Self.adaptivePlanFallback(context: ctx, chinese: Self.isChinese(p))
        }
        if Self.matches(p, [
            "sleep plan", "schedule", "automatic", "auto track", "smart alarm",
            "cycle wake", "nightmare wake", "press start", "bedtime",
            "睡眠计划", "自动", "计划", "不用点", "不想点", "开始睡眠",
            "点开始", "睡前还点", "智能闹钟", "周期唤醒", "噩梦叫醒",
            "入睡时间", "起床时间"
        ]) {
            return Self.sleepPlanReply(prompt: p, chinese: Self.isChinese(p))
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
                Self.local("ai.suggestion.jetLag"),
                Self.local("ai.suggestion.memory")
            ]
        }
        return [
            Self.local("ai.suggestion.summarize"),
            Self.local("ai.suggestion.trend"),
            Self.local("ai.suggestion.jetLag"),
            Self.local("ai.suggestion.memory")
        ]
    }

    // MARK: Helpers

    private static func matches(_ haystack: String, _ needles: [String]) -> Bool {
        for n in needles where haystack.contains(n.lowercased()) { return true }
        return false
    }

    public static func isAdaptivePlanIntent(_ lowered: String) -> Bool {
        let needles = [
            "jet lag", "jetlag", "time zone", "timezone", "flight", "travel",
            "circadian", "memory", "memor", "study", "learn", "exam", "test",
            "倒时差", "时差", "飞往", "飞到", "航班", "旅行", "出差", "记忆", "学习",
            "背", "考试", "复习", "高效记忆"
        ]
        return needles.contains { lowered.contains($0) }
            || containsChineseFlightRoute(lowered)
    }

    private static func containsChineseFlightRoute(_ text: String) -> Bool {
        let patterns = [
            #"从.{1,16}飞.{1,16}"#,
            #".{1,16}飞往.{1,16}"#,
            #".{1,16}飞到.{1,16}"#
        ]
        return patterns.contains { pattern in
            (try? NSRegularExpression(pattern: pattern))?
                .firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) != nil
        }
    }

    /// Detects when the user is complaining about the bot itself —
    /// politeness, tone, repetition, irrelevance. Routing these into the
    /// skill matchers used to dump unrelated advice on top of the original
    /// offence; routing them into the LLM with no context is also bad
    /// because small models tend to double down. Handle here with a soft,
    /// human apology.
    static func isMetaComplaint(_ lowered: String) -> Bool {
        let needles = [
            // English
            "rude", "that was rude", "be polite", "you're rude", "youre rude",
            "stop saying that", "why did you say that", "why are you saying",
            "that's not helpful", "thats not helpful", "you didn't answer",
            "you didnt answer", "dont be condescending", "don't be condescending",
            // Chinese
            "不礼貌", "无礼", "没礼貌", "礼貌点", "客气点", "语气", "口气",
            "为什么这么说", "为啥这么说", "你怎么说话",
            "你没回答", "答非所问", "牛头不对马嘴", "胡说",
            "别说教", "别教训", "瞧不起", "看不起"
        ]
        for n in needles where lowered.contains(n) { return true }
        return false
    }

    /// Soft apology + offer one concrete next step. Pulled from a small
    /// pool so repeated complaints don't loop on the same line.
    static func metaApologyReply(chinese: Bool) -> String {
        if chinese {
            return [
                "抱歉，刚才那句确实生硬了。我换一种说法 — 想从睡眠的哪一面聊起？",
                "对不起，那句话不太合适。我重新来：你想看 **昨晚** 的情况，还是聊点睡前习惯？",
                "嗯，是我没说好。换个方式 — 我可以讲一下你最近的睡眠，或给点小建议，挑一个？",
                "抱歉。我回得有点机械。你具体想问什么，我尽量直接答。"
            ].randomElement()!
        } else {
            return [
                "Sorry — that came out blunt. Let me try again. What part of sleep do you want to dig into?",
                "Apologies, that wasn't great. Want me to look at last night, or chat about wind-down habits?",
                "You're right, that wasn't helpful. Tell me what you actually want to know and I'll keep it direct.",
                "Sorry — let me reset. Pick one: a read on last night, or a tip to help you sleep better."
            ].randomElement()!
        }
    }

    /// One- or two-character affirmations / fillers that have no semantic
    /// content for a sleep coach to act on. Without this guard an open-weights
    /// model latches onto them as translation requests ("可以" → "I can
    /// translate that to English…") or generic chitchat. We answer with a
    /// short conversational filler reply instead.
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

    private static func adaptivePlanFallback(context ctx: SleepAIContext,
                                             chinese: Bool) -> String {
        let plan = ctx.skillResults.first { $0.id == "plan_requirements" }
        let missing = plan?.adviceInputs
            .filter { $0.hasPrefix("ask_for_") }
            .map { String($0.dropFirst("ask_for_".count)) } ?? []

        if !missing.isEmpty {
            let questions = missing.prefix(3).map { input -> String in
                switch input {
                case "route_or_time_zones":
                    return chinese ? "出发地和目的地，或跨几个时区" : "departure and arrival cities or time zones"
                case "departure_and_arrival_times":
                    return chinese ? "出发和到达时间" : "departure and arrival times"
                case "first_must_be_awake_time":
                    return chinese ? "到达后第一件必须清醒的安排时间" : "the first must-be-awake time after arrival"
                case "habitual_sleep_window":
                    return chinese ? "你平时大概几点睡、几点起" : "your usual sleep and wake window"
                case "learning_deadline_or_performance_time":
                    return chinese ? "考试、汇报或需要表现的时间" : "the exam, presentation, or performance time"
                case "study_or_sleep_timing":
                    return chinese ? "今天学习大概到几点、今晚能睡多久" : "when study ends and how much sleep you can protect tonight"
                default:
                    return input.replacingOccurrences(of: "_", with: " ")
                }
            }
            if chinese {
                return "可以，我先缺这几项：\(questions.joined(separator: "；"))。补齐后我会直接给你一版可执行的睡眠计划。"
            }
            return "I can do that. I need: \(questions.joined(separator: "; ")). Then I can give you a plan you can follow."
        }

        if chinese {
            return "信息基本够了。本地正式模型不可用时，我先给保守版本：保持当前睡眠计划，早晨尽快接触亮光，下午后停止咖啡因，睡前一小时减光。"
        }
        return "I have enough to plan. If the local model is unavailable, use the conservative path: keep the current Sleep Plan, get bright morning light, stop caffeine after early afternoon, and dim light in the last hour."
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

    private static func tiredReply(context ctx: SleepAIContext, chinese: Bool) -> String {
        guard ctx.hasUsableNight else {
            return chinese
                ? "我还没有昨晚的完整记录，所以不能判断你今天困是不是和睡眠有关。今晚记录一整晚，明早我会看时长、清醒时间和分期。"
                : "I do not have a complete tracked night yet, so I cannot tell whether today's tiredness is sleep-related. Track tonight and I will check duration, wake time, and stages."
        }

        let duration = Self.formatHours(ctx.durationSec)
        let wake = Self.formatMinutes(ctx.timeInWakeSec)
        let shortNight = ctx.durationSec < 6 * 3600
        let fragmented = ctx.timeInWakeSec >= 30 * 60
        let weakScore = ctx.sleepScore < 70
        let headline: String
        if shortNight {
            headline = chinese ? "总时长偏短" : "short duration"
        } else if fragmented {
            headline = chinese ? "夜间清醒偏多" : "more awake time"
        } else if weakScore {
            headline = chinese ? "整体分数偏低" : "lower overall score"
        } else {
            headline = chinese ? "昨晚数据没有明显短板" : "no obvious weak spot in last night's data"
        }

        if chinese {
            return "你今天困，最可能先看 **\(headline)**：昨晚得分 **\(ctx.sleepScore)**，睡了 \(duration)，清醒 \(wake)。单晚不能下结论，连续几晚再看会更准。"
        }
        return "For tiredness today, first check **\(headline)**: last night scored **\(ctx.sleepScore)**, with \(duration) asleep and \(wake) awake. One night is not a conclusion; a few nights are more reliable."
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

    private static func sleepPlanReply(prompt p: String, chinese: Bool) -> String {
        if Self.matches(p, ["smart alarm", "cycle wake", "智能闹钟", "周期唤醒"]) {
            return chinese
                ? "智能闹钟会在你设置的唤醒窗口里观察动作和心率，尽量在较浅、较稳定的时刻叫醒；如果没有合适时机，就按目标时间响。"
                : "Smart Alarm watches motion and heart-rate patterns inside your wake window and tries to wake you at a lighter, steadier moment; otherwise it rings at the target time."
        }
        if Self.matches(p, ["nightmare", "噩梦"]) {
            return chinese
                ? "噩梦叫醒是保守实验功能：结合心率突增和动作变化触发手表触感提醒。它不是医学判断，默认应谨慎开启。"
                : "Nightmare wake is a conservative experimental feature: it combines heart-rate spikes and motion changes to trigger Watch haptics. It is not a medical judgment."
        }
        return chinese
            ? "可以用睡眠计划。设置入睡时间、起床时间、睡眠目标和智能唤醒窗口后，手表会在计划窗口内自动追踪；手动开始只作为临时兜底。"
            : "Use Sleep Plan. Set bedtime, wake time, sleep goal, and a smart wake window; the Watch can track automatically in that planned window. Manual Start is only a fallback."
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
