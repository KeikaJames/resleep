import Foundation

/// User-supplied labels recorded at wake-up, used both for the History
/// detail row and as training signal for on-device personalization.
public struct WakeSurvey: Codable, Sendable, Equatable {
    /// 1 = poor, 5 = excellent.
    public var quality: Int
    /// User-entered actual fall-asleep time, if they remember.
    public var actualFellAsleepAt: Date?
    /// User-entered actual wake-up time. Useful when alarm dismissed late.
    public var actualWokeUpAt: Date?
    /// Did the smart alarm wake them in light sleep (subjective)?
    public var alarmFeltGood: Bool?
    /// Free-form note (≤500 chars enforced by UI).
    public var note: String?
    public var submittedAt: Date

    public init(
        quality: Int,
        actualFellAsleepAt: Date? = nil,
        actualWokeUpAt: Date? = nil,
        alarmFeltGood: Bool? = nil,
        note: String? = nil,
        submittedAt: Date = Date()
    ) {
        self.quality = max(1, min(5, quality))
        self.actualFellAsleepAt = actualFellAsleepAt
        self.actualWokeUpAt = actualWokeUpAt
        self.alarmFeltGood = alarmFeltGood
        self.note = note
        self.submittedAt = submittedAt
    }
}

/// Pre-defined tags. Free-form `notes` on the record is separate.
public enum SleepTag: String, CaseIterable, Codable, Sendable {
    case caffeine
    case alcohol
    case exercise
    case stress
    case lateMeal     = "late_meal"
    case travel
    case medication
    case screen       = "screen_time"

    public var localizedKey: String {
        switch self {
        case .caffeine:  return "tag.caffeine"
        case .alcohol:   return "tag.alcohol"
        case .exercise:  return "tag.exercise"
        case .stress:    return "tag.stress"
        case .lateMeal:  return "tag.late_meal"
        case .travel:    return "tag.travel"
        case .medication: return "tag.medication"
        case .screen:    return "tag.screen_time"
        }
    }

    public var systemSymbol: String {
        switch self {
        case .caffeine:  return "cup.and.saucer.fill"
        case .alcohol:   return "wineglass.fill"
        case .exercise:  return "figure.run"
        case .stress:    return "bolt.heart.fill"
        case .lateMeal:  return "fork.knife"
        case .travel:    return "airplane"
        case .medication: return "pills.fill"
        case .screen:    return "iphone"
        }
    }
}
