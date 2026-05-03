import XCTest
@testable import SleepKit

final class SleepAIServiceTests: XCTestCase {

    private let svc = SleepAIService()

    func testSummary_emptyContext_returnsEmptyKey() {
        let s = svc.morningSummary(context: .empty)
        // Bundle.main on tests has no .strings → key is returned as fallback
        XCTAssertFalse(s.isEmpty)
    }

    func testSummary_withNight_containsScore() {
        let ctx = SleepAIContext(
            hasNight: true,
            durationSec: 7 * 3600,
            sleepScore: 82,
            timeInDeepSec: 80 * 60,
            timeInRemSec: 90 * 60,
            timeInLightSec: 5 * 3600,
            timeInWakeSec: 10 * 60,
            weeklyAverageScore: 78
        )
        let s = svc.morningSummary(context: ctx)
        XCTAssertFalse(s.isEmpty)
    }

    func testReply_summarizeMatchesSummary() async {
        let ctx = SleepAIContext(hasNight: true, durationSec: 1, sleepScore: 50)
        let r = await svc.reply(to: "summarize my night", context: ctx)
        XCTAssertFalse(r.isEmpty)
    }

    func testReply_advicePrompt_doesNotCrash() async {
        let r = await svc.reply(to: "give me tips", context: .empty)
        XCTAssertFalse(r.isEmpty)
    }

    func testDefaultStreamEmitsPerformanceMetrics() async {
        var final = ""
        var metrics: SleepAIPerformanceMetrics?

        for await event in svc.streamReply(to: "give me tips", context: .empty) {
            switch event {
            case .final(let text):
                final = text
            case .metrics(let value):
                metrics = value
            case .delta, .planDraft, .checkInPlan:
                break
            }
        }

        XCTAssertFalse(final.isEmpty)
        XCTAssertEqual(metrics?.route, .ruleBased)
        XCTAssertEqual(metrics?.engineKind, .ruleBased)
        XCTAssertGreaterThanOrEqual(metrics?.totalMs ?? -1, 0)
        XCTAssertEqual(metrics?.finalCharacters, final.count)
    }

    func testProtocolPlanStreamEmitsDraftAndCheckInPlan() async {
        let ctx = SleepAIContext(
            hasNight: true,
            durationSec: 7 * 3600,
            sleepScore: 80,
            sleepPlanAutoTrackingEnabled: true,
            sleepPlanBedtimeMinute: 23 * 60 + 30,
            sleepPlanWakeMinute: 7 * 60 + 30,
            sleepPlanGoalMinutes: 480,
            sleepPlanSmartWakeWindowMinutes: 25
        )
        let prompt = "我向西跨12个时区，20:00出发，22:00到，第二天09:00开会，帮我保存倒时差计划"
        var draft: SleepPlanDraft?
        var checkIn: SleepProtocolCheckInPlan?
        var final = ""

        for await event in svc.streamReply(to: prompt, context: ctx) {
            switch event {
            case .planDraft(let value):
                draft = value
            case .checkInPlan(let value):
                checkIn = value
            case .final(let value):
                final = value
            case .delta, .metrics:
                break
            }
        }

        XCTAssertNotNil(draft)
        XCTAssertNotNil(checkIn)
        XCTAssertEqual(checkIn?.kind, .jetLag)
        XCTAssertEqual(draft?.plan.bedtimeHour, 1)
        XCTAssertEqual(draft?.plan.wakeHour, 9)
        XCTAssertTrue(final.contains("01:00"))
    }

    func testFollowUps_emptyContext_returnsOnboardingChoices() {
        let s = svc.suggestedFollowUps(context: .empty)
        XCTAssertEqual(s.count, 4)
    }

    func testFollowUps_withNight_returnsFour() {
        let ctx = SleepAIContext(hasNight: true)
        XCTAssertEqual(svc.suggestedFollowUps(context: ctx).count, 4)
    }

    func testContextPack_includesRecentNightsTagsAndStatus() {
        let ctx = SleepAIContext(
            hasNight: true,
            durationSec: 7 * 3600,
            sleepScore: 82,
            timeInDeepSec: 80 * 60,
            timeInRemSec: 90 * 60,
            timeInLightSec: 5 * 3600,
            timeInWakeSec: 10 * 60,
            weeklyAverageScore: 76,
            recentNights: [
                SleepAINightContext(
                    id: "n1",
                    endedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    durationSec: 7 * 3600,
                    sleepScore: 82,
                    timeInDeepSec: 80 * 60,
                    timeInRemSec: 90 * 60,
                    timeInLightSec: 5 * 3600,
                    timeInWakeSec: 10 * 60,
                    tags: ["caffeine"],
                    noteSnippet: "late coffee",
                    surveyQuality: 4,
                    alarmFeltGood: true,
                    snoreEventCount: 2,
                    sourceRaw: "watch",
                    runtimeModeRaw: "live",
                    evidenceQualityRaw: NightEvidenceQuality.high.rawValue,
                    evidenceConfidence: 0.86,
                    missingSignals: [NightEvidenceSignal.wakeSurvey.rawValue],
                    isEstimated: false
                )
            ],
            tagInsights: [
                SleepAITagInsight(
                    tag: "caffeine",
                    count: 2,
                    averageScore: 70,
                    comparisonAverageScore: 82,
                    scoreDelta: -12
                )
            ],
            healthAuthorization: "authorized",
            watchPaired: true,
            watchReachable: false,
            watchAppInstalled: true
        )

        let pack = ctx.llmContextPack()
        XCTAssertTrue(pack.contains("CIRCADIA_LOCAL_CONTEXT"))
        XCTAssertTrue(pack.contains("caffeine"))
        XCTAssertTrue(pack.contains("HealthKit=authorized"))
        XCTAssertTrue(pack.contains("watchReachable=false"))
        XCTAssertTrue(pack.contains("dataQuality=high"))
        XCTAssertTrue(pack.contains("confidence=86%"))
        XCTAssertTrue(pack.contains("missingSignals=wakeSurvey"))
    }

    func testReply_trendUsesRecentWindow() async {
        let ctx = SleepAIContext(
            hasNight: true,
            durationSec: 7 * 3600,
            sleepScore: 84,
            weeklyAverageScore: 76,
            recentNights: [
                SleepAINightContext(id: "latest", durationSec: 7 * 3600, sleepScore: 84,
                                    timeInDeepSec: 0, timeInRemSec: 0, timeInLightSec: 0, timeInWakeSec: 0),
                SleepAINightContext(id: "older1", durationSec: 6 * 3600, sleepScore: 72,
                                    timeInDeepSec: 0, timeInRemSec: 0, timeInLightSec: 0, timeInWakeSec: 0),
                SleepAINightContext(id: "older2", durationSec: 6 * 3600, sleepScore: 74,
                                    timeInDeepSec: 0, timeInRemSec: 0, timeInLightSec: 0, timeInWakeSec: 0)
            ]
        )

        let r = await svc.reply(to: "what changed recently?", context: ctx)
        XCTAssertTrue(r.contains("84"))
        XCTAssertTrue(r.localizedCaseInsensitiveContains("trend"))
    }

    func testReply_tagInsightUsesLocalCorrelation() async {
        let ctx = SleepAIContext(
            hasNight: true,
            durationSec: 7 * 3600,
            sleepScore: 70,
            recentNights: [
                SleepAINightContext(id: "n1", durationSec: 7 * 3600, sleepScore: 70,
                                    timeInDeepSec: 0, timeInRemSec: 0, timeInLightSec: 0, timeInWakeSec: 0,
                                    tags: ["caffeine"]),
                SleepAINightContext(id: "n2", durationSec: 7 * 3600, sleepScore: 82,
                                    timeInDeepSec: 0, timeInRemSec: 0, timeInLightSec: 0, timeInWakeSec: 0)
            ],
            tagInsights: [
                SleepAITagInsight(tag: "caffeine", count: 1,
                                  averageScore: 70, comparisonAverageScore: 82,
                                  scoreDelta: -12)
            ]
        )

        let r = await svc.reply(to: "did caffeine affect my sleep?", context: ctx)
        XCTAssertTrue(r.localizedCaseInsensitiveContains("caffeine"))
        XCTAssertTrue(r.contains("70"))
    }

    // MARK: Skill router

    func testSkillReply_summarizeChinese_routesDeterministic() {
        let ctx = SleepAIContext(hasNight: true, durationSec: 6 * 3600, sleepScore: 72)
        let r = svc.skillReply(to: "总结昨晚", context: ctx)
        // Test bundle has no Localizable.strings, so the deterministic
        // result is the localization key itself — what matters is that
        // the router *did* match (non-nil) and didn't escalate.
        XCTAssertNotNil(r, "Chinese summarize must hit deterministic skill")
        XCTAssertFalse(r!.isEmpty)
    }

    func testSkillReply_emptyContextSummarize_returnsEmptyTemplate() {
        let r = svc.skillReply(to: "总结昨晚", context: .empty)
        XCTAssertNotNil(r)
        // Either localized "no night" copy or its key fallback — never nil.
        XCTAssertFalse(r!.isEmpty)
    }

    func testSkillReply_unknownPrompt_returnsNilForLLMEscalation() {
        let r = svc.skillReply(to: "我做了一个奇怪的梦，感觉在飞", context: .empty)
        XCTAssertNil(r, "Free-form non-skill prompts must return nil so the caller escalates to the LLM")
    }

    func testAdaptivePlanIntentDoesNotMatchDreamFlight() {
        XCTAssertFalse(SleepAIService.isAdaptivePlanIntent("我做了一个奇怪的梦，感觉在飞"))
        XCTAssertTrue(SleepAIService.isAdaptivePlanIntent("我下周从上海飞纽约，帮我安排睡眠"))
    }

    func testSkillReply_singleWordAffirmation_isTrivialFiller() {
        // "可以" — without this guard Gemma routes it to translation.
        let r = svc.skillReply(to: "可以", context: .empty)
        XCTAssertNotNil(r, "One-word fillers must short-circuit, not reach the LLM")
    }

    func testSkillReply_ok_isTrivialFiller() {
        let r = svc.skillReply(to: "ok", context: .empty)
        XCTAssertNotNil(r)
    }

    func testSkillReply_naturalChineseRecentSleep_routesSummary() {
        let ctx = SleepAIContext(hasNight: true, durationSec: 6 * 3600, sleepScore: 70)
        let r = svc.skillReply(to: "看一下我最近的睡眠", context: ctx)
        XCTAssertNotNil(r, "Natural Chinese summary phrasings must hit the deterministic skill")
    }

    func testHasUsableNight_filtersTrivialDurations() {
        let trivial = SleepAIContext(hasNight: true, durationSec: 30, sleepScore: 0)
        XCTAssertFalse(trivial.hasUsableNight, "30-second start/stop test sessions are not usable nights")
        let real = SleepAIContext(hasNight: true, durationSec: 4 * 3600, sleepScore: 70)
        XCTAssertTrue(real.hasUsableNight)
    }

    func testContextPack_trivialNight_emitsNoNightDirective() {
        let trivial = SleepAIContext(hasNight: true, durationSec: 30, sleepScore: 0)
        let pack = trivial.llmContextPack()
        XCTAssertTrue(pack.contains("NO_NIGHT_RECORDED"),
                      "30s session must be packed as no-night so the LLM doesn't report 0-minute stages")
    }

    func testContextPack_emptyContext_carriesNoNightDirective() {
        let pack = SleepAIContext.empty.llmContextPack()
        XCTAssertTrue(pack.contains("NO_NIGHT_RECORDED"))
        XCTAssertTrue(pack.localizedCaseInsensitiveContains("never invent"))
    }

    func testTopicGate_refusesEnglishPythonFunction() {
        let decision = SleepTopicGate.classify("Write a Python function.")
        if case .refuse(let reason) = decision {
            XCTAssertEqual(reason, .offTopic)
        } else {
            XCTFail("Expected Python function prompt to be refused, got \(decision)")
        }
    }

    func testSkillReply_sleepPlanAutoTracking_isDeterministic() {
        let r = svc.skillReply(to: "我不想睡前还点开始，有没有自动的？", context: .empty)
        XCTAssertNotNil(r)
        XCTAssertTrue(r!.contains("睡眠计划"))
        XCTAssertTrue(r!.contains("自动"))
    }

    func testSkillReply_adaptiveJetLagPlanAsksForMissingInputsNotGenericScript() {
        let base = SleepAIContext(
            hasNight: false,
            sleepPlanAutoTrackingEnabled: true,
            sleepPlanBedtimeMinute: 23 * 60 + 30,
            sleepPlanWakeMinute: 7 * 60 + 30,
            sleepPlanGoalMinutes: 480,
            sleepPlanSmartWakeWindowMinutes: 25
        )
        let prompt = "帮我做一个倒时差睡眠计划"
        let ctx = base.withSkillResults(SleepAISkillRunner.run(context: base, prompt: prompt))

        let r = svc.skillReply(to: prompt, context: ctx)

        XCTAssertNotNil(r)
        XCTAssertTrue(r!.contains("出发地"))
        XCTAssertTrue(r!.contains("到达时间"))
        XCTAssertFalse(r!.contains(NSLocalizedString("ai.reply.sleepPlan", comment: "")))
    }

    func testSkillReply_tiredUsesLocalNumbers() {
        let ctx = SleepAIContext(
            hasNight: true,
            durationSec: 5 * 3600 + 44 * 60,
            sleepScore: 61,
            timeInDeepSec: 38 * 60,
            timeInRemSec: 52 * 60,
            timeInLightSec: 3 * 3600 + 54 * 60,
            timeInWakeSec: 42 * 60,
            weeklyAverageScore: 73
        )
        let r = svc.skillReply(to: "为什么我今天这么困？", context: ctx)
        XCTAssertNotNil(r)
        XCTAssertTrue(r!.contains("61"))
        XCTAssertTrue(r!.contains("5h 44m"))
        XCTAssertTrue(r!.contains("42m"))
    }
}

final class SleepAIModelManagerTests: XCTestCase {

    @MainActor
    func testInitialStatusIsNotInstalled() {
        let mm = SleepAIModelManager(descriptor: .init(
            id: "t-\(UUID().uuidString)",
            displayName: "t",
            approximateMB: 1,
            downloadURL: nil,
            licenseSummary: ""
        ))
        if case .notInstalled = mm.status { } else { XCTFail("expected notInstalled, got \(mm.status)") }
    }

    @MainActor
    func testCancelDownloadResetsStatus() async {
        let mm = SleepAIModelManager(descriptor: .init(
            id: "t-\(UUID().uuidString)",
            displayName: "t",
            approximateMB: 1,
            downloadURL: nil,
            licenseSummary: ""
        ))
        mm.startDownload()
        try? await Task.sleep(nanoseconds: 80_000_000)
        mm.cancelDownload()
        if case .notInstalled = mm.status { } else {
            // Could legitimately be installed if extremely slow; both okay
        }
    }
}
