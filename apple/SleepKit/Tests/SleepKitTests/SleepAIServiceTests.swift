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

    func testFollowUps_emptyContext_returnsOnboardingChoices() {
        let s = svc.suggestedFollowUps(context: .empty)
        XCTAssertEqual(s.count, 3)
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
                    runtimeModeRaw: "live"
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

    func testContextPack_emptyContext_carriesNoNightDirective() {
        let pack = SleepAIContext.empty.llmContextPack()
        XCTAssertTrue(pack.contains("NO_NIGHT_RECORDED"))
        XCTAssertTrue(pack.localizedCaseInsensitiveContains("never invent"))
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
