import Foundation

public struct SessionSummary: Codable, Sendable, Equatable {
    public let sessionId: String
    public let durationSec: Int
    public let timeInWakeSec: Int
    public let timeInLightSec: Int
    public let timeInDeepSec: Int
    public let timeInRemSec: Int
    public let sleepScore: Int

    public init(
        sessionId: String,
        durationSec: Int,
        timeInWakeSec: Int,
        timeInLightSec: Int,
        timeInDeepSec: Int,
        timeInRemSec: Int,
        sleepScore: Int
    ) {
        self.sessionId = sessionId
        self.durationSec = durationSec
        self.timeInWakeSec = timeInWakeSec
        self.timeInLightSec = timeInLightSec
        self.timeInDeepSec = timeInDeepSec
        self.timeInRemSec = timeInRemSec
        self.sleepScore = sleepScore
    }

    /// Decoder keys must match the snake_case JSON emitted by Rust's SessionSummary.
    private enum CodingKeys: String, CodingKey {
        case sessionId      = "session_id"
        case durationSec    = "duration_sec"
        case timeInWakeSec  = "time_in_wake_sec"
        case timeInLightSec = "time_in_light_sec"
        case timeInDeepSec  = "time_in_deep_sec"
        case timeInRemSec   = "time_in_rem_sec"
        case sleepScore     = "sleep_score"
    }
}
