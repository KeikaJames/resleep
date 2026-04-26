import XCTest
@testable import SleepKit

final class UnattendedReportTests: XCTestCase {

    func testAggregatesEventsForSession() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let events: [DiagnosticEvent] = [
            DiagnosticEvent(ts: t0, type: .appLaunch),
            DiagnosticEvent(ts: t0.addingTimeInterval(5), type: .sessionStart, sessionId: "S1"),
            DiagnosticEvent(ts: t0.addingTimeInterval(10), type: .watchReachable, sessionId: "S1"),
            DiagnosticEvent(ts: t0.addingTimeInterval(11), type: .telemetryBatchReceived,
                            sessionId: "S1", counters: ["hr": 5, "accel": 3]),
            DiagnosticEvent(ts: t0.addingTimeInterval(12), type: .telemetryBatchReceived,
                            sessionId: "S1", counters: ["hr": 7, "accel": 4]),
            DiagnosticEvent(ts: t0.addingTimeInterval(20), type: .inferenceTick, sessionId: "S1"),
            DiagnosticEvent(ts: t0.addingTimeInterval(25), type: .smartAlarmArmed, sessionId: "S1"),
            DiagnosticEvent(ts: t0.addingTimeInterval(30), type: .watchUnreachable, sessionId: "S1"),
            DiagnosticEvent(ts: t0.addingTimeInterval(40), type: .smartAlarmTriggered, sessionId: "S1"),
            DiagnosticEvent(ts: t0.addingTimeInterval(45), type: .smartAlarmDismissed, sessionId: "S1"),
            DiagnosticEvent(ts: t0.addingTimeInterval(50), type: .sessionStop, sessionId: "S1"),
        ]
        let r = UnattendedReportBuilder.build(events: events)
        XCTAssertEqual(r.sessionId, "S1")
        XCTAssertEqual(r.hrSampleCount, 12)
        XCTAssertEqual(r.accelWindowCount, 7)
        XCTAssertEqual(r.telemetryBatchCount, 2)
        XCTAssertEqual(r.inferenceTickCount, 1)
        XCTAssertEqual(r.watchReachableCount, 1)
        XCTAssertEqual(r.watchUnreachableCount, 1)
        XCTAssertTrue(r.alarmEnabled)
        XCTAssertEqual(r.alarmFinalState, "dismissed")
        XCTAssertNotNil(r.alarmTriggeredAt)
        XCTAssertNotNil(r.alarmDismissedAt)
        XCTAssertEqual(r.durationSec, 45)
    }

    func testRecordOverlayPopulatesAlarmAndScore() {
        let t0 = Date(timeIntervalSince1970: 1_700_500_000)
        let summary = SessionSummary(sessionId: "R1",
                                     durationSec: 3600,
                                     timeInWakeSec: 600,
                                     timeInLightSec: 1800,
                                     timeInDeepSec: 600,
                                     timeInRemSec: 600,
                                     sleepScore: 73)
        let alarm = StoredAlarmMeta(enabled: true,
                                    finalStateRaw: AlarmState.failedWatchUnreachable.rawValue,
                                    targetTsMs: Int64(t0.addingTimeInterval(3600).timeIntervalSince1970 * 1000),
                                    windowMinutes: 30)
        let rec = StoredSessionRecord(id: "R1", startedAt: t0, endedAt: t0.addingTimeInterval(3600),
                                      summary: summary, alarm: alarm,
                                      sourceRaw: TrackingSource.remoteWatch.rawValue,
                                      runtimeModeRaw: "live")
        let r = UnattendedReportBuilder.build(events: [], record: rec)
        XCTAssertEqual(r.sessionId, "R1")
        XCTAssertEqual(r.sleepScore, 73)
        XCTAssertEqual(r.durationSec, 3600)
        XCTAssertTrue(r.alarmEnabled)
        XCTAssertTrue(r.alarmFailedUnreachable)
        XCTAssertEqual(r.source, TrackingSource.remoteWatch.rawValue)
    }

    func testRenderTextIsStableAndIncludesKeyFields() {
        let r = UnattendedReport(
            sessionId: "txt",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_003_600),
            durationSec: 3600,
            runtimeMode: "simulated",
            source: "remoteWatch",
            hrSampleCount: 100,
            accelWindowCount: 50,
            telemetryBatchCount: 7,
            alarmEnabled: true,
            alarmFinalState: "dismissed",
            sleepScore: 80
        )
        let text = UnattendedReportBuilder.renderText(r)
        XCTAssertTrue(text.contains("session_id           : txt"))
        XCTAssertTrue(text.contains("hr_samples           : 100"))
        XCTAssertTrue(text.contains("alarm_final_state    : dismissed"))
        XCTAssertTrue(text.contains("sleep_score          : 80"))
    }

    func testInterruptedFinishedAddsNote() {
        let t0 = Date(timeIntervalSince1970: 1_700_700_000)
        let events: [DiagnosticEvent] = [
            DiagnosticEvent(ts: t0, type: .sessionStart, sessionId: "I"),
            DiagnosticEvent(ts: t0.addingTimeInterval(30), type: .sessionInterruptedDetected, sessionId: "I"),
            DiagnosticEvent(ts: t0.addingTimeInterval(31), type: .sessionInterruptedFinished, sessionId: "I"),
        ]
        let r = UnattendedReportBuilder.build(events: events)
        XCTAssertEqual(r.sessionId, "I")
        XCTAssertNotNil(r.endedAt)
        XCTAssertNotNil(r.notes)
        XCTAssertTrue(r.notes?.contains("Interrupted") ?? false)
    }
}
