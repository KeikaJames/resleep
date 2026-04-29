import XCTest
@testable import SleepKit

final class NightEvidenceTests: XCTestCase {

    func testActiveRemoteWatchRecordWithTimelineScoresHigh() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let summary = SessionSummary(
            sessionId: "active",
            durationSec: 7 * 3600,
            timeInWakeSec: 20 * 60,
            timeInLightSec: 4 * 3600,
            timeInDeepSec: 90 * 60,
            timeInRemSec: 80 * 60,
            sleepScore: 86
        )
        let record = StoredSessionRecord(
            id: "active",
            startedAt: start,
            endedAt: start.addingTimeInterval(TimeInterval(summary.durationSec)),
            summary: summary,
            alarm: StoredAlarmMeta(enabled: true, finalStateRaw: AlarmState.dismissed.rawValue),
            sourceRaw: TrackingSource.remoteWatch.rawValue,
            runtimeModeRaw: "live",
            survey: WakeSurvey(quality: 4, alarmFeltGood: true),
            timeline: [
                TimelineEntry(stage: .light, start: start, end: start.addingTimeInterval(3600)),
                TimelineEntry(stage: .deep,
                              start: start.addingTimeInterval(3600),
                              end: start.addingTimeInterval(7200))
            ]
        )

        let evidence = NightEvidence(record: record)
        XCTAssertEqual(evidence.assessment.origin, .activeSession)
        XCTAssertEqual(evidence.assessment.quality, .high)
        XCTAssertFalse(evidence.assessment.isEstimated)
        XCTAssertGreaterThanOrEqual(evidence.assessment.confidence, 0.78)
        XCTAssertTrue(evidence.assessment.observedSignals.contains(.heartRate))
        XCTAssertTrue(evidence.assessment.observedSignals.contains(.accelerometer))
        XCTAssertFalse(evidence.assessment.missingSignals.contains(.timeline))
    }

    func testPassiveAppleWatchNightIsEstimatedAndModerateOrBetter() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let night = PassiveSleepNight(
            id: "passive",
            startedAt: start,
            endedAt: start.addingTimeInterval(7 * 3600),
            inBedSec: 7 * 3600 + 20 * 60,
            asleepSec: 7 * 3600,
            awakeSec: 20 * 60,
            coreSec: 4 * 3600,
            deepSec: 90 * 60,
            remSec: 90 * 60,
            sourceBundleIDs: ["com.apple.health"]
        )

        let evidence = NightEvidence(passiveNight: night)
        XCTAssertEqual(evidence.assessment.origin, .passiveHealthKit)
        XCTAssertTrue(evidence.assessment.isEstimated)
        XCTAssertGreaterThanOrEqual(evidence.assessment.quality, .moderate)
        XCTAssertTrue(evidence.assessment.observedSignals.contains(.appleWatchSleepAnalysis))
        XCTAssertTrue(evidence.assessment.missingSignals.contains(.wakeSurvey))
    }

    func testSparsePassiveNightKeepsUncertaintyVisible() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let night = PassiveSleepNight(
            id: "sparse",
            startedAt: start,
            endedAt: start.addingTimeInterval(50 * 60),
            inBedSec: 50 * 60,
            asleepSec: 50 * 60,
            awakeSec: 0,
            coreSec: 0,
            deepSec: 0,
            remSec: 0,
            sourceBundleIDs: []
        )

        let evidence = NightEvidence(passiveNight: night)
        XCTAssertEqual(evidence.assessment.quality, .low)
        XCTAssertLessThan(evidence.assessment.confidence, 0.50)
        XCTAssertTrue(evidence.assessment.limitations.contains("short_passive_sleep"))
        XCTAssertTrue(evidence.assessment.limitations.contains("unknown_healthkit_source"))
    }
}
