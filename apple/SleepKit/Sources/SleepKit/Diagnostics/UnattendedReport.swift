import Foundation

/// Aggregated overnight-readiness report for a single session, derived
/// purely from a `DiagnosticEvent` stream plus an optional persisted
/// `StoredSessionRecord`. All fields are local-only.
public struct UnattendedReport: Codable, Sendable, Equatable {
    public var sessionId: String?
    public var startedAt: Date?
    public var endedAt: Date?
    public var durationSec: Int?
    public var runtimeMode: String?
    public var source: String?

    public var hrSampleCount: Int
    public var accelWindowCount: Int
    public var telemetryBatchCount: Int
    public var inferenceTickCount: Int
    public var watchUnreachableCount: Int
    public var watchReachableCount: Int

    public var alarmEnabled: Bool
    public var alarmFinalState: String?
    public var alarmTriggeredAt: Date?
    public var alarmDismissedAt: Date?
    public var alarmFailedUnreachable: Bool

    public var localStoreWriteCount: Int
    public var errorCount: Int
    public var notableErrors: [String]

    public var sleepScore: Int?
    public var notes: String?

    public init(
        sessionId: String? = nil,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        durationSec: Int? = nil,
        runtimeMode: String? = nil,
        source: String? = nil,
        hrSampleCount: Int = 0,
        accelWindowCount: Int = 0,
        telemetryBatchCount: Int = 0,
        inferenceTickCount: Int = 0,
        watchUnreachableCount: Int = 0,
        watchReachableCount: Int = 0,
        alarmEnabled: Bool = false,
        alarmFinalState: String? = nil,
        alarmTriggeredAt: Date? = nil,
        alarmDismissedAt: Date? = nil,
        alarmFailedUnreachable: Bool = false,
        localStoreWriteCount: Int = 0,
        errorCount: Int = 0,
        notableErrors: [String] = [],
        sleepScore: Int? = nil,
        notes: String? = nil
    ) {
        self.sessionId = sessionId
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSec = durationSec
        self.runtimeMode = runtimeMode
        self.source = source
        self.hrSampleCount = hrSampleCount
        self.accelWindowCount = accelWindowCount
        self.telemetryBatchCount = telemetryBatchCount
        self.inferenceTickCount = inferenceTickCount
        self.watchUnreachableCount = watchUnreachableCount
        self.watchReachableCount = watchReachableCount
        self.alarmEnabled = alarmEnabled
        self.alarmFinalState = alarmFinalState
        self.alarmTriggeredAt = alarmTriggeredAt
        self.alarmDismissedAt = alarmDismissedAt
        self.alarmFailedUnreachable = alarmFailedUnreachable
        self.localStoreWriteCount = localStoreWriteCount
        self.errorCount = errorCount
        self.notableErrors = notableErrors
        self.sleepScore = sleepScore
        self.notes = notes
    }
}

public enum UnattendedReportBuilder {

    /// Build a report for a specific session (or the most-recent one if
    /// `sessionId` is nil) by replaying the diagnostic events between its
    /// `sessionStart` and `sessionStop`/`sessionInterruptedFinished`.
    public static func build(
        events: [DiagnosticEvent],
        record: StoredSessionRecord? = nil,
        sessionId: String? = nil
    ) -> UnattendedReport {
        let target: String? = sessionId
            ?? record?.id
            ?? events.last(where: { $0.type == .sessionStart })?.sessionId
        let scoped: [DiagnosticEvent]
        if let target {
            scoped = events.filter { $0.sessionId == target || $0.sessionId == nil }
        } else {
            scoped = events
        }

        var report = UnattendedReport(sessionId: target)

        if let rec = record {
            report.startedAt = rec.startedAt
            report.endedAt = rec.endedAt
            if let s = rec.summary {
                report.durationSec = s.durationSec
                report.sleepScore = s.sleepScore
            }
            report.runtimeMode = rec.runtimeModeRaw
            report.source = rec.sourceRaw
            if let a = rec.alarm {
                report.alarmEnabled = a.enabled
                report.alarmFinalState = a.finalStateRaw
                report.alarmTriggeredAt = a.triggeredAt
                report.alarmDismissedAt = a.dismissedAt
                report.alarmFailedUnreachable = (a.finalState == .failedWatchUnreachable)
            }
            report.notes = rec.notes
        }

        for ev in scoped {
            switch ev.type {
            case .sessionStart:
                if report.startedAt == nil { report.startedAt = ev.ts }
            case .sessionStop:
                if report.endedAt == nil { report.endedAt = ev.ts }
            case .sessionInterruptedFinished:
                if report.endedAt == nil { report.endedAt = ev.ts }
                report.notes = (report.notes.map { $0 + "; " } ?? "") + "Interrupted; finished by user."
            case .sessionInterruptedDiscarded:
                report.notes = (report.notes.map { $0 + "; " } ?? "") + "Interrupted; discarded by user."
            case .telemetryBatchReceived:
                report.telemetryBatchCount += 1
                if let c = ev.counters {
                    report.hrSampleCount += c["hr"] ?? 0
                    report.accelWindowCount += c["accel"] ?? 0
                }
            case .heartRateSampleCount:
                report.hrSampleCount += ev.counters?["count"] ?? 0
            case .accelWindowCount:
                report.accelWindowCount += ev.counters?["count"] ?? 0
            case .inferenceTick:
                report.inferenceTickCount += 1
            case .watchReachable:
                report.watchReachableCount += 1
            case .watchUnreachable:
                report.watchUnreachableCount += 1
            case .smartAlarmArmed:
                report.alarmEnabled = true
            case .smartAlarmTriggered:
                if report.alarmTriggeredAt == nil { report.alarmTriggeredAt = ev.ts }
                if report.alarmFinalState == nil { report.alarmFinalState = "triggered" }
            case .smartAlarmDismissed:
                if report.alarmDismissedAt == nil { report.alarmDismissedAt = ev.ts }
                report.alarmFinalState = "dismissed"
            case .smartAlarmFailedWatchUnreachable:
                report.alarmFailedUnreachable = true
                if report.alarmFinalState == nil { report.alarmFinalState = "failedWatchUnreachable" }
            case .localStoreWrite:
                report.localStoreWriteCount += 1
            case .localStoreError:
                report.errorCount += 1
                if let e = ev.error, report.notableErrors.count < 8 {
                    report.notableErrors.append("local_store: \(e)")
                }
            default:
                break
            }
            if let e = ev.error, ev.type != .localStoreError, report.notableErrors.count < 8 {
                report.notableErrors.append("\(ev.type.rawValue): \(e)")
                report.errorCount += 1
            }
        }

        if report.durationSec == nil,
           let s = report.startedAt, let e = report.endedAt {
            report.durationSec = max(0, Int(e.timeIntervalSince(s)))
        }

        return report
    }

    /// Plain-text rendering suitable for Settings → Diagnostics or for
    /// pasteboard export. Stable, line-oriented, no localization.
    public static func renderText(_ r: UnattendedReport) -> String {
        var lines: [String] = []
        lines.append("Sleep Tracker — Unattended Report")
        lines.append("---------------------------------")
        lines.append("session_id           : \(r.sessionId ?? "—")")
        lines.append("started_at           : \(format(r.startedAt))")
        lines.append("ended_at             : \(format(r.endedAt))")
        lines.append("duration_sec         : \(r.durationSec.map(String.init) ?? "—")")
        lines.append("runtime_mode         : \(r.runtimeMode ?? "—")")
        lines.append("source               : \(r.source ?? "—")")
        lines.append("hr_samples           : \(r.hrSampleCount)")
        lines.append("accel_windows        : \(r.accelWindowCount)")
        lines.append("telemetry_batches    : \(r.telemetryBatchCount)")
        lines.append("inference_ticks      : \(r.inferenceTickCount)")
        lines.append("watch_reachable_evt  : \(r.watchReachableCount)")
        lines.append("watch_unreachable_evt: \(r.watchUnreachableCount)")
        lines.append("alarm_enabled        : \(r.alarmEnabled)")
        lines.append("alarm_final_state    : \(r.alarmFinalState ?? "—")")
        lines.append("alarm_triggered_at   : \(format(r.alarmTriggeredAt))")
        lines.append("alarm_dismissed_at   : \(format(r.alarmDismissedAt))")
        lines.append("alarm_failed_uw      : \(r.alarmFailedUnreachable)")
        lines.append("local_store_writes   : \(r.localStoreWriteCount)")
        lines.append("errors               : \(r.errorCount)")
        if !r.notableErrors.isEmpty {
            lines.append("notable_errors:")
            for e in r.notableErrors { lines.append("  - \(e)") }
        }
        if let s = r.sleepScore { lines.append("sleep_score          : \(s)") }
        if let n = r.notes { lines.append("notes                : \(n)") }
        return lines.joined(separator: "\n")
    }

    private static func format(_ d: Date?) -> String {
        guard let d else { return "—" }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }
}
