import Foundation

public enum SleepPlanPhase: String, Codable, Sendable, Equatable {
    case idle
    case windDown
    case scheduledSleep
    case wakeWindow
    case postWake
}

public struct SleepPlanWindow: Codable, Sendable, Equatable {
    public let id: String
    public let bedtime: Date
    public let wakeTime: Date
    public let windDownStart: Date
    public let smartWakeStart: Date
    public let autoStartAt: Date
    public let autoStopAfter: Date

    public init(id: String,
                bedtime: Date,
                wakeTime: Date,
                windDownStart: Date,
                smartWakeStart: Date,
                autoStartAt: Date,
                autoStopAfter: Date) {
        self.id = id
        self.bedtime = bedtime
        self.wakeTime = wakeTime
        self.windDownStart = windDownStart
        self.smartWakeStart = smartWakeStart
        self.autoStartAt = autoStartAt
        self.autoStopAfter = autoStopAfter
    }
}

public struct SleepPlanDecision: Codable, Sendable, Equatable {
    public let phase: SleepPlanPhase
    public let window: SleepPlanWindow
    public let shouldAutoStart: Bool
    public let shouldArmSmartAlarm: Bool

    public init(phase: SleepPlanPhase,
                window: SleepPlanWindow,
                shouldAutoStart: Bool,
                shouldArmSmartAlarm: Bool) {
        self.phase = phase
        self.window = window
        self.shouldAutoStart = shouldAutoStart
        self.shouldArmSmartAlarm = shouldArmSmartAlarm
    }
}

/// User-facing sleep plan. This is intentionally schedule-first: the watch can
/// begin collecting at night without requiring a "I'm going to sleep" tap.
public struct SleepPlanConfiguration: Codable, Sendable, Equatable {
    public var autoTrackingEnabled: Bool
    public var bedtimeHour: Int
    public var bedtimeMinute: Int
    public var wakeHour: Int
    public var wakeMinute: Int
    public var sleepGoalMinutes: Int
    public var smartWakeWindowMinutes: Int
    public var nightmareWakeEnabled: Bool

    public static let `default` = SleepPlanConfiguration(
        autoTrackingEnabled: false,
        bedtimeHour: 23,
        bedtimeMinute: 0,
        wakeHour: 7,
        wakeMinute: 0,
        sleepGoalMinutes: 8 * 60,
        smartWakeWindowMinutes: 25,
        nightmareWakeEnabled: false
    )

    public init(autoTrackingEnabled: Bool,
                bedtimeHour: Int,
                bedtimeMinute: Int,
                wakeHour: Int,
                wakeMinute: Int,
                sleepGoalMinutes: Int,
                smartWakeWindowMinutes: Int,
                nightmareWakeEnabled: Bool) {
        self.autoTrackingEnabled = autoTrackingEnabled
        self.bedtimeHour = Self.clampHour(bedtimeHour)
        self.bedtimeMinute = Self.clampMinute(bedtimeMinute)
        self.wakeHour = Self.clampHour(wakeHour)
        self.wakeMinute = Self.clampMinute(wakeMinute)
        self.sleepGoalMinutes = min(max(sleepGoalMinutes, 4 * 60), 12 * 60)
        self.smartWakeWindowMinutes = min(max(smartWakeWindowMinutes, 5), 45)
        self.nightmareWakeEnabled = nightmareWakeEnabled
    }

    public var scheduleDurationMinutes: Int {
        let bedtimeTotal = bedtimeHour * 60 + bedtimeMinute
        let wakeTotal = wakeHour * 60 + wakeMinute
        let raw = wakeTotal - bedtimeTotal
        return raw > 0 ? raw : raw + 24 * 60
    }

    public func decision(now: Date = Date(),
                         calendar: Calendar = .current) -> SleepPlanDecision {
        let window = bestWindow(near: now, calendar: calendar)
        let phase = phase(for: now, in: window)
        let shouldAutoStart = autoTrackingEnabled
            && now >= window.autoStartAt
            && now <= window.autoStopAfter
        let shouldArmSmartAlarm = smartWakeWindowMinutes > 0
            && now < window.wakeTime
        return SleepPlanDecision(
            phase: phase,
            window: window,
            shouldAutoStart: shouldAutoStart,
            shouldArmSmartAlarm: shouldArmSmartAlarm
        )
    }

    public func bestWindow(near date: Date = Date(),
                           calendar: Calendar = .current) -> SleepPlanWindow {
        let startOfDay = calendar.startOfDay(for: date)
        let candidates = (-1...1).map { offset in
            window(forBedDay: calendar.date(byAdding: .day, value: offset, to: startOfDay) ?? startOfDay,
                   calendar: calendar)
        }
        if let containing = candidates.first(where: { date >= $0.windDownStart && date <= $0.autoStopAfter }) {
            return containing
        }
        return candidates.min {
            abs($0.bedtime.timeIntervalSince(date)) < abs($1.bedtime.timeIntervalSince(date))
        } ?? window(forBedDay: startOfDay, calendar: calendar)
    }

    public func dateForWakeTime(near date: Date = Date(),
                                calendar: Calendar = .current) -> Date {
        decision(now: date, calendar: calendar).window.wakeTime
    }

    private func window(forBedDay bedDay: Date,
                        calendar: Calendar) -> SleepPlanWindow {
        let bedtime = Self.date(on: bedDay, hour: bedtimeHour, minute: bedtimeMinute, calendar: calendar)
        var wake = Self.date(on: bedDay, hour: wakeHour, minute: wakeMinute, calendar: calendar)
        if wake <= bedtime {
            wake = calendar.date(byAdding: .day, value: 1, to: wake) ?? wake.addingTimeInterval(24 * 3600)
        }

        let windDown = bedtime.addingTimeInterval(-30 * 60)
        let smartWake = wake.addingTimeInterval(-TimeInterval(smartWakeWindowMinutes * 60))
        let autoStart = bedtime.addingTimeInterval(-15 * 60)
        let autoStop = wake.addingTimeInterval(90 * 60)
        let id = Self.windowId(for: bedtime, calendar: calendar)
        return SleepPlanWindow(
            id: id,
            bedtime: bedtime,
            wakeTime: wake,
            windDownStart: windDown,
            smartWakeStart: smartWake,
            autoStartAt: autoStart,
            autoStopAfter: autoStop
        )
    }

    private func phase(for date: Date, in window: SleepPlanWindow) -> SleepPlanPhase {
        if date >= window.windDownStart && date < window.bedtime {
            return .windDown
        }
        if date >= window.bedtime && date < window.smartWakeStart {
            return .scheduledSleep
        }
        if date >= window.smartWakeStart && date <= window.wakeTime {
            return .wakeWindow
        }
        if date > window.wakeTime && date <= window.autoStopAfter {
            return .postWake
        }
        return .idle
    }

    private static func date(on day: Date,
                             hour: Int,
                             minute: Int,
                             calendar: Calendar) -> Date {
        var comps = calendar.dateComponents([.year, .month, .day], from: day)
        comps.hour = clampHour(hour)
        comps.minute = clampMinute(minute)
        return calendar.date(from: comps) ?? day
    }

    private static func windowId(for bedtime: Date, calendar: Calendar) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: bedtime)
        return String(format: "%04d-%02d-%02d",
                      comps.year ?? 0,
                      comps.month ?? 0,
                      comps.day ?? 0)
    }

    private static func clampHour(_ hour: Int) -> Int {
        min(max(hour, 0), 23)
    }

    private static func clampMinute(_ minute: Int) -> Int {
        min(max(minute, 0), 59)
    }
}

public struct SleepPlanUserDefaultsStore {
    public enum Key {
        public static let autoTrackingEnabled = "settings.sleepPlan.autoTrackingEnabled"
        public static let bedtimeHour = "settings.sleepPlan.bedtimeHour"
        public static let bedtimeMinute = "settings.sleepPlan.bedtimeMinute"
        public static let wakeHour = "settings.sleepPlan.wakeHour"
        public static let wakeMinute = "settings.sleepPlan.wakeMinute"
        public static let sleepGoalMinutes = "settings.sleepPlan.sleepGoalMinutes"
        public static let smartWakeWindowMinutes = "settings.sleepPlan.smartWakeWindowMinutes"
        public static let nightmareWakeEnabled = "settings.sleepPlan.nightmareWakeEnabled"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> SleepPlanConfiguration {
        let fallback = SleepPlanConfiguration.default
        return SleepPlanConfiguration(
            autoTrackingEnabled: defaults.bool(forKey: Key.autoTrackingEnabled),
            bedtimeHour: defaults.object(forKey: Key.bedtimeHour) as? Int ?? fallback.bedtimeHour,
            bedtimeMinute: defaults.object(forKey: Key.bedtimeMinute) as? Int ?? fallback.bedtimeMinute,
            wakeHour: defaults.object(forKey: Key.wakeHour) as? Int ?? fallback.wakeHour,
            wakeMinute: defaults.object(forKey: Key.wakeMinute) as? Int ?? fallback.wakeMinute,
            sleepGoalMinutes: defaults.object(forKey: Key.sleepGoalMinutes) as? Int ?? fallback.sleepGoalMinutes,
            smartWakeWindowMinutes: defaults.object(forKey: Key.smartWakeWindowMinutes) as? Int ?? fallback.smartWakeWindowMinutes,
            nightmareWakeEnabled: defaults.bool(forKey: Key.nightmareWakeEnabled)
        )
    }

    public func save(_ plan: SleepPlanConfiguration) {
        defaults.set(plan.autoTrackingEnabled, forKey: Key.autoTrackingEnabled)
        defaults.set(plan.bedtimeHour, forKey: Key.bedtimeHour)
        defaults.set(plan.bedtimeMinute, forKey: Key.bedtimeMinute)
        defaults.set(plan.wakeHour, forKey: Key.wakeHour)
        defaults.set(plan.wakeMinute, forKey: Key.wakeMinute)
        defaults.set(plan.sleepGoalMinutes, forKey: Key.sleepGoalMinutes)
        defaults.set(plan.smartWakeWindowMinutes, forKey: Key.smartWakeWindowMinutes)
        defaults.set(plan.nightmareWakeEnabled, forKey: Key.nightmareWakeEnabled)
    }
}
