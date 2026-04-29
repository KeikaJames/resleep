import XCTest
@testable import SleepKit

final class SleepAISkillsTests: XCTestCase {

    func testSkillRunnerSurfacesSnoreAndEvidenceSignals() {
        let night = SleepAINightContext(
            id: "n1",
            endedAt: Date(timeIntervalSince1970: 1_700_000_000),
            durationSec: 7 * 3600,
            sleepScore: 78,
            timeInDeepSec: 60 * 60,
            timeInRemSec: 70 * 60,
            timeInLightSec: 5 * 3600,
            timeInWakeSec: 30 * 60,
            snoreEventCount: 56,
            sourceRaw: "remoteWatch",
            evidenceQualityRaw: NightEvidenceQuality.high.rawValue,
            evidenceConfidence: 0.86,
            missingSignals: [NightEvidenceSignal.wakeSurvey.rawValue]
        )
        let ctx = SleepAIContext(
            hasNight: true,
            durationSec: night.durationSec,
            sleepScore: night.sleepScore,
            timeInDeepSec: night.timeInDeepSec,
            timeInRemSec: night.timeInRemSec,
            timeInLightSec: night.timeInLightSec,
            timeInWakeSec: night.timeInWakeSec,
            recentNights: [night],
            healthAuthorization: "authorized",
            watchPaired: true
        )

        let results = SleepAISkillRunner.run(context: ctx)

        XCTAssertTrue(results.contains { $0.id == "sleep_status" })
        XCTAssertTrue(results.contains { result in
            result.id == "sleep_continuity"
                && result.facts.contains(where: { $0.contains("sleep_efficiency=") })
        })
        XCTAssertTrue(results.contains { result in
            result.id == "advice_inputs"
                && result.facts.contains(where: { $0.contains("latest_microphone_snore_events=56") })
        })
        XCTAssertTrue(results.contains { result in
            result.id == "evidence"
                && result.findings.contains(where: { $0.contains("missing_signals=wakeSurvey") })
        })
    }

    func testContextPackIncludesLocalSkillResults() {
        let skill = SleepAISkillResult(
            id: "sleep_status",
            confidence: 0.8,
            facts: ["latest_score=80"],
            findings: ["no_major_single_night_flag"],
            adviceInputs: ["reinforce_recent_successful_conditions"]
        )
        let ctx = SleepAIContext(hasNight: false, skillResults: [skill])

        let pack = ctx.llmContextPack()

        XCTAssertTrue(pack.contains("LOCAL_SLEEP_SKILLS_AVAILABLE"))
        XCTAssertTrue(pack.contains("LOCAL_SLEEP_SKILL_RESULTS"))
        XCTAssertTrue(pack.contains("skill=sleep_status"))
        XCTAssertTrue(pack.contains("skill=adaptive_plan"))
        XCTAssertTrue(pack.contains("skill=plan_requirements"))
        XCTAssertTrue(pack.contains("tool=sleep_status"))
        XCTAssertTrue(pack.contains("latest_score=80"))
    }

    func testAdaptivePlanSkillSurfacesDynamicRecommendation() {
        let ctx = SleepAIContext(
            hasNight: false,
            sleepPlanAutoTrackingEnabled: true,
            sleepPlanBedtimeMinute: 23 * 60 + 30,
            sleepPlanWakeMinute: 7 * 60 + 30,
            sleepPlanGoalMinutes: 480,
            sleepPlanSmartWakeWindowMinutes: 25,
            adaptivePlanSampleCount: 6,
            adaptivePlanConfidence: 0.72,
            adaptiveSuggestedBedtimeMinute: 23 * 60 + 10,
            adaptiveSuggestedWakeMinute: 7 * 60 + 10,
            adaptiveSuggestedGoalMinutes: 500,
            adaptiveSuggestedSmartWakeWindowMinutes: 20,
            adaptivePlanReasons: ["learned_bedtime_drift", "low_recovery_feedback"]
        )

        let results = SleepAISkillRunner.run(context: ctx)
        let adaptive = results.first { $0.id == "adaptive_plan" }

        XCTAssertNotNil(adaptive)
        XCTAssertTrue(adaptive?.facts.contains("adaptive_samples=6") == true)
        XCTAssertTrue(adaptive?.facts.contains("suggested_bedtime=23:10") == true)
        XCTAssertTrue(adaptive?.findings.contains("learned_bedtime_drift") == true)
        XCTAssertTrue(adaptive?.adviceInputs.contains("require_explicit_user_confirmation_before_save") == true)
        XCTAssertTrue(ctx.llmContextPack().contains("Adaptive Sleep Model"))
    }

    func testPromptAwareSkillAsksMissingJetLagInputs() {
        let ctx = SleepAIContext(
            hasNight: false,
            sleepPlanAutoTrackingEnabled: true,
            sleepPlanBedtimeMinute: 23 * 60 + 30,
            sleepPlanWakeMinute: 7 * 60 + 30,
            sleepPlanGoalMinutes: 480,
            sleepPlanSmartWakeWindowMinutes: 25
        )

        let results = SleepAISkillRunner.run(context: ctx,
                                             prompt: "帮我做一个倒时差睡眠计划")

        let plan = results.first { $0.id == "plan_requirements" }
        XCTAssertNotNil(plan)
        XCTAssertTrue(plan?.findings.contains { $0.contains("intent=jet_lag_sleep_plan") } == true)
        XCTAssertTrue(plan?.findings.contains { $0.contains("missing_plan_inputs=") } == true)
        XCTAssertTrue(plan?.adviceInputs.contains("ask_for_route_or_time_zones") == true)
    }

    func testPromptAwareSkillDoesNotTreatDreamFlightAsTravel() {
        let results = SleepAISkillRunner.run(context: .empty,
                                             prompt: "我做了一个奇怪的梦，感觉在飞")

        XCTAssertFalse(results.contains { $0.id == "plan_requirements" })
    }

    func testPromptAwareSkillTreatsChineseFlightRouteAsTravel() {
        let ctx = SleepAIContext(
            hasNight: false,
            sleepPlanAutoTrackingEnabled: true,
            sleepPlanBedtimeMinute: 23 * 60 + 30,
            sleepPlanWakeMinute: 7 * 60 + 30,
            sleepPlanGoalMinutes: 480,
            sleepPlanSmartWakeWindowMinutes: 25
        )

        let results = SleepAISkillRunner.run(context: ctx,
                                             prompt: "我下周从上海飞纽约，帮我安排睡眠")

        let plan = results.first { $0.id == "plan_requirements" }
        XCTAssertNotNil(plan)
        XCTAssertTrue(plan?.findings.contains { $0.contains("intent=jet_lag_sleep_plan") } == true)
        XCTAssertFalse(plan?.adviceInputs.contains("ask_for_route_or_time_zones") == true)
    }

    func testPromptAwareSkillMarksCompleteJetLagPromptReady() {
        let ctx = SleepAIContext(
            hasNight: false,
            sleepPlanAutoTrackingEnabled: true,
            sleepPlanBedtimeMinute: 23 * 60 + 30,
            sleepPlanWakeMinute: 7 * 60 + 30,
            sleepPlanGoalMinutes: 480,
            sleepPlanSmartWakeWindowMinutes: 25
        )

        let prompt = "我5月3日20:00从上海飞纽约，5月4日22:00到，5月5日上午9点开会，帮我保存倒时差计划"
        let results = SleepAISkillRunner.run(context: ctx, prompt: prompt)

        let plan = results.first { $0.id == "plan_requirements" }
        XCTAssertNotNil(plan)
        XCTAssertTrue(plan?.findings.contains("ready_for_plan_generation") == true)
        XCTAssertTrue(plan?.adviceInputs.contains("generate_saveable_sleep_plan_when_user_wants_plan") == true)
    }

    func testEstimatedSleepScorePenalizesShortRestlessNight() {
        let good = SleepScoreEstimator.estimate(
            durationSec: 8 * 3600,
            asleepSec: 7 * 3600 + 30 * 60,
            wakeSec: 20 * 60,
            deepSec: 80 * 60,
            remSec: 90 * 60
        )
        let poor = SleepScoreEstimator.estimate(
            durationSec: 5 * 3600,
            asleepSec: 4 * 3600,
            wakeSec: 60 * 60,
            deepSec: 15 * 60,
            remSec: 20 * 60
        )

        XCTAssertGreaterThan(good, poor)
        XCTAssertGreaterThanOrEqual(good, 80)
        XCTAssertLessThan(poor, 70)
    }
}
