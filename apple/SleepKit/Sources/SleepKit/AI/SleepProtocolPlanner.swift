import Foundation

public struct SleepPlanDraft: Sendable, Equatable, Identifiable {
    public let id: String
    public let plan: SleepPlanConfiguration

    public init(id: String = UUID().uuidString, plan: SleepPlanConfiguration) {
        self.id = id
        self.plan = plan
    }
}

/// Control-plane helpers for AI-authored Sleep Plan changes.
///
/// This type deliberately does not write user-facing prose. The local LLM
/// decides whether to ask a follow-up or propose a plan. Swift only parses the
/// hidden directive that lets the app save a plan after explicit confirmation.
public enum SleepProtocolPlanner {
    public static let directiveOpen = "<CIRCADIA_PLAN>"
    public static let directiveClose = "</CIRCADIA_PLAN>"

    public static let directiveInstructions = """
    SLEEP PLAN CONTROL
    If the user wants to adjust sleep timing for jet lag, learning, memory,
    exams, recovery, or a bedtime routine:
      - If essential facts are missing, ask only the missing questions.
      - If enough facts are present, give a concise plan in normal language.
      - For jet-lag plans, include timed bright-light exposure or light
        avoidance; light timing is the main behavioral lever.
      - Keep the visible plan under 90 words, with no headings or tables, so
        the hidden save block fits in the generation budget.
      - When and only when you are proposing a plan the app can save, append
        this hidden block at the very end. Do not explain the block:
        <CIRCADIA_PLAN>
        autoTracking=true
        bedtime=23:30
        wake=07:30
        goalMinutes=480
        smartWakeWindowMinutes=25
        </CIRCADIA_PLAN>
    Use the current Sleep Plan from CIRCADIA_LOCAL_CONTEXT as the starting
    point. Never invent travel dates, wake deadlines, medication dosing, or
    fertility/cycle predictions.
    """

    public static func isApplyCommand(_ prompt: String) -> Bool {
        let p = prompt.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            "apply", "apply plan", "save", "save plan", "confirm", "yes apply",
            "应用", "应用计划", "保存", "保存计划", "确认", "就这样", "可以应用"
        ].contains(p)
    }

    public static func extractPlanDraft(from text: String,
                                        currentPlan: SleepPlanConfiguration,
                                        allowLooseDirective: Bool = false) -> SleepPlanDraft? {
        guard let block = directiveBlock(in: text)
            ?? (allowLooseDirective ? looseDirectiveBlock(in: text) : nil) else { return nil }
        let values = parseKeyValues(block)

        let bedtime = parseClock(values["bedtime"])
        let wake = parseClock(values["wake"])
        guard let bedtime, let wake else { return nil }

        let plan = SleepPlanConfiguration(
            autoTrackingEnabled: parseBool(values["autotracking"]) ?? true,
            bedtimeHour: bedtime.hour,
            bedtimeMinute: bedtime.minute,
            wakeHour: wake.hour,
            wakeMinute: wake.minute,
            sleepGoalMinutes: parseInt(values["goalminutes"]) ?? currentPlan.sleepGoalMinutes,
            smartWakeWindowMinutes: parseInt(values["smartwakewindowminutes"])
                ?? currentPlan.smartWakeWindowMinutes,
            nightmareWakeEnabled: currentPlan.nightmareWakeEnabled
        )
        return SleepPlanDraft(plan: plan)
    }

    public static func allowsLoosePlanDraft(for prompt: String) -> Bool {
        let lower = prompt.lowercased()
        let wantsSavedPlan = [
            "保存", "可以保存", "应用", "睡眠计划", "倒时差计划",
            "save", "apply", "sleep plan"
        ].contains { lower.contains($0) }
        guard wantsSavedPlan else { return false }

        let clockPattern = #"([01]?[0-9]|2[0-3])[:：][0-5][0-9]"#
        let matches = (try? NSRegularExpression(pattern: clockPattern))?
            .matches(in: prompt, range: NSRange(prompt.startIndex..<prompt.endIndex, in: prompt))
            .count ?? 0
        return matches >= 2
    }

    public static func visibleText(from text: String) -> String {
        var out = text
        while let start = out.range(of: directiveOpen, options: [.caseInsensitive]) {
            if let end = out.range(of: directiveClose,
                                   options: [.caseInsensitive],
                                   range: start.upperBound..<out.endIndex) {
                out.removeSubrange(start.lowerBound..<end.upperBound)
            } else {
                out.removeSubrange(start.lowerBound..<out.endIndex)
            }
        }
        return out
            .components(separatedBy: .newlines)
            .filter { !isLooseControlDirectiveLine($0) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func directiveBlock(in text: String) -> String? {
        guard let start = text.range(of: directiveOpen, options: [.caseInsensitive]),
              let end = text.range(of: directiveClose,
                                   options: [.caseInsensitive],
                                   range: start.upperBound..<text.endIndex) else {
            return nil
        }
        return String(text[start.upperBound..<end.lowerBound])
    }

    private static func looseDirectiveBlock(in text: String) -> String? {
        let tail = String(text.suffix(700))
        let values = parseKeyValues(tail)
        let required = ["autotracking", "bedtime", "wake", "goalminutes", "smartwakewindowminutes"]
        guard required.allSatisfy({ values[$0] != nil }) else { return nil }
        return tail
    }

    private static func parseKeyValues(_ block: String) -> [String: String] {
        var values: [String: String] = [:]
        for rawLine in block.components(separatedBy: CharacterSet(charactersIn: "\n;")) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, let sep = line.firstIndex(of: "=") else { continue }
            let key = line[..<sep]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let value = line[line.index(after: sep)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            values[key] = sanitizedValue(String(value))
        }
        return values
    }

    private static func parseClock(_ raw: String?) -> (hour: Int, minute: Int)? {
        guard let raw else { return nil }
        let pattern = #"^\s*([01]?[0-9]|2[0-3])[:：]([0-5][0-9])\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: raw,
                                           range: NSRange(raw.startIndex..<raw.endIndex, in: raw)),
              let hRange = Range(match.range(at: 1), in: raw),
              let mRange = Range(match.range(at: 2), in: raw),
              let hour = Int(raw[hRange]),
              let minute = Int(raw[mRange]) else {
            return nil
        }
        return (hour, minute)
    }

    private static func parseBool(_ raw: String?) -> Bool? {
        guard let raw else { return nil }
        switch sanitizedValue(raw).lowercased() {
        case "true", "yes", "1": return true
        case "false", "no", "0": return false
        default: return nil
        }
    }

    private static func parseInt(_ raw: String?) -> Int? {
        guard let raw else { return nil }
        let value = sanitizedValue(raw)
        if let int = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return int
        }
        guard let match = try? NSRegularExpression(pattern: #"\d+"#)
            .firstMatch(in: value, range: NSRange(value.startIndex..<value.endIndex, in: value)),
              let range = Range(match.range, in: value) else { return nil }
        return Int(value[range])
    }

    private static func sanitizedValue(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let tag = value.firstIndex(of: "<") {
            value = String(value[..<tag])
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isLooseControlDirectiveLine(_ raw: String) -> Bool {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = line.lowercased()
        guard !line.isEmpty else { return false }
        if lower.contains("circadia_plan") || lower.contains("</circad") {
            return true
        }
        let markers = [
            "autotracking=",
            "goalminutes=",
            "smartwakewindowminutes=",
            "bedtime=",
            "wake="
        ]
        return markers.contains { lower.contains($0) }
    }
}
