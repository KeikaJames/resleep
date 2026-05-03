import Foundation

public enum SleepProtocolKind: String, Codable, Sendable, Equatable {
    case jetLag
    case memory
}

public struct SleepProtocolOptimization: Sendable, Equatable {
    public let kind: SleepProtocolKind
    public let visibleText: String
    public let draft: SleepPlanDraft?
    public let missingInputs: [String]
    public let confidence: Double
    public let reasons: [String]

    public init(kind: SleepProtocolKind,
                visibleText: String,
                draft: SleepPlanDraft?,
                missingInputs: [String],
                confidence: Double,
                reasons: [String]) {
        self.kind = kind
        self.visibleText = visibleText
        self.draft = draft
        self.missingInputs = missingInputs
        self.confidence = min(max(confidence, 0), 1)
        self.reasons = reasons
    }
}

/// Local deterministic protocol planner. It does not call network APIs and it
/// does not infer medical treatment. The LLM can phrase the result, but the
/// saveable Sleep Plan draft comes from this bounded on-device planner.
public enum SleepProtocolOptimizer {
    public static func optimize(prompt: String,
                                context ctx: SleepAIContext,
                                now: Date = Date()) -> SleepProtocolOptimization? {
        let lower = prompt.lowercased()
        let isJetLag = containsAny(lower, [
            "jet lag", "jetlag", "time zone", "timezone", "flight", "travel",
            "倒时差", "时差", "飞往", "飞到", "航班", "旅行", "出差"
        ]) || containsChineseFlightRoute(prompt)
        let isMemory = containsAny(lower, [
            "memory", "memor", "study", "learn", "exam", "test",
            "记忆", "学习", "背", "考试", "复习", "高效记忆"
        ])

        if isJetLag {
            return jetLagPlan(prompt: prompt, context: ctx, now: now)
        }
        if isMemory {
            return memoryPlan(prompt: prompt, context: ctx)
        }
        return nil
    }

    private static func jetLagPlan(prompt: String,
                                   context ctx: SleepAIContext,
                                   now: Date) -> SleepProtocolOptimization {
        let delta = routeTimeZoneDeltaHours(prompt: prompt, now: now)
            ?? explicitTimeZoneDeltaHours(prompt)
        let missing = jetLagMissingInputs(prompt: prompt,
                                          context: ctx,
                                          hasTimeZoneDelta: delta != nil)
        if !missing.isEmpty {
            return SleepProtocolOptimization(
                kind: .jetLag,
                visibleText: missingQuestionText(missing, chinese: isChinese(prompt)),
                draft: nil,
                missingInputs: missing,
                confidence: 0.72,
                reasons: ["missing_jet_lag_inputs"]
            )
        }

        let base = basePlan(from: ctx)
        let deltaHours = delta ?? 0
        let directionShift = jetLagShiftMinutes(deltaHours: deltaHours)
        let targetBed = shiftedMinute(base.bedtimeMinuteOfDay, by: directionShift)
        let targetWake = shiftedMinute(base.wakeMinuteOfDay, by: directionShift)
        let goal = max(base.goalMinutes, 8 * 60)
        let plan = SleepPlanConfiguration(
            autoTrackingEnabled: true,
            bedtimeHour: targetBed / 60,
            bedtimeMinute: targetBed % 60,
            wakeHour: targetWake / 60,
            wakeMinute: targetWake % 60,
            sleepGoalMinutes: min(goal, 9 * 60),
            smartWakeWindowMinutes: base.smartWakeWindowMinutes,
            nightmareWakeEnabled: ctx.currentSleepPlanConfiguration.nightmareWakeEnabled
        )

        let shiftText = directionShift == 0
            ? "keep_window"
            : (directionShift < 0 ? "advance_sleep_window" : "delay_sleep_window")
        return SleepProtocolOptimization(
            kind: .jetLag,
            visibleText: jetLagVisibleText(plan: plan,
                                           shiftMinutes: directionShift,
                                           deltaHours: deltaHours,
                                           chinese: isChinese(prompt)),
            draft: SleepPlanDraft(plan: plan),
            missingInputs: [],
            confidence: abs(deltaHours) >= 1 ? 0.82 : 0.62,
            reasons: [shiftText, "timed_light", "destination_daytime_alignment"]
        )
    }

    private static func memoryPlan(prompt: String,
                                   context ctx: SleepAIContext) -> SleepProtocolOptimization {
        let missing = memoryMissingInputs(prompt: prompt, context: ctx)
        if !missing.isEmpty {
            return SleepProtocolOptimization(
                kind: .memory,
                visibleText: missingQuestionText(missing, chinese: isChinese(prompt)),
                draft: nil,
                missingInputs: missing,
                confidence: 0.70,
                reasons: ["missing_memory_plan_inputs"]
            )
        }

        let base = basePlan(from: ctx)
        var bedtime = base.bedtimeMinuteOfDay
        var goal = max(base.goalMinutes, 8 * 60)
        var reasons = ["protect_post_learning_sleep"]

        if ctx.hasUsableNight, ctx.sleepScore > 0, ctx.sleepScore < 70 {
            bedtime = shiftedMinute(bedtime, by: -20)
            goal = min(max(goal + 15, 8 * 60), 9 * 60)
            reasons.append("recent_low_sleep_score")
        } else if base.fromAdaptive {
            reasons.append("uses_adaptive_sleep_window")
        }

        let wake = shiftedMinute(bedtime, by: goal)
        let plan = SleepPlanConfiguration(
            autoTrackingEnabled: true,
            bedtimeHour: bedtime / 60,
            bedtimeMinute: bedtime % 60,
            wakeHour: wake / 60,
            wakeMinute: wake % 60,
            sleepGoalMinutes: goal,
            smartWakeWindowMinutes: min(base.smartWakeWindowMinutes, 25),
            nightmareWakeEnabled: ctx.currentSleepPlanConfiguration.nightmareWakeEnabled
        )

        return SleepProtocolOptimization(
            kind: .memory,
            visibleText: memoryVisibleText(plan: plan, chinese: isChinese(prompt)),
            draft: SleepPlanDraft(plan: plan),
            missingInputs: [],
            confidence: base.fromAdaptive ? 0.78 : 0.68,
            reasons: reasons
        )
    }

    private struct BasePlan {
        let bedtimeMinuteOfDay: Int
        let wakeMinuteOfDay: Int
        let goalMinutes: Int
        let smartWakeWindowMinutes: Int
        let fromAdaptive: Bool
    }

    private static func basePlan(from ctx: SleepAIContext) -> BasePlan {
        let current = ctx.currentSleepPlanConfiguration
        let adaptiveUsable = ctx.adaptivePlanSampleCount >= 3
            && (ctx.adaptivePlanConfidence ?? 0) >= 0.45
        if adaptiveUsable,
           let bed = ctx.adaptiveSuggestedBedtimeMinute,
           let wake = ctx.adaptiveSuggestedWakeMinute {
            return BasePlan(
                bedtimeMinuteOfDay: normalizeMinute(bed),
                wakeMinuteOfDay: normalizeMinute(wake),
                goalMinutes: ctx.adaptiveSuggestedGoalMinutes ?? current.sleepGoalMinutes,
                smartWakeWindowMinutes: ctx.adaptiveSuggestedSmartWakeWindowMinutes
                    ?? current.smartWakeWindowMinutes,
                fromAdaptive: true
            )
        }
        return BasePlan(
            bedtimeMinuteOfDay: current.bedtimeHour * 60 + current.bedtimeMinute,
            wakeMinuteOfDay: current.wakeHour * 60 + current.wakeMinute,
            goalMinutes: current.sleepGoalMinutes,
            smartWakeWindowMinutes: current.smartWakeWindowMinutes,
            fromAdaptive: false
        )
    }

    private static func jetLagMissingInputs(prompt: String,
                                            context ctx: SleepAIContext,
                                            hasTimeZoneDelta: Bool) -> [String] {
        var missing: [String] = []
        if !hasTimeZoneDelta { missing.append("route_or_time_zones") }
        if clockCount(in: prompt) < 2 { missing.append("departure_and_arrival_times") }
        if !containsAny(prompt.lowercased(), [
            "meeting", "exam", "work", "must be awake",
            "开会", "考试", "上班", "必须清醒", "重要安排"
        ]) {
            missing.append("first_must_be_awake_time")
        }
        if ctx.sleepPlanBedtimeMinute == nil || ctx.sleepPlanWakeMinute == nil {
            missing.append("habitual_sleep_window")
        }
        return stableUnique(missing)
    }

    private static func memoryMissingInputs(prompt: String,
                                            context ctx: SleepAIContext) -> [String] {
        let lower = prompt.lowercased()
        var missing: [String] = []
        if !containsAny(lower, [
            "exam", "test", "presentation", "interview", "deadline",
            "考试", "测验", "汇报", "面试", "截止", "deadline", "明天", "今晚", "today", "tomorrow"
        ]) {
            missing.append("learning_deadline_or_performance_time")
        }
        if clockCount(in: prompt) == 0
            && !containsAny(lower, ["tonight", "tomorrow", "今天", "今晚", "明天"]) {
            missing.append("study_or_sleep_timing")
        }
        if ctx.sleepPlanBedtimeMinute == nil || ctx.sleepPlanWakeMinute == nil {
            missing.append("habitual_sleep_window")
        }
        return stableUnique(missing)
    }

    private static func missingQuestionText(_ missing: [String],
                                            chinese: Bool) -> String {
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
            return "可以，我先缺这几项：\(questions.joined(separator: "；"))。补齐后我会直接给你一版可保存的睡眠计划。"
        }
        return "I can do that. I need: \(questions.joined(separator: "; ")). Then I can give you a saveable Sleep Plan."
    }

    private static func jetLagVisibleText(plan: SleepPlanConfiguration,
                                          shiftMinutes: Int,
                                          deltaHours: Double,
                                          chinese: Bool) -> String {
        let bed = formatClock(plan.bedtimeHour * 60 + plan.bedtimeMinute)
        let wake = formatClock(plan.wakeHour * 60 + plan.wakeMinute)
        let shift = abs(shiftMinutes)
        if chinese {
            let direction = shiftMinutes < 0 ? "提前" : (shiftMinutes > 0 ? "推迟" : "保持")
            let shiftPart = shiftMinutes == 0 ? "先保持睡眠窗口" : "今晚先把睡眠窗口\(direction) **\(shift) 分钟**"
            let travel = deltaHours == 0 ? "" : "，按约 \(String(format: "%.0f", abs(deltaHours))) 小时时差处理"
            return "\(shiftPart)到 **\(bed)-\(wake)**\(travel)。到达后按目的地白天晒自然光，睡前 6 小时停止咖啡因；如果白天撑不住，只睡 20-30 分钟短 nap。确认后我再保存。"
        }
        let direction = shiftMinutes < 0 ? "advance" : (shiftMinutes > 0 ? "delay" : "keep")
        let shiftPart = shiftMinutes == 0 ? "Keep the sleep window" : "\(direction.capitalized) tonight's sleep window by **\(shift) minutes**"
        return "\(shiftPart) to **\(bed)-\(wake)**. Use destination daytime light, stop caffeine 6 hours before bed, and keep any nap to 20-30 minutes. Confirm and I will save it."
    }

    private static func memoryVisibleText(plan: SleepPlanConfiguration,
                                          chinese: Bool) -> String {
        let bed = formatClock(plan.bedtimeHour * 60 + plan.bedtimeMinute)
        let wake = formatClock(plan.wakeHour * 60 + plan.wakeMinute)
        if chinese {
            return "今晚按 **\(bed)-\(wake)** 睡，目标 \(plan.sleepGoalMinutes / 60) 小时左右。学习结束后留 30-45 分钟降刺激，不再刷题到入睡前；明早醒后用 20 分钟复习最难内容。睡眠能支持巩固，但我不会把它说成保证提分。确认后我再保存。"
        }
        return "Use **\(bed)-\(wake)** tonight, aiming for about \(plan.sleepGoalMinutes / 60) hours. Leave 30-45 minutes after studying to wind down, then do a 20-minute review after waking. Sleep supports consolidation, but it is not a guaranteed memory boost. Confirm and I will save it."
    }

    private static func jetLagShiftMinutes(deltaHours: Double) -> Int {
        guard abs(deltaHours) >= 1 else { return 0 }
        let unbounded = abs(deltaHours) * 15
        let raw = Int((unbounded / 15).rounded()) * 15
        let bounded = min(max(raw, 30), 90)
        return deltaHours > 0 ? -bounded : bounded
    }

    private static func routeTimeZoneDeltaHours(prompt: String,
                                                now: Date) -> Double? {
        let matches = cityMatches(in: prompt)
        guard matches.count >= 2 else { return nil }
        let origin = matches[0].timeZone
        let destination = matches[1].timeZone
        let raw = Double(destination.secondsFromGMT(for: now) - origin.secondsFromGMT(for: now)) / 3600
        return normalizedHourDelta(raw)
    }

    private static func explicitTimeZoneDeltaHours(_ prompt: String) -> Double? {
        let patterns = [
            #"跨\s*(\d{1,2})\s*个?时区"#,
            #"(\d{1,2})\s*time\s*zones?"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: prompt,
                                               range: NSRange(prompt.startIndex..<prompt.endIndex, in: prompt)),
                  let range = Range(match.range(at: 1), in: prompt),
                  let value = Double(prompt[range]) else { continue }
            if containsAny(prompt.lowercased(), ["west", "向西", "往西"]) { return -value }
            return value
        }
        return nil
    }

    private struct CityMatch {
        let rangeStart: String.Index
        let timeZone: TimeZone
    }

    private static func cityMatches(in prompt: String) -> [CityMatch] {
        let lower = prompt.lowercased()
        var out: [CityMatch] = []
        var seen = Set<String>()
        for city in cityTimeZones {
            for alias in city.aliases {
                let needle = alias.lowercased()
                guard let range = lower.range(of: needle),
                      !seen.contains(city.identifier),
                      let zone = TimeZone(identifier: city.identifier) else { continue }
                seen.insert(city.identifier)
                out.append(CityMatch(rangeStart: range.lowerBound, timeZone: zone))
                break
            }
        }
        return out.sorted { $0.rangeStart < $1.rangeStart }
    }

    private static let cityTimeZones: [(identifier: String, aliases: [String])] = [
        ("Asia/Shanghai", ["shanghai", "上海", "北京", "beijing", "pek", "pvg"]),
        ("Asia/Hong_Kong", ["hong kong", "香港", "hkg"]),
        ("Asia/Tokyo", ["tokyo", "东京", "東京", "nrt", "hnd"]),
        ("Asia/Seoul", ["seoul", "首尔", "icn"]),
        ("Asia/Singapore", ["singapore", "新加坡", "sin"]),
        ("Asia/Dubai", ["dubai", "迪拜", "dxb"]),
        ("Europe/London", ["london", "伦敦", "lhr", "lgw"]),
        ("Europe/Paris", ["paris", "巴黎", "cdg"]),
        ("Europe/Berlin", ["berlin", "柏林", "ber"]),
        ("America/New_York", ["new york", "nyc", "jfk", "纽约"]),
        ("America/Los_Angeles", ["los angeles", "la", "lax", "洛杉矶"]),
        ("America/Chicago", ["chicago", "芝加哥", "ord"]),
        ("America/Toronto", ["toronto", "多伦多", "yyz"]),
        ("Australia/Sydney", ["sydney", "悉尼", "syd"])
    ]

    private static func normalizedHourDelta(_ hours: Double) -> Double {
        var value = hours
        while value > 12 { value -= 24 }
        while value < -12 { value += 24 }
        return value
    }

    private static func clockCount(in prompt: String) -> Int {
        let pattern = #"([01]?[0-9]|2[0-3])[:：][0-5][0-9]"#
        return (try? NSRegularExpression(pattern: pattern))?
            .matches(in: prompt, range: NSRange(prompt.startIndex..<prompt.endIndex, in: prompt))
            .count ?? 0
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

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0.lowercased()) }
    }

    private static func isChinese(_ text: String) -> Bool {
        text.range(of: #"\p{Han}"#, options: .regularExpression) != nil
    }

    private static func shiftedMinute(_ minute: Int, by delta: Int) -> Int {
        normalizeMinute(minute + delta)
    }

    private static func normalizeMinute(_ minute: Int) -> Int {
        ((minute % (24 * 60)) + (24 * 60)) % (24 * 60)
    }

    private static func formatClock(_ minute: Int) -> String {
        let normalized = normalizeMinute(minute)
        return String(format: "%02d:%02d", normalized / 60, normalized % 60)
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
