import Foundation

public struct SleepAISkillResult: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let confidence: Double
    public let facts: [String]
    public let findings: [String]
    public let adviceInputs: [String]

    public init(id: String,
                confidence: Double,
                facts: [String],
                findings: [String],
                adviceInputs: [String]) {
        self.id = id
        self.confidence = min(max(confidence, 0), 1)
        self.facts = facts
        self.findings = findings
        self.adviceInputs = adviceInputs
    }
}

public struct SleepAISkillDefinition: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let description: String
    public let inputContract: String
    public let outputContract: String

    public init(id: String,
                title: String,
                description: String,
                inputContract: String,
                outputContract: String) {
        self.id = id
        self.title = title
        self.description = description
        self.inputContract = inputContract
        self.outputContract = outputContract
    }
}

/// MCP-style local skill runner. These are not network tools and do not call
/// external APIs; they package on-device sleep facts so the LLM can reason
/// from evidence instead of guessing.
public enum SleepAISkillRunner {
    public static let availableSkills: [SleepAISkillDefinition] = [
        SleepAISkillDefinition(
            id: "sleep_status",
            title: "Sleep Status",
            description: "Summarizes the latest locally stored night: duration, score, awake time, deep/REM share, evidence quality, and major single-night flags.",
            inputContract: "SleepAIContext.latestNight",
            outputContract: "facts, findings, adviceInputs"
        ),
        SleepAISkillDefinition(
            id: "sleep_continuity",
            title: "Sleep Continuity",
            description: "Evaluates sleep efficiency, wake after sleep onset, and stage-share continuity from local aggregates.",
            inputContract: "SleepAIContext.latestNight",
            outputContract: "facts, findings, adviceInputs"
        ),
        SleepAISkillDefinition(
            id: "evidence",
            title: "Evidence Quality",
            description: "Explains HealthKit, Watch, fallback, estimated-night, and missing-signal status so advice can be confidence-aware.",
            inputContract: "SleepAIContext.deviceStatus + latestNight.evidence",
            outputContract: "facts, findings, adviceInputs"
        ),
        SleepAISkillDefinition(
            id: "advice_inputs",
            title: "Advice Inputs",
            description: "Extracts local behavioral clues such as snore-event counts, tag trends, and score changes. It never exposes raw audio.",
            inputContract: "SleepAIContext.recentNights + tagInsights",
            outputContract: "facts, findings, adviceInputs"
        ),
        SleepAISkillDefinition(
            id: "adaptive_plan",
            title: "Adaptive Sleep Plan",
            description: "Reports the local dynamic sleep-plan recommendation learned from completed nights and wake surveys. It is a draft only and must not be auto-applied.",
            inputContract: "AdaptiveSleepProfile + current Sleep Plan",
            outputContract: "facts, findings, adviceInputs"
        ),
        SleepAISkillDefinition(
            id: "plan_requirements",
            title: "Plan Requirements",
            description: "Detects jet-lag and memory-plan intents, then reports whether route, timing, deadlines, and habitual sleep window are present or missing.",
            inputContract: "userPrompt + current Sleep Plan",
            outputContract: "facts, findings, adviceInputs"
        )
    ]

    public static func run(context ctx: SleepAIContext) -> [SleepAISkillResult] {
        run(context: ctx, prompt: nil)
    }

    public static func run(context ctx: SleepAIContext,
                           prompt: String?) -> [SleepAISkillResult] {
        [
            sleepStatus(context: ctx),
            continuity(context: ctx),
            evidence(context: ctx),
            adviceInputs(context: ctx),
            adaptivePlan(context: ctx),
            planRequirements(context: ctx, prompt: prompt)
        ].compactMap { $0 }
    }

    private static func sleepStatus(context ctx: SleepAIContext) -> SleepAISkillResult? {
        guard ctx.hasUsableNight, let latest = ctx.latestNight else { return nil }
        let durationHours = Double(latest.durationSec) / 3600
        let awakeRatio = Double(latest.timeInWakeSec) / Double(max(latest.durationSec, 1))
        let deepRatio = Double(latest.timeInDeepSec) / Double(max(latest.durationSec, 1))
        let remRatio = Double(latest.timeInRemSec) / Double(max(latest.durationSec, 1))

        var facts = [
            "latest_duration=\(formatHours(latest.durationSec))",
            "latest_score=\(latest.sleepScore)",
            "awake_minutes=\(latest.timeInWakeSec / 60)",
            "deep_ratio=\(formatRatio(deepRatio))",
            "rem_ratio=\(formatRatio(remRatio))"
        ]
        if let quality = latest.evidenceQualityRaw { facts.append("data_quality=\(quality)") }
        if let confidence = latest.evidenceConfidence {
            facts.append("evidence_confidence=\(formatRatio(confidence))")
        }
        if latest.isEstimated { facts.append("estimated_from_passive_sources=true") }

        var findings: [String] = []
        if durationHours < 6.5 { findings.append("short_sleep_opportunity") }
        if awakeRatio > 0.14 { findings.append("high_wake_after_sleep_onset") }
        if deepRatio < 0.12 { findings.append("low_deep_sleep_share") }
        if remRatio < 0.14 { findings.append("low_rem_sleep_share") }
        if findings.isEmpty { findings.append("no_major_single_night_flag") }

        return SleepAISkillResult(
            id: "sleep_status",
            confidence: latest.evidenceConfidence ?? 0.65,
            facts: facts,
            findings: findings,
            adviceInputs: findings
        )
    }

    private static func continuity(context ctx: SleepAIContext) -> SleepAISkillResult? {
        guard ctx.hasUsableNight, let latest = ctx.latestNight else { return nil }
        let asleepSec = latest.timeInLightSec + latest.timeInDeepSec + latest.timeInRemSec
        let sleepEfficiency = Double(asleepSec) / Double(max(latest.durationSec, 1))
        let awakeMinutes = latest.timeInWakeSec / 60
        let deepShare = Double(latest.timeInDeepSec) / Double(max(asleepSec, 1))
        let remShare = Double(latest.timeInRemSec) / Double(max(asleepSec, 1))

        var facts = [
            "sleep_efficiency=\(formatRatio(sleepEfficiency))",
            "awake_minutes=\(awakeMinutes)",
            "deep_share_of_asleep=\(formatRatio(deepShare))",
            "rem_share_of_asleep=\(formatRatio(remShare))"
        ]
        if latest.isEstimated {
            facts.append("continuity_from_estimated_night=true")
        }

        var findings: [String] = []
        var advice: [String] = []
        if sleepEfficiency < 0.82 {
            findings.append("low_sleep_efficiency")
            advice.append("increase_sleep_opportunity_and_reduce_wake_triggers")
        }
        if awakeMinutes >= 35 {
            findings.append("fragmented_night")
            advice.append("review_caffeine_alcohol_light_temperature_and_stress")
        }
        if deepShare < 0.10 {
            findings.append("low_deep_share")
            advice.append("protect_first_sleep_cycles_with_consistent_bedtime")
        }
        if remShare < 0.14 {
            findings.append("low_rem_share")
            advice.append("avoid_early_wake_cutting_late_night_rem")
        }
        if findings.isEmpty {
            findings.append("continuity_looks_reasonable")
            advice.append("maintain_current_sleep_window")
        }

        return SleepAISkillResult(
            id: "sleep_continuity",
            confidence: latest.evidenceConfidence ?? 0.60,
            facts: facts,
            findings: findings,
            adviceInputs: Array(Set(advice)).sorted()
        )
    }

    private static func evidence(context ctx: SleepAIContext) -> SleepAISkillResult {
        var facts: [String] = []
        if let health = ctx.healthAuthorization { facts.append("healthkit=\(health)") }
        if let paired = ctx.watchPaired { facts.append("watch_paired=\(paired)") }
        if let reachable = ctx.watchReachable { facts.append("watch_reachable_now=\(reachable)") }
        if let installed = ctx.watchAppInstalled { facts.append("watch_app_installed=\(installed)") }
        if let fallback = ctx.inferenceFallbackReason { facts.append("stage_model_fallback=\(fallback)") }

        let latest = ctx.latestNight
        let missing = latest?.missingSignals ?? []
        var findings: [String] = []
        if !ctx.hasUsableNight {
            findings.append("no_usable_night")
        }
        if latest?.isEstimated == true {
            findings.append("night_estimated_from_healthkit_or_fallback")
        }
        if !missing.isEmpty {
            findings.append("missing_signals=\(missing.joined(separator: ","))")
        }
        if findings.isEmpty { findings.append("evidence_adequate_for_basic_advice") }

        return SleepAISkillResult(
            id: "evidence",
            confidence: latest?.evidenceConfidence ?? 0.35,
            facts: facts,
            findings: findings,
            adviceInputs: missing.map { "collect_or_confirm_\($0)" }
        )
    }

    private static func adviceInputs(context ctx: SleepAIContext) -> SleepAISkillResult? {
        guard !ctx.recentNights.isEmpty else { return nil }
        var facts: [String] = []
        var findings: [String] = []
        var advice: [String] = []

        let snoreNights = ctx.recentNights.filter { ($0.snoreEventCount ?? 0) > 0 }
        if let latestSnore = ctx.latestNight?.snoreEventCount, latestSnore > 0 {
            facts.append("latest_microphone_snore_events=\(latestSnore)")
            let perHour = Double(latestSnore) / (Double(max(ctx.latestNight?.durationSec ?? 1, 1)) / 3600)
            facts.append(String(format: "latest_snore_events_per_hour=%.1f", perHour))
            findings.append(perHour >= 6 ? "high_snore_density" : "snore_events_present")
            advice.append("discuss_sleep_position_nasal_congestion_alcohol_timing")
        }
        if snoreNights.count >= 2 {
            findings.append("snore_seen_on_multiple_recent_nights")
            advice.append("track_snore_trend_without_saving_audio")
        }

        if let strongest = ctx.strongestTagInsight {
            facts.append(String(format: "strongest_tag=%@ delta=%+.1f",
                                strongest.tag,
                                strongest.scoreDelta))
            findings.append("observational_tag_pattern_available")
            advice.append("mention_tag_association_not_causation")
        }

        if let delta = ctx.scoreTrendDelta {
            facts.append(String(format: "latest_vs_prior_score_delta=%+.1f", delta))
            if delta <= -6 {
                findings.append("recent_score_drop")
                advice.append("ask_about_recent_schedule_caffeine_stress")
            } else if delta >= 6 {
                findings.append("recent_score_improvement")
                advice.append("reinforce_recent_successful_conditions")
            }
        }

        guard !facts.isEmpty || !findings.isEmpty else { return nil }
        return SleepAISkillResult(
            id: "advice_inputs",
            confidence: ctx.latestNight?.evidenceConfidence ?? 0.55,
            facts: facts,
            findings: findings,
            adviceInputs: Array(Set(advice)).sorted()
        )
    }

    private static func adaptivePlan(context ctx: SleepAIContext) -> SleepAISkillResult? {
        guard ctx.adaptivePlanSampleCount > 0 else { return nil }
        var facts: [String] = [
            "adaptive_samples=\(ctx.adaptivePlanSampleCount)"
        ]
        if let confidence = ctx.adaptivePlanConfidence {
            facts.append("adaptive_confidence=\(formatRatio(confidence))")
        }
        if let bed = ctx.adaptiveSuggestedBedtimeMinute {
            facts.append("suggested_bedtime=\(formatClockMinute(bed))")
        }
        if let wake = ctx.adaptiveSuggestedWakeMinute {
            facts.append("suggested_wake=\(formatClockMinute(wake))")
        }
        if let goal = ctx.adaptiveSuggestedGoalMinutes {
            facts.append("suggested_goal_minutes=\(goal)")
        }
        if let window = ctx.adaptiveSuggestedSmartWakeWindowMinutes {
            facts.append("suggested_smart_wake_window_minutes=\(window)")
        }

        var findings = ctx.adaptivePlanReasons
        if findings.isEmpty {
            findings.append("adaptive_plan_matches_current_plan")
        }

        var advice = [
            "use_adaptive_plan_as_draft_not_auto_apply",
            "explain_plan_reasons_before_asking_to_save",
            "require_explicit_user_confirmation_before_save"
        ]
        if ctx.adaptivePlanSampleCount < 5 {
            advice.append("treat_adaptive_plan_as_low_sample_suggestion")
        }

        return SleepAISkillResult(
            id: "adaptive_plan",
            confidence: ctx.adaptivePlanConfidence ?? 0.35,
            facts: facts,
            findings: stableUnique(findings),
            adviceInputs: stableUnique(advice)
        )
    }

    private static func planRequirements(context ctx: SleepAIContext,
                                         prompt rawPrompt: String?) -> SleepAISkillResult? {
        guard let prompt = rawPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
              !prompt.isEmpty else { return nil }
        let lower = prompt.lowercased()
        let isJetLag = containsAny(lower, [
            "jet lag", "jetlag", "time zone", "timezone", "flight", "travel",
            "倒时差", "时差", "飞往", "飞到", "航班", "旅行", "出差"
        ]) || hasChineseFlightRoute(prompt)
        let isMemory = containsAny(lower, [
            "memory", "memor", "study", "learn", "exam", "test",
            "记忆", "学习", "背", "考试", "复习", "高效记忆"
        ])
        guard isJetLag || isMemory else { return nil }

        var facts: [String] = []
        if let bed = ctx.sleepPlanBedtimeMinute,
           let wake = ctx.sleepPlanWakeMinute {
            facts.append("current_sleep_plan=\(formatClockMinute(bed))-\(formatClockMinute(wake))")
        }
        if let goal = ctx.sleepPlanGoalMinutes {
            facts.append("current_sleep_goal_minutes=\(goal)")
        }

        var findings: [String] = []
        var missing: [String] = []
        if isJetLag {
            findings.append("intent=jet_lag_sleep_plan")
            if !hasRoute(prompt) { missing.append("route_or_time_zones") }
            if clockCount(in: prompt) < 2 { missing.append("departure_and_arrival_times") }
            if !containsAny(lower, ["meeting", "exam", "work", "must be awake", "开会", "考试", "上班", "必须清醒", "重要安排"]) {
                missing.append("first_must_be_awake_time")
            }
            if ctx.sleepPlanBedtimeMinute == nil || ctx.sleepPlanWakeMinute == nil {
                missing.append("habitual_sleep_window")
            }
            facts.append("planner_policy=use_light_timing_sleep_window_and_caffeine_cutoff")
        }
        if isMemory {
            findings.append("intent=memory_aware_sleep_plan")
            if !containsAny(lower, ["exam", "test", "考试", "测验", "presentation", "面试", "汇报", "deadline"]) {
                missing.append("learning_deadline_or_performance_time")
            }
            if clockCount(in: prompt) == 0 && !containsAny(lower, ["tonight", "tomorrow", "今天", "今晚", "明天"]) {
                missing.append("study_or_sleep_timing")
            }
            if ctx.sleepPlanBedtimeMinute == nil || ctx.sleepPlanWakeMinute == nil {
                missing.append("habitual_sleep_window")
            }
            facts.append("planner_policy=protect_sleep_after_learning_no_guaranteed_memory_claim")
        }

        if missing.isEmpty {
            findings.append("ready_for_plan_generation")
        } else {
            findings.append("missing_plan_inputs=\(Array(Set(missing)).sorted().joined(separator: ","))")
        }

        return SleepAISkillResult(
            id: "plan_requirements",
            confidence: 0.88,
            facts: facts,
            findings: findings,
            adviceInputs: missing.isEmpty
                ? ["generate_saveable_sleep_plan_when_user_wants_plan"]
                : Array(Set(missing)).sorted().map { "ask_for_\($0)" }
        )
    }

    private static func formatHours(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        return "\(h)h\(m)m"
    }

    private static func formatRatio(_ value: Double) -> String {
        String(format: "%.2f", min(max(value, 0), 1))
    }

    private static func formatClockMinute(_ minute: Int) -> String {
        let normalized = ((minute % (24 * 60)) + (24 * 60)) % (24 * 60)
        return String(format: "%02d:%02d", normalized / 60, normalized % 60)
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    private static func hasRoute(_ prompt: String) -> Bool {
        let patterns = [
            #"从.+到.+"#,
            #"从.+飞.+"#,
            #".+飞往.+"#,
            #".+飞到.+"#,
            #"from\s+.+\s+to\s+.+"#,
            #"[A-Z]{3}\s*(->|→|-)\s*[A-Z]{3}"#
        ]
        return patterns.contains { pattern in
            (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]))?
                .firstMatch(in: prompt, range: NSRange(prompt.startIndex..<prompt.endIndex, in: prompt)) != nil
        }
    }

    private static func hasChineseFlightRoute(_ prompt: String) -> Bool {
        let patterns = [
            #"从.{1,16}飞.{1,16}"#,
            #".{1,16}飞往.{1,16}"#,
            #".{1,16}飞到.{1,16}"#
        ]
        return patterns.contains { pattern in
            (try? NSRegularExpression(pattern: pattern))?
                .firstMatch(in: prompt, range: NSRange(prompt.startIndex..<prompt.endIndex, in: prompt)) != nil
        }
    }

    private static func clockCount(in prompt: String) -> Int {
        let pattern = #"([01]?[0-9]|2[0-3])[:：][0-5][0-9]"#
        return (try? NSRegularExpression(pattern: pattern))?
            .matches(in: prompt, range: NSRange(prompt.startIndex..<prompt.endIndex, in: prompt))
            .count ?? 0
    }

    private static func stableUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for value in values where !seen.contains(value) {
            seen.insert(value)
            out.append(value)
        }
        return out
    }
}

public enum SleepScoreEstimator {
    public static func estimate(durationSec: Int,
                                asleepSec: Int,
                                wakeSec: Int,
                                deepSec: Int,
                                remSec: Int) -> Int {
        guard durationSec >= 30 * 60 else { return 0 }
        let durationHours = Double(durationSec) / 3600
        let awakeRatio = Double(wakeSec) / Double(max(durationSec, 1))
        let deepRatio = Double(deepSec) / Double(max(asleepSec, 1))
        let remRatio = Double(remSec) / Double(max(asleepSec, 1))

        var score = 86.0
        let durationPenalty = max(0, abs(durationHours - 8.0) - 0.75) * 7.0
        score -= min(durationPenalty, 22)
        score -= min(max(0, awakeRatio - 0.10) * 120, 22)

        let hasStageDetail = deepSec > 0 || remSec > 0
        if hasStageDetail {
            if deepRatio < 0.10 { score -= min((0.10 - deepRatio) * 90, 10) }
            if remRatio < 0.14 { score -= min((0.14 - remRatio) * 70, 8) }
        } else {
            score -= 6
        }

        return Int(min(max(score.rounded(), 35), 96))
    }
}
