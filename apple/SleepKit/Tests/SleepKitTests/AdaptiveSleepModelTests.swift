import XCTest
@testable import SleepKit

final class AdaptiveSleepModelTests: XCTestCase {

    func testEmptyProfileReturnsCurrentPlanWithoutLearning() {
        let plan = Self.plan()

        let recommendation = AdaptiveSleepModel.recommendation(profile: .empty,
                                                               currentPlan: plan)

        XCTAssertEqual(recommendation.plan, plan)
        XCTAssertEqual(recommendation.sampleCount, 0)
        XCTAssertEqual(recommendation.confidence, 0)
        XCTAssertEqual(recommendation.reasons, ["no_adaptive_history"])
    }

    func testIngestLearnsNightOnceAndIgnoresDuplicateEvidence() {
        let plan = Self.plan()
        let evidence = Self.evidence(id: "n1",
                                     startHour: 22,
                                     startMinute: 50,
                                     wakeHour: 6,
                                     wakeMinute: 50,
                                     score: 82)

        let first = AdaptiveSleepModel.updated(profile: .empty,
                                               evidence: evidence,
                                               survey: nil,
                                               snoreEventCount: 8,
                                               currentPlan: plan,
                                               calendar: Self.utcCalendar)
        let duplicate = AdaptiveSleepModel.updated(profile: first,
                                                   evidence: evidence,
                                                   survey: nil,
                                                   snoreEventCount: 8,
                                                   currentPlan: plan,
                                                   calendar: Self.utcCalendar)

        XCTAssertEqual(first.sampleCount, 1)
        XCTAssertEqual(duplicate.sampleCount, 1)
        XCTAssertEqual(duplicate.ingestedNightIDs, ["n1"])
        XCTAssertEqual(duplicate.typicalBedtimeMinute, 22 * 60 + 50)
        XCTAssertEqual(duplicate.typicalWakeMinute, 6 * 60 + 50)
        XCTAssertEqual(duplicate.averageSleepScore, 82)
        XCTAssertNotNil(duplicate.snoreEventsPerHour)
    }

    func testSurveyCanUpdateSameNightLaterWithoutDuplicatingNightSample() {
        let plan = Self.plan()
        let evidence = Self.evidence(id: "n1",
                                     startHour: 23,
                                     startMinute: 20,
                                     wakeHour: 7,
                                     wakeMinute: 20,
                                     score: 68)

        let withoutSurvey = AdaptiveSleepModel.updated(profile: .empty,
                                                       evidence: evidence,
                                                       survey: nil,
                                                       snoreEventCount: nil,
                                                       currentPlan: plan,
                                                       calendar: Self.utcCalendar)
        let withSurvey = AdaptiveSleepModel.updated(profile: withoutSurvey,
                                                    evidence: evidence,
                                                    survey: WakeSurvey(quality: 2,
                                                                       alarmFeltGood: false),
                                                    snoreEventCount: nil,
                                                    currentPlan: plan,
                                                    calendar: Self.utcCalendar)
        let duplicateSurvey = AdaptiveSleepModel.updated(profile: withSurvey,
                                                         evidence: evidence,
                                                         survey: WakeSurvey(quality: 5,
                                                                            alarmFeltGood: true),
                                                         snoreEventCount: nil,
                                                         currentPlan: plan,
                                                         calendar: Self.utcCalendar)

        XCTAssertEqual(withSurvey.sampleCount, 1)
        XCTAssertEqual(withSurvey.feedbackSampleCount, 1)
        XCTAssertEqual(withSurvey.feedbackNightIDs, ["n1"])
        XCTAssertEqual(withSurvey.recoveryQuality, 2)
        XCTAssertEqual(withSurvey.alarmFeltGoodRate, 0)
        XCTAssertEqual(duplicateSurvey, withSurvey)
    }

    func testRecommendationUsesBoundedDynamicPlanAndReasons() {
        let plan = Self.plan()
        var profile = AdaptiveSleepProfile.empty
        for idx in 0..<5 {
            let evidence = Self.evidence(id: "n\(idx)",
                                         startHour: 22,
                                         startMinute: 30,
                                         wakeHour: 6,
                                         wakeMinute: 45,
                                         score: 64)
            profile = AdaptiveSleepModel.updated(profile: profile,
                                                 evidence: evidence,
                                                 survey: WakeSurvey(quality: 2,
                                                                    alarmFeltGood: false),
                                                 snoreEventCount: 64,
                                                 currentPlan: plan,
                                                 calendar: Self.utcCalendar)
        }

        let recommendation = AdaptiveSleepModel.recommendation(profile: profile,
                                                               currentPlan: plan)

        XCTAssertEqual(recommendation.sampleCount, 5)
        XCTAssertGreaterThan(recommendation.confidence, 0.5)
        XCTAssertEqual(recommendation.plan.bedtimeHour, 23)
        XCTAssertEqual(recommendation.plan.bedtimeMinute, 10)
        XCTAssertEqual(recommendation.plan.wakeHour, 7)
        XCTAssertEqual(recommendation.plan.wakeMinute, 10)
        XCTAssertEqual(recommendation.plan.sleepGoalMinutes, 500)
        XCTAssertEqual(recommendation.plan.smartWakeWindowMinutes, 20)
        XCTAssertTrue(recommendation.reasons.contains("learned_bedtime_drift"))
        XCTAssertTrue(recommendation.reasons.contains("learned_wake_drift"))
        XCTAssertTrue(recommendation.reasons.contains("learned_sleep_opportunity"))
        XCTAssertTrue(recommendation.reasons.contains("low_recovery_feedback"))
        XCTAssertTrue(recommendation.reasons.contains("poor_smart_alarm_feedback"))
        XCTAssertTrue(recommendation.reasons.contains("high_snore_event_density"))
    }

    func testFewSamplesDoNotMovePlanEvenWhenClusteredEarlier() {
        let plan = Self.plan()
        var profile = AdaptiveSleepProfile.empty
        for idx in 0..<2 {
            let evidence = Self.evidence(id: "few-\(idx)",
                                         startHour: 22,
                                         startMinute: 20,
                                         wakeHour: 6,
                                         wakeMinute: 30,
                                         score: 88)
            profile = AdaptiveSleepModel.updated(profile: profile,
                                                 evidence: evidence,
                                                 survey: nil,
                                                 snoreEventCount: 4,
                                                 currentPlan: plan,
                                                 calendar: Self.utcCalendar)
        }

        let recommendation = AdaptiveSleepModel.recommendation(profile: profile,
                                                               currentPlan: plan)

        XCTAssertEqual(profile.sampleCount, 2)
        XCTAssertEqual(recommendation.plan, plan)
        XCTAssertLessThanOrEqual(recommendation.confidence, 0.45)
        XCTAssertTrue(recommendation.reasons.contains("collecting_adaptive_history"))
        XCTAssertTrue(recommendation.reasons.contains("low_sample_count"))
    }

    func testThreeHighQualitySamplesAllowOnlyConservativeShift() {
        let plan = Self.plan()
        var profile = AdaptiveSleepProfile.empty
        for idx in 0..<3 {
            let evidence = Self.evidence(id: "ready-\(idx)",
                                         startHour: 22,
                                         startMinute: 20,
                                         wakeHour: 6,
                                         wakeMinute: 30,
                                         score: 84)
            profile = AdaptiveSleepModel.updated(profile: profile,
                                                 evidence: evidence,
                                                 survey: nil,
                                                 snoreEventCount: 4,
                                                 currentPlan: plan,
                                                 calendar: Self.utcCalendar)
        }

        let recommendation = AdaptiveSleepModel.recommendation(profile: profile,
                                                               currentPlan: plan)

        XCTAssertEqual(recommendation.sampleCount, 3)
        XCTAssertEqual(recommendation.plan.bedtimeHour, 23)
        XCTAssertEqual(recommendation.plan.bedtimeMinute, 20)
        XCTAssertEqual(recommendation.plan.wakeHour, 7)
        XCTAssertEqual(recommendation.plan.wakeMinute, 20)
        XCTAssertTrue(recommendation.reasons.contains("learned_bedtime_drift"))
        XCTAssertTrue(recommendation.reasons.contains("learned_wake_drift"))
        XCTAssertTrue(recommendation.reasons.contains("low_sample_count"))
    }

    func testServicePersistsProfileThroughStore() async {
        let store = InMemoryAdaptiveSleepProfileStore()
        let service = AdaptiveSleepModelService(store: store)
        let record = Self.record(id: "n1")

        await service.ingest(record: record, plan: Self.plan(), calendar: Self.utcCalendar)
        let profile = await service.snapshot()
        let recommendation = await service.recommendation(currentPlan: Self.plan())

        XCTAssertEqual(profile.sampleCount, 1)
        XCTAssertEqual(profile.ingestedNightIDs, ["n1"])
        XCTAssertEqual(recommendation.sampleCount, 1)
        XCTAssertEqual(recommendation.plan, Self.plan())
        XCTAssertTrue(recommendation.reasons.contains("collecting_adaptive_history"))
    }

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private static func plan() -> SleepPlanConfiguration {
        SleepPlanConfiguration(
            autoTrackingEnabled: true,
            bedtimeHour: 23,
            bedtimeMinute: 30,
            wakeHour: 7,
            wakeMinute: 30,
            sleepGoalMinutes: 480,
            smartWakeWindowMinutes: 25,
            nightmareWakeEnabled: false
        )
    }

    private static func evidence(id: String,
                                 startHour: Int,
                                 startMinute: Int,
                                 wakeHour: Int,
                                 wakeMinute: Int,
                                 score: Int) -> NightEvidence {
        let start = date(hour: startHour, minute: startMinute)
        let end = date(hour: wakeHour, minute: wakeMinute).addingTimeInterval(24 * 3600)
        let duration = Int(end.timeIntervalSince(start))
        return NightEvidence(
            id: id,
            startedAt: start,
            endedAt: end,
            durationSec: duration,
            asleepSec: duration - 35 * 60,
            wakeSec: 35 * 60,
            lightSec: 5 * 3600,
            deepSec: 75 * 60,
            remSec: 80 * 60,
            sleepScore: score,
            assessment: NightEvidenceAssessment(
                origin: .activeSession,
                quality: .high,
                confidence: 0.86,
                observedSignals: [.activeSession, .stageSummary, .timeline, .heartRate],
                missingSignals: [],
                isEstimated: false
            )
        )
    }

    private static func record(id: String) -> StoredSessionRecord {
        let evidence = evidence(id: id,
                                startHour: 23,
                                startMinute: 15,
                                wakeHour: 7,
                                wakeMinute: 10,
                                score: 78)
        let summary = SessionSummary(
            sessionId: id,
            durationSec: evidence.durationSec,
            timeInWakeSec: evidence.wakeSec ?? 0,
            timeInLightSec: evidence.lightSec ?? 0,
            timeInDeepSec: evidence.deepSec ?? 0,
            timeInRemSec: evidence.remSec ?? 0,
            sleepScore: evidence.sleepScore ?? 0
        )
        return StoredSessionRecord(
            id: id,
            startedAt: evidence.startedAt,
            endedAt: evidence.endedAt,
            summary: summary,
            sourceRaw: TrackingSource.remoteWatch.rawValue,
            runtimeModeRaw: "live",
            snoreEventCount: 4,
            timeline: [
                TimelineEntry(stage: .light,
                              start: evidence.startedAt,
                              end: evidence.startedAt.addingTimeInterval(3600))
            ]
        )
    }

    private static func date(hour: Int, minute: Int) -> Date {
        var components = DateComponents()
        components.calendar = utcCalendar
        components.timeZone = utcCalendar.timeZone
        components.year = 2026
        components.month = 4
        components.day = 1
        components.hour = hour
        components.minute = minute
        return components.date!
    }
}
