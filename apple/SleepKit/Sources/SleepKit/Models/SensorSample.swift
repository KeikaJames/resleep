import Foundation

public enum SensorSampleKind: Int, Codable, Sendable {
    case heartRate = 1
    case accelerometer = 2
    case audioEvent = 3
    case hrv = 4
}

public struct SensorSample: Codable, Sendable, Equatable {
    public let sessionId: String
    public let timestamp: Date
    public let kind: SensorSampleKind
    public let valueJSON: String

    public init(sessionId: String, timestamp: Date, kind: SensorSampleKind, valueJSON: String) {
        self.sessionId = sessionId
        self.timestamp = timestamp
        self.kind = kind
        self.valueJSON = valueJSON
    }
}
