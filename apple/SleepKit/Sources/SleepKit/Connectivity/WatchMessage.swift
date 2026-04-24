import Foundation

// This file is a slim legacy shim. The M3 wire protocol lives in
// `ConnectivityModels.swift`. We keep `WatchMessage` around so any external
// callers / existing Xcode project references don't break during migration.
// New code must use `MessageEnvelope` + typed payloads.

/// Thin façade over `MessageEnvelope` for callers that want to construct
/// envelopes via named factories rather than by hand. All factories encode
/// their payload via JSON; errors bubble out as `throws`.
public enum WatchMessage {
    public static func startTracking(sessionId: String,
                                     at date: Date = Date()) throws -> MessageEnvelope {
        try .make(kind: .control,
                  sessionId: sessionId,
                  tsMs: UInt64(date.timeIntervalSince1970 * 1000),
                  payload: ControlPayload(command: .startTracking))
    }

    public static func stopTracking(sessionId: String?,
                                    at date: Date = Date()) throws -> MessageEnvelope {
        try .make(kind: .control,
                  sessionId: sessionId,
                  tsMs: UInt64(date.timeIntervalSince1970 * 1000),
                  payload: ControlPayload(command: .stopTracking))
    }

    public static func ping(sessionId: String? = nil,
                            at date: Date = Date()) throws -> MessageEnvelope {
        try .make(kind: .control,
                  sessionId: sessionId,
                  tsMs: UInt64(date.timeIntervalSince1970 * 1000),
                  payload: ControlPayload(command: .ping))
    }

    public static func armSmartAlarm(sessionId: String?,
                                     targetMs: UInt64,
                                     windowMinutes: Int) throws -> MessageEnvelope {
        try .make(kind: .control,
                  sessionId: sessionId,
                  tsMs: WallClock.nowMs(),
                  payload: ControlPayload(command: .armSmartAlarm,
                                          targetMs: targetMs,
                                          windowMinutes: windowMinutes))
    }

    public static func telemetryBatch(sessionId: String?,
                                      payload: TelemetryBatchPayload) throws -> MessageEnvelope {
        try .make(kind: .telemetryBatch, sessionId: sessionId, payload: payload)
    }

    public static func status(sessionId: String?,
                              payload: StatusSnapshotPayload) throws -> MessageEnvelope {
        try .make(kind: .statusSnapshot, sessionId: sessionId, payload: payload)
    }

    public static func ack(sessionId: String?,
                           payload: AckPayload) throws -> MessageEnvelope {
        try .make(kind: .ack, sessionId: sessionId, payload: payload)
    }

    /// Convenience overload: encodes a minimal `AckPayload(ackKind:)`.
    public static func ack(sessionId: String?,
                           ackKind: String,
                           batchId: String? = nil) throws -> MessageEnvelope {
        try ack(sessionId: sessionId,
                payload: AckPayload(ackKind: ackKind, batchId: batchId))
    }

    // MARK: M4 alarm control factories

    public static func triggerAlarm(sessionId: String?,
                                    at date: Date = Date()) throws -> MessageEnvelope {
        try .make(kind: .control,
                  sessionId: sessionId,
                  tsMs: UInt64(date.timeIntervalSince1970 * 1000),
                  payload: ControlPayload(command: .triggerAlarm))
    }

    public static func dismissAlarm(sessionId: String?,
                                    at date: Date = Date()) throws -> MessageEnvelope {
        try .make(kind: .control,
                  sessionId: sessionId,
                  tsMs: UInt64(date.timeIntervalSince1970 * 1000),
                  payload: ControlPayload(command: .dismissAlarm))
    }

    public static func stopAlarm(sessionId: String?,
                                 at date: Date = Date()) throws -> MessageEnvelope {
        try .make(kind: .control,
                  sessionId: sessionId,
                  tsMs: UInt64(date.timeIntervalSince1970 * 1000),
                  payload: ControlPayload(command: .stopAlarm))
    }
}
