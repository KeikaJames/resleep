import XCTest
@testable import SleepKit

final class SleepProtocolOptimizerTests: XCTestCase {

    func testJetLagPromptWithMissingInputsAsksOnlyForMissingConstraints() {
        let ctx = Self.context()

        let result = SleepProtocolOptimizer.optimize(
            prompt: "帮我做一个倒时差睡眠计划",
            context: ctx
        )

        XCTAssertEqual(result?.kind, .jetLag)
        XCTAssertNil(result?.draft)
        XCTAssertTrue(result?.missingInputs.contains("route_or_time_zones") == true)
        XCTAssertTrue(result?.visibleText.contains("缺这几项") == true)
    }

    func testCompleteShanghaiToNewYorkPromptCreatesSaveablePlanAndCheckIn() throws {
        let ctx = Self.context()
        let result = try XCTUnwrap(SleepProtocolOptimizer.optimize(
            prompt: "我5月3日20:00从上海飞纽约，5月4日22:00到，5月5日上午9点开会，帮我保存倒时差计划",
            context: ctx,
            now: Date(timeIntervalSince1970: 1_780_000_000)
        ))

        XCTAssertEqual(result.kind, .jetLag)
        XCTAssertNotNil(result.draft)
        XCTAssertTrue(result.reasons.contains("delay_sleep_window"))
        XCTAssertEqual(result.draft?.plan.bedtimeHour, 1)
        XCTAssertEqual(result.draft?.plan.bedtimeMinute, 0)
        XCTAssertEqual(result.draft?.plan.wakeHour, 9)
        XCTAssertEqual(result.draft?.plan.wakeMinute, 0)
        XCTAssertTrue(result.visibleText.contains("01:00"))

        let checkIn = SleepProtocolCheckInFactory.makePlan(from: result,
                                                           prompt: "上海飞纽约",
                                                           now: Date(timeIntervalSince1970: 1_780_000_000))
        XCTAssertEqual(checkIn?.kind, .jetLag)
        XCTAssertEqual(checkIn?.tasks.count, 5)
        XCTAssertTrue(checkIn?.tasks.contains { $0.id == "light" } == true)
        XCTAssertTrue(checkIn?.tasks.contains { $0.id == "sleep_window" } == true)
    }

    func testMemoryPromptCreatesCheckInTasks() throws {
        let ctx = Self.context(
            adaptivePlanSampleCount: 6,
            adaptivePlanConfidence: 0.72,
            adaptiveSuggestedBedtimeMinute: 23 * 60 + 10,
            adaptiveSuggestedWakeMinute: 7 * 60 + 10,
            adaptiveSuggestedGoalMinutes: 500,
            adaptiveSuggestedSmartWakeWindowMinutes: 20
        )

        let result = try XCTUnwrap(SleepProtocolOptimizer.optimize(
            prompt: "我明天考试，今晚想高效记忆",
            context: ctx
        ))

        XCTAssertEqual(result.kind, .memory)
        XCTAssertNotNil(result.draft)
        XCTAssertTrue(result.reasons.contains("uses_adaptive_sleep_window"))
        let checkIn = SleepProtocolCheckInFactory.makePlan(from: result,
                                                           prompt: "高效记忆")
        XCTAssertEqual(checkIn?.kind, .memory)
        XCTAssertTrue(checkIn?.tasks.contains { $0.id == "morning_review" } == true)
        XCTAssertTrue(checkIn?.tasks.contains { $0.id == "study_cutoff" } == true)
    }

    func testCheckInServiceCompletesTask() async throws {
        let ctx = Self.context()
        let result = try XCTUnwrap(SleepProtocolOptimizer.optimize(
            prompt: "我明天考试，今晚想高效记忆",
            context: ctx
        ))
        let plan = try XCTUnwrap(SleepProtocolCheckInFactory.makePlan(from: result,
                                                                      prompt: "高效记忆"))
        let service = SleepProtocolCheckInService(store: InMemorySleepProtocolCheckInStore())

        _ = await service.activate(plan)
        let updated = await service.completeTask(id: "study_cutoff",
                                                 at: Date(timeIntervalSince1970: 1_780_000_000))

        XCTAssertEqual(updated?.completedCount, 1)
        XCTAssertTrue(updated?.tasks.first { $0.id == "study_cutoff" }?.isCompleted == true)
    }

    private static func context(adaptivePlanSampleCount: Int = 0,
                                adaptivePlanConfidence: Double? = nil,
                                adaptiveSuggestedBedtimeMinute: Int? = nil,
                                adaptiveSuggestedWakeMinute: Int? = nil,
                                adaptiveSuggestedGoalMinutes: Int? = nil,
                                adaptiveSuggestedSmartWakeWindowMinutes: Int? = nil) -> SleepAIContext {
        SleepAIContext(
            hasNight: true,
            durationSec: 7 * 3600,
            sleepScore: 82,
            sleepPlanAutoTrackingEnabled: true,
            sleepPlanBedtimeMinute: 23 * 60 + 30,
            sleepPlanWakeMinute: 7 * 60 + 30,
            sleepPlanGoalMinutes: 480,
            sleepPlanSmartWakeWindowMinutes: 25,
            adaptivePlanSampleCount: adaptivePlanSampleCount,
            adaptivePlanConfidence: adaptivePlanConfidence,
            adaptiveSuggestedBedtimeMinute: adaptiveSuggestedBedtimeMinute,
            adaptiveSuggestedWakeMinute: adaptiveSuggestedWakeMinute,
            adaptiveSuggestedGoalMinutes: adaptiveSuggestedGoalMinutes,
            adaptiveSuggestedSmartWakeWindowMinutes: adaptiveSuggestedSmartWakeWindowMinutes
        )
    }
}
