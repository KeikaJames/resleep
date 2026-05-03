import Foundation

// MARK: - Scenario taxonomy

/// High-level scenarios the replay harness can synthesize. These drive the
/// exact same telemetry path as live data — HR + accel windows land in
/// `WorkoutSessionManager` via a mock connectivity bus.
public enum ScenarioType: String, CaseIterable, Sendable, Codable, Identifiable {
    case fallingAsleep        = "fallingAsleep"
    case stableLight          = "stableLight"
    case stableDeep           = "stableDeep"
    case remSegment           = "remSegment"
    case preAlarmLightInWake  = "preAlarmLightInWake"
    case watchDisconnect      = "watchDisconnect"
    case watchUnavailable     = "watchUnavailable"
    case smartAlarmTriggerDismiss = "smartAlarmTriggerDismiss"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .fallingAsleep:            return "Falling asleep"
        case .stableLight:              return "Stable light sleep"
        case .stableDeep:               return "Stable deep sleep"
        case .remSegment:               return "REM segment"
        case .preAlarmLightInWake:      return "Pre-alarm light (inside window)"
        case .watchDisconnect:          return "Watch disconnect / reconnect"
        case .watchUnavailable:         return "Watch unavailable → phone-local"
        case .smartAlarmTriggerDismiss: return "Smart alarm trigger + dismiss"
        }
    }
}

// MARK: - Scenario step

/// One scripted event inside a scenario. Each step carries a monotonic
/// `offsetSec` from scenario start so the runner can schedule deterministically.
public enum ScenarioStep: Sendable, Equatable {
    case heartRate(offsetSec: Double, bpm: Double)
    case accelWindow(offsetSec: Double, meanX: Double, meanY: Double, meanZ: Double, energy: Double)
    case reachability(offsetSec: Double, reachable: Bool)
    case armSmartAlarm(offsetSec: Double, targetOffsetSec: Double, windowMinutes: Int)
    case dismissAlarm(offsetSec: Double)
    case mark(offsetSec: Double, label: String)

    public var offsetSec: Double {
        switch self {
        case .heartRate(let t, _),
             .accelWindow(let t, _, _, _, _),
             .reachability(let t, _),
             .armSmartAlarm(let t, _, _),
             .dismissAlarm(let t),
             .mark(let t, _):
            return t
        }
    }
}

// MARK: - Scripts

public enum ScenarioScripts {

    public static func duration(_ scenario: ScenarioType) -> Double {
        switch scenario {
        case .fallingAsleep, .stableLight, .stableDeep, .remSegment:
            return 60
        case .preAlarmLightInWake, .smartAlarmTriggerDismiss:
            return 90
        case .watchDisconnect:
            return 45
        case .watchUnavailable:
            return 30
        }
    }

    public static func steps(for scenario: ScenarioType) -> [ScenarioStep] {
        let raw: [ScenarioStep]
        switch scenario {
        case .fallingAsleep:            raw = fallingAsleep()
        case .stableLight:              raw = stableLight()
        case .stableDeep:               raw = stableDeep()
        case .remSegment:               raw = remSegment()
        case .preAlarmLightInWake:      raw = preAlarmLight()
        case .watchDisconnect:          raw = watchDisconnect()
        case .watchUnavailable:         raw = watchUnavailable()
        case .smartAlarmTriggerDismiss: raw = smartAlarmTriggerDismiss()
        }
        return raw.sorted { $0.offsetSec < $1.offsetSec }
    }

    // MARK: helpers

    private static func hrSweep(from: Double, to: Double, sec: Int, startT: Double) -> [ScenarioStep] {
        guard sec > 0 else { return [] }
        return (0..<sec).map { i in
            let denom = Double(max(1, sec - 1))
            let bpm = from + (to - from) * (Double(i) / denom)
            return ScenarioStep.heartRate(offsetSec: startT + Double(i), bpm: bpm)
        }
    }

    private static func accelFlat(energy: Double, sec: Int, startT: Double) -> [ScenarioStep] {
        (0..<sec).map { i in
            .accelWindow(offsetSec: startT + Double(i),
                         meanX: 0, meanY: 0, meanZ: 0, energy: energy)
        }
    }

    // MARK: scripts

    private static func fallingAsleep() -> [ScenarioStep] {
        var out: [ScenarioStep] = []
        out += hrSweep(from: 78, to: 58, sec: 60, startT: 0)
        for i in 0..<60 {
            let denom = Double(max(1, 60 - 1))
            let energy = 0.8 - (0.75 * Double(i) / denom)
            out.append(.accelWindow(offsetSec: Double(i),
                                    meanX: 0, meanY: 0, meanZ: 0, energy: energy))
        }
        out.append(.mark(offsetSec: 60, label: "asleep"))
        return out
    }

    private static func stableLight() -> [ScenarioStep] {
        var out: [ScenarioStep] = []
        out += hrSweep(from: 60, to: 62, sec: 60, startT: 0)
        out += accelFlat(energy: 0.08, sec: 60, startT: 0)
        out.append(.mark(offsetSec: 0, label: "light"))
        return out
    }

    private static func stableDeep() -> [ScenarioStep] {
        var out: [ScenarioStep] = []
        out += hrSweep(from: 52, to: 54, sec: 60, startT: 0)
        out += accelFlat(energy: 0.015, sec: 60, startT: 0)
        out.append(.mark(offsetSec: 0, label: "deep"))
        return out
    }

    private static func remSegment() -> [ScenarioStep] {
        var out: [ScenarioStep] = []
        for i in 0..<60 {
            let bpm = 62 + 6 * sin(Double(i) / 4.0)
            out.append(.heartRate(offsetSec: Double(i), bpm: bpm))
        }
        out += accelFlat(energy: 0.04, sec: 60, startT: 0)
        out.append(.mark(offsetSec: 0, label: "rem"))
        return out
    }

    private static func preAlarmLight() -> [ScenarioStep] {
        var out: [ScenarioStep] = []
        out.append(.armSmartAlarm(offsetSec: 5, targetOffsetSec: 70, windowMinutes: 1))
        out += hrSweep(from: 60, to: 64, sec: 90, startT: 0)
        out += accelFlat(energy: 0.09, sec: 90, startT: 0)
        return out
    }

    private static func watchDisconnect() -> [ScenarioStep] {
        var out: [ScenarioStep] = []
        out += hrSweep(from: 62, to: 60, sec: 45, startT: 0)
        out += accelFlat(energy: 0.05, sec: 45, startT: 0)
        out.append(.reachability(offsetSec: 15, reachable: false))
        out.append(.mark(offsetSec: 15, label: "disconnected"))
        out.append(.reachability(offsetSec: 30, reachable: true))
        out.append(.mark(offsetSec: 30, label: "reconnected"))
        return out
    }

    private static func watchUnavailable() -> [ScenarioStep] {
        var out: [ScenarioStep] = [
            .reachability(offsetSec: 0, reachable: false),
            .mark(offsetSec: 0, label: "phoneLocalFallback"),
        ]
        out += hrSweep(from: 64, to: 60, sec: 30, startT: 0)
        out += accelFlat(energy: 0.06, sec: 30, startT: 0)
        return out
    }

    private static func smartAlarmTriggerDismiss() -> [ScenarioStep] {
        var out: [ScenarioStep] = []
        out.append(.armSmartAlarm(offsetSec: 2, targetOffsetSec: 10, windowMinutes: 1))
        out += hrSweep(from: 60, to: 64, sec: 90, startT: 0)
        out += accelFlat(energy: 0.09, sec: 90, startT: 0)
        out.append(.dismissAlarm(offsetSec: 30))
        out.append(.mark(offsetSec: 30, label: "dismissed"))
        return out
    }
}
