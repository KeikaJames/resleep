import Foundation

public struct SleepSession: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let startedAt: Date
    public let endedAt: Date?
    public let stage: SleepStage

    public init(id: String, startedAt: Date, endedAt: Date?, stage: SleepStage) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.stage = stage
    }

    public var isActive: Bool { endedAt == nil }
}
