import XCTest
@testable import SleepKit

final class PersonalSleepBaselineTests: XCTestCase {

    func testCircularBedtimeMeanKeepsMidnightCluster() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let assessment = NightEvidenceAssessment(
            origin: .activeSession,
            quality: .high,
            confidence: 0.9,
            observedSignals: [.activeSession],
            missingSignals: [],
            isEstimated: false
        )
        let first = evidence(id: "first",
                             startedAt: date(calendar, year: 2026, month: 4, day: 1, hour: 23, minute: 50),
                             assessment: assessment)
        let second = evidence(id: "second",
                              startedAt: date(calendar, year: 2026, month: 4, day: 2, hour: 0, minute: 10),
                              assessment: assessment)

        let baseline = PersonalSleepBaselineBuilder.build(evidence: [first, second],
                                                          now: date(calendar, year: 2026, month: 4, day: 3),
                                                          calendar: calendar)

        XCTAssertEqual(baseline.sampleCount, 2)
        XCTAssertEqual(baseline.highQualitySampleCount, 2)
        XCTAssertEqual(baseline.typicalBedtimeMinute, 0)
    }

    func testBuildFromRecordsUsesNewestSamplesForScoreAverage() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let older = record(id: "older",
                           start: date(calendar, year: 2026, month: 4, day: 1, hour: 23),
                           score: 50)
        let newer = record(id: "newer",
                           start: date(calendar, year: 2026, month: 4, day: 2, hour: 23),
                           score: 90)

        let baseline = PersonalSleepBaselineBuilder.buildFromRecords([older, newer],
                                                                     now: date(calendar, year: 2026, month: 4, day: 3),
                                                                     calendar: calendar,
                                                                     maxSamples: 1)

        XCTAssertEqual(baseline.sampleCount, 1)
        XCTAssertEqual(baseline.averageSleepScore, 90)
    }

    func testShortEvidenceIsExcluded() {
        let assessment = NightEvidenceAssessment(
            origin: .passiveHealthKit,
            quality: .low,
            confidence: 0.2,
            observedSignals: [.healthSleepAnalysis],
            missingSignals: [.heartRate],
            isEstimated: true
        )
        let short = NightEvidence(id: "nap",
                                  startedAt: Date(timeIntervalSince1970: 0),
                                  endedAt: Date(timeIntervalSince1970: 20 * 60),
                                  durationSec: 20 * 60,
                                  assessment: assessment)

        let baseline = PersonalSleepBaselineBuilder.build(evidence: [short])

        XCTAssertEqual(baseline, .empty)
    }

    private func evidence(id: String,
                          startedAt: Date,
                          assessment: NightEvidenceAssessment) -> NightEvidence {
        NightEvidence(id: id,
                      startedAt: startedAt,
                      endedAt: startedAt.addingTimeInterval(7 * 3600),
                      durationSec: 7 * 3600,
                      asleepSec: 6 * 3600,
                      wakeSec: 20 * 60,
                      deepSec: 80 * 60,
                      remSec: 80 * 60,
                      sleepScore: 86,
                      assessment: assessment)
    }

    private func record(id: String, start: Date, score: Int) -> StoredSessionRecord {
        let summary = SessionSummary(sessionId: id,
                                     durationSec: 7 * 3600,
                                     timeInWakeSec: 20 * 60,
                                     timeInLightSec: 4 * 3600,
                                     timeInDeepSec: 80 * 60,
                                     timeInRemSec: 80 * 60,
                                     sleepScore: score)
        return StoredSessionRecord(
            id: id,
            startedAt: start,
            endedAt: start.addingTimeInterval(TimeInterval(summary.durationSec)),
            summary: summary,
            sourceRaw: TrackingSource.remoteWatch.rawValue,
            timeline: [
                TimelineEntry(stage: .light, start: start, end: start.addingTimeInterval(3600))
            ]
        )
    }

    private func date(_ calendar: Calendar,
                      year: Int,
                      month: Int,
                      day: Int,
                      hour: Int = 0,
                      minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(timeZone: calendar.timeZone,
                                           year: year,
                                           month: month,
                                           day: day,
                                           hour: hour,
                                           minute: minute))!
    }
}
