import Foundation

/// Closed enumeration of M7 unattended-readiness diagnostic event types.
/// String raw values are stable on disk — never rename a case without a
/// migration. New cases must be added at the end and decoded leniently.
public enum DiagnosticEventType: String, Codable, Sendable, CaseIterable {
    case appLaunch
    case appForeground
    case appBackground
    case sessionStart
    case sessionStop
    case sessionInterruptedDetected
    case sessionInterruptedFinished
    case sessionInterruptedDiscarded
    case watchReachable
    case watchUnreachable
    case telemetryBatchReceived
    case heartRateSampleCount
    case accelWindowCount
    case inferenceTick
    case smartAlarmArmed
    case smartAlarmTriggered
    case smartAlarmDismissed
    case smartAlarmFailedWatchUnreachable
    case localStoreWrite
    case localStoreError
    case healthPermissionRequested
    case healthPermissionGranted
    case healthPermissionDenied
    case screenshotSmokeStarted
    case screenshotSmokeFinished
}

/// One diagnostic event row. Persisted as a single JSON line. Optional
/// fields are omitted by encoding policy so logs stay compact.
public struct DiagnosticEvent: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var ts: Date
    public var type: DiagnosticEventType
    public var sessionId: String?
    public var message: String?
    public var counters: [String: Int]?
    public var error: String?

    public init(
        id: String = UUID().uuidString,
        ts: Date = Date(),
        type: DiagnosticEventType,
        sessionId: String? = nil,
        message: String? = nil,
        counters: [String: Int]? = nil,
        error: String? = nil
    ) {
        self.id = id
        self.ts = ts
        self.type = type
        self.sessionId = sessionId
        self.message = message
        self.counters = counters
        self.error = error
    }
}
