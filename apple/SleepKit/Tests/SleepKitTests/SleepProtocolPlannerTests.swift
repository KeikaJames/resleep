import XCTest
@testable import SleepKit

final class SleepProtocolPlannerTests: XCTestCase {

    func testExtractsHiddenPlanDirective() {
        let text = """
        今晚计划很简单：23:30 上床，7:30 起床。回复应用计划我会保存。
        <CIRCADIA_PLAN>
        autoTracking=true
        bedtime=23:30
        wake=07:30
        goalMinutes=480
        smartWakeWindowMinutes=25
        </CIRCADIA_PLAN>
        """

        let draft = SleepProtocolPlanner.extractPlanDraft(from: text, currentPlan: .default)

        XCTAssertEqual(draft?.plan.bedtimeHour, 23)
        XCTAssertEqual(draft?.plan.bedtimeMinute, 30)
        XCTAssertEqual(draft?.plan.wakeHour, 7)
        XCTAssertEqual(draft?.plan.wakeMinute, 30)
        XCTAssertEqual(draft?.plan.sleepGoalMinutes, 480)
        XCTAssertTrue(draft?.plan.autoTrackingEnabled == true)
    }

    func testVisibleTextRemovesHiddenPlanDirective() {
        let text = """
        调整到 00:00-08:00。
        <CIRCADIA_PLAN>
        bedtime=00:00
        wake=08:00
        </CIRCADIA_PLAN>
        """

        let visible = SleepProtocolPlanner.visibleText(from: text)

        XCTAssertEqual(visible, "调整到 00:00-08:00。")
    }

    func testInvalidDirectiveDoesNotCreateDraft() {
        let text = """
        先告诉我你几点必须起。
        <CIRCADIA_PLAN>
        bedtime=late
        wake=08:00
        </CIRCADIA_PLAN>
        """

        XCTAssertNil(SleepProtocolPlanner.extractPlanDraft(from: text, currentPlan: .default))
    }

    func testLooseDirectiveIsParsedOnlyWhenAllowed() {
        let text = """
        保存前建议这样执行：到达后 23:30 入睡，07:30 起床，早上接触亮光。
        autoTracking=true; bedtime=23:30; wake=07:30; goalMinutes=480; smartWakeWindowMinutes=25</CIRCADO_PLAN>
        """

        XCTAssertNil(SleepProtocolPlanner.extractPlanDraft(from: text, currentPlan: .default))

        let draft = SleepProtocolPlanner.extractPlanDraft(
            from: text,
            currentPlan: .default,
            allowLooseDirective: true
        )
        XCTAssertEqual(draft?.plan.bedtimeHour, 23)
        XCTAssertEqual(draft?.plan.wakeHour, 7)
        XCTAssertEqual(draft?.plan.smartWakeWindowMinutes, 25)
    }

    func testVisibleTextRemovesMalformedLooseDirectiveLine() {
        let text = """
        保存前建议这样执行：到达后 23:30 入睡，07:30 起床。
        autoTracking=true; bedtime=23:30; wake=07:30; goalMinutes=480; smartWakeWindowMinutes=25</CIRCAD0000
        """

        XCTAssertEqual(
            SleepProtocolPlanner.visibleText(from: text),
            "保存前建议这样执行：到达后 23:30 入睡，07:30 起床。"
        )
    }

    func testLooseDraftRequiresSaveIntentAndSpecificTimes() {
        XCTAssertTrue(SleepProtocolPlanner.allowsLoosePlanDraft(
            for: "我5月3日20:00飞，5月4日22:00到，给我可以保存的睡眠计划"
        ))
        XCTAssertFalse(SleepProtocolPlanner.allowsLoosePlanDraft(for: "我要去纽约，帮我倒时差"))
    }

    func testApplyCommandMatchesExplicitConfirmationOnly() {
        XCTAssertTrue(SleepProtocolPlanner.isApplyCommand("应用计划"))
        XCTAssertTrue(SleepProtocolPlanner.isApplyCommand("Apply plan"))
        XCTAssertFalse(SleepProtocolPlanner.isApplyCommand("可以倒时差吗"))
    }
}
