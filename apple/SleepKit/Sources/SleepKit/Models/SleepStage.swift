import Foundation

public enum SleepStage: Int, Codable, Sendable, CaseIterable {
    case wake = 0
    case light = 1
    case deep = 2
    case rem = 3

    public var displayName: String {
        switch self {
        case .wake:  return "Wake"
        case .light: return "Light"
        case .deep:  return "Deep"
        case .rem:   return "REM"
        }
    }
}
