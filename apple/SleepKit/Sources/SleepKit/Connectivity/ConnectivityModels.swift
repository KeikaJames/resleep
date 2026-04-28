import Foundation

// MARK: - Wire protocol

/// Kind discriminator for `MessageEnvelope`. The payload `Data` is decoded as
/// the matching struct below.
public enum WatchMessageKind: String, Codable, Sendable {
    case control
    case telemetryBatch
    case statusSnapshot
    case ack
}

public enum ControlCommand: String, Codable, Sendable {
    case startTracking
    case stopTracking
    case ping
    case armSmartAlarm
    case triggerAlarm
    case dismissAlarm
    case stopAlarm
    case ack
}

// MARK: - Alarm + source wire enums

/// Wire-level alarm state exposed via `StatusSnapshotPayload`. Mirrors
/// `SmartAlarmController.AlarmState`; kept as a plain `String`-raw enum to
/// survive JSON round-trips across versions.
public enum AlarmState: String, Codable, Sendable, Equatable {
    case idle
    case armed
    case triggered
    case dismissed
    case failedWatchUnreachable
}

/// Mirrors SleepKit's `TrackingSource` for the wire. `TrackingSource` itself
/// lives close to `WorkoutSessionManager` and is not wire-encoded directly so
/// UI-only cases (e.g. `idle`) stay local.
public enum TrackingSourceWire: String, Codable, Sendable, Equatable {
    case none
    case phoneLocal
    case watch
}

// MARK: - Envelope

/// Single envelope type sent over WatchConnectivity. Non-generic because
/// `WCSession` payloads are `[String: Any]` / `Data` — we encode the typed
/// payload once into `payload: Data` and inspect `kind` on the receiving side
/// to pick the right decoder.
public struct MessageEnvelope: Codable, Sendable, Equatable {
    public let version: Int
    public let kind: WatchMessageKind
    public let sessionId: String?
    public let tsMs: UInt64
    public let payload: Data

    public static let currentVersion: Int = 1

    public init(version: Int = currentVersion,
                kind: WatchMessageKind,
                sessionId: String?,
                tsMs: UInt64,
                payload: Data) {
        self.version = version
        self.kind = kind
        self.sessionId = sessionId
        self.tsMs = tsMs
        self.payload = payload
    }

    public static func make<P: Encodable>(kind: WatchMessageKind,
                                          sessionId: String?,
                                          tsMs: UInt64 = WallClock.nowMs(),
                                          payload: P) throws -> MessageEnvelope {
        let data = try JSONEncoder().encode(payload)
        return MessageEnvelope(kind: kind, sessionId: sessionId, tsMs: tsMs, payload: data)
    }

    public func decode<P: Decodable>(_ type: P.Type) throws -> P {
        try JSONDecoder().decode(type, from: payload)
    }

    // Dictionary codec used by WCSession `sendMessage` / `transferUserInfo`
    // (both are `[String: Any]`). Keep keys short to trim Bluetooth payloads.
    public func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "v":   version,
            "k":   kind.rawValue,
            "ts":  NSNumber(value: tsMs),
            "p":   payload
        ]
        // WatchConnectivity payloads must be property-list values. Do not
        // encode Optional.none as `Any`; omit the key when there is no
        // session id, otherwise `updateApplicationContext` rejects the whole
        // payload with WCErrorCodePayloadUnsupportedTypes.
        if let sessionId {
            dict["sid"] = sessionId
        }
        return dict
    }

    public static func fromDictionary(_ dict: [String: Any]) -> MessageEnvelope? {
        guard
            let v = dict["v"] as? Int,
            let k = (dict["k"] as? String).flatMap(WatchMessageKind.init(rawValue:)),
            let ts = (dict["ts"] as? NSNumber)?.uint64Value,
            let p = dict["p"] as? Data
        else { return nil }
        let sid = dict["sid"] as? String
        return MessageEnvelope(version: v, kind: k, sessionId: sid, tsMs: ts, payload: p)
    }
}

// MARK: - Payloads

public struct ControlPayload: Codable, Sendable, Equatable {
    public let command: ControlCommand
    public let targetMs: UInt64?
    public let windowMinutes: Int?

    public init(command: ControlCommand, targetMs: UInt64? = nil, windowMinutes: Int? = nil) {
        self.command = command
        self.targetMs = targetMs
        self.windowMinutes = windowMinutes
    }
}

public struct HeartRatePoint: Codable, Sendable, Equatable {
    public let tsMs: UInt64
    public let bpm: Double
    public init(tsMs: UInt64, bpm: Double) { self.tsMs = tsMs; self.bpm = bpm }
}

public struct AccelWindow: Codable, Sendable, Equatable {
    public let tsMs: UInt64
    public let meanX: Double
    public let meanY: Double
    public let meanZ: Double
    public let magnitudeMean: Double
    public let energy: Double
    public let sampleCount: Int

    public init(tsMs: UInt64,
                meanX: Double, meanY: Double, meanZ: Double,
                magnitudeMean: Double, energy: Double,
                sampleCount: Int) {
        self.tsMs = tsMs
        self.meanX = meanX; self.meanY = meanY; self.meanZ = meanZ
        self.magnitudeMean = magnitudeMean
        self.energy = energy
        self.sampleCount = sampleCount
    }
}

public struct TelemetryBatchPayload: Codable, Sendable, Equatable {
    public let batchId: String
    public let heartRates: [HeartRatePoint]
    public let accelWindows: [AccelWindow]

    public init(batchId: String = UUID().uuidString,
                heartRates: [HeartRatePoint],
                accelWindows: [AccelWindow]) {
        self.batchId = batchId
        self.heartRates = heartRates
        self.accelWindows = accelWindows
    }

    public var isEmpty: Bool { heartRates.isEmpty && accelWindows.isEmpty }
}

public struct StatusSnapshotPayload: Codable, Sendable, Equatable {
    public let isTracking: Bool
    public let reachable: Bool
    public let currentStageRaw: Int?
    public let currentConfidence: Float?
    public let lastSyncTsMs: UInt64?
    public let trackingSourceRaw: String?
    public let alarmStateRaw: String?
    public let alarmTargetTsMs: UInt64?
    public let alarmWindowMinutes: Int?
    public let alarmTriggeredAtTsMs: UInt64?
    public let sleepPlan: SleepPlanConfiguration?
    /// "live" or "simulated" — lets the Watch show whether the phone is
    /// driving the session from real data or a debug scenario. Optional so
    /// old payloads (pre-M6.6) still decode.
    public let runtimeModeRaw: String?

    public init(isTracking: Bool,
                reachable: Bool,
                currentStageRaw: Int? = nil,
                currentConfidence: Float? = nil,
                lastSyncTsMs: UInt64? = nil,
                trackingSourceRaw: String? = nil,
                alarmStateRaw: String? = nil,
                alarmTargetTsMs: UInt64? = nil,
                alarmWindowMinutes: Int? = nil,
                alarmTriggeredAtTsMs: UInt64? = nil,
                sleepPlan: SleepPlanConfiguration? = nil,
                runtimeModeRaw: String? = nil) {
        self.isTracking = isTracking
        self.reachable = reachable
        self.currentStageRaw = currentStageRaw
        self.currentConfidence = currentConfidence
        self.lastSyncTsMs = lastSyncTsMs
        self.trackingSourceRaw = trackingSourceRaw
        self.alarmStateRaw = alarmStateRaw
        self.alarmTargetTsMs = alarmTargetTsMs
        self.alarmWindowMinutes = alarmWindowMinutes
        self.alarmTriggeredAtTsMs = alarmTriggeredAtTsMs
        self.sleepPlan = sleepPlan
        self.runtimeModeRaw = runtimeModeRaw
    }

    public var alarmState: AlarmState? {
        alarmStateRaw.flatMap(AlarmState.init(rawValue:))
    }
    public var trackingSource: TrackingSourceWire? {
        trackingSourceRaw.flatMap(TrackingSourceWire.init(rawValue:))
    }
}

public struct AckPayload: Codable, Sendable, Equatable {
    public let ackKind: String
    public let batchId: String?
    public init(ackKind: String, batchId: String? = nil) {
        self.ackKind = ackKind
        self.batchId = batchId
    }
}

// MARK: - Small utilities

public enum WallClock {
    public static func nowMs() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1000)
    }
    public static func date(ms: UInt64) -> Date {
        Date(timeIntervalSince1970: Double(ms) / 1000.0)
    }
}
