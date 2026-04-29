import XCTest
@testable import SleepTracker_iOS
import SleepKit

final class SleepAIContractTests: XCTestCase {

    func testSanitizeRemovesHiddenPlanButKeepsDraftParseable() {
        let ctx = SleepAIContext(
            hasNight: true,
            durationSec: 6 * 3600 + 5 * 60,
            sleepScore: 64,
            timeInDeepSec: 42 * 60,
            timeInRemSec: 58 * 60,
            timeInLightSec: 4 * 3600 + 25 * 60,
            timeInWakeSec: 40 * 60,
            sleepPlanAutoTrackingEnabled: true,
            sleepPlanBedtimeMinute: 23 * 60 + 30,
            sleepPlanWakeMinute: 7 * 60 + 30,
            sleepPlanGoalMinutes: 480,
            sleepPlanSmartWakeWindowMinutes: 25
        )
        let raw = """
        先把今晚的睡眠计划调成 **23:40 入睡，07:20 起床**。上午用强光，下午少咖啡因。
        <CIRCADIA_PLAN>
        autoTracking=true
        bedtime=23:40
        wake=07:20
        goalMinutes=460
        smartWakeWindowMinutes=25
        </CIRCADIA_PLAN>
        """

        let draft = SleepProtocolPlanner.extractPlanDraft(
            from: raw,
            currentPlan: ctx.currentSleepPlanConfiguration
        )
        XCTAssertEqual(draft?.plan.bedtimeHour, 23)
        XCTAssertEqual(draft?.plan.bedtimeMinute, 40)
        XCTAssertEqual(draft?.plan.wakeHour, 7)
        XCTAssertEqual(draft?.plan.wakeMinute, 20)
        XCTAssertEqual(draft?.plan.sleepGoalMinutes, 460)

        let visible = MLXSleepAIService.sanitize(raw,
                                                 originalPrompt: "帮我倒时差",
                                                 ctx: ctx,
                                                 ruleBased: SleepAIService())
        XCTAssertTrue(visible.contains("23:40"))
        XCTAssertFalse(visible.contains("CIRCADIA_PLAN"))
        XCTAssertFalse(visible.contains("autoTracking"))
    }

    func testHiddenBlockFilterDoesNotStreamThinkingOrPlanDirectives() {
        var filter = HiddenBlockFilter()
        let chunks = [
            "今晚建议先",
            "<thi",
            "nk>内部推理不应出现</think>",
            "把计划调轻一点。",
            "<CIR",
            "CADIA_PLAN>\nbedtime=23:10\nwake=07:10\n</CIRCADIA_PLAN>",
            "确认后我会保存。这里有足够长的可见文字用来刷新缓冲。"
        ]

        let visible = chunks.map { filter.feed($0) }.joined()
        XCTAssertTrue(visible.contains("今晚建议"))
        XCTAssertTrue(visible.contains("计划调轻"))
        XCTAssertFalse(visible.contains("内部推理"))
        XCTAssertFalse(visible.contains("CIRCADIA_PLAN"))
        XCTAssertFalse(visible.contains("bedtime=23:10"))
    }

    func testSanitizeRemovesUnpromptedApologyButKeepsComplaintApology() {
        let plain = MLXSleepAIService.sanitize(
            "抱歉，我理解你想要倒时差计划。今晚先按 23:30 入睡。",
            originalPrompt: "帮我倒时差",
            ctx: .empty,
            ruleBased: SleepAIService()
        )
        XCTAssertFalse(plain.hasPrefix("抱歉"))

        let complaint = MLXSleepAIService.sanitize(
            "抱歉，我刚才答非所问。今晚先按 23:30 入睡。",
            originalPrompt: "你刚才答非所问",
            ctx: .empty,
            ruleBased: SleepAIService()
        )
        XCTAssertTrue(complaint.hasPrefix("抱歉"))
    }

    func testLLMContextCarriesLocalSkillResultsAndClosedSystemControlContract() {
        let ctx = SleepAIContext(
            hasNight: true,
            durationSec: 6 * 3600 + 5 * 60,
            sleepScore: 64,
            timeInDeepSec: 42 * 60,
            timeInRemSec: 58 * 60,
            timeInLightSec: 4 * 3600 + 25 * 60,
            timeInWakeSec: 40 * 60,
            recentNights: [
                SleepAINightContext(
                    id: "latest",
                    durationSec: 6 * 3600 + 5 * 60,
                    sleepScore: 64,
                    timeInDeepSec: 42 * 60,
                    timeInRemSec: 58 * 60,
                    timeInLightSec: 4 * 3600 + 25 * 60,
                    timeInWakeSec: 40 * 60,
                    snoreEventCount: 38,
                    evidenceQualityRaw: NightEvidenceQuality.moderate.rawValue,
                    evidenceConfidence: 0.68,
                    missingSignals: [NightEvidenceSignal.wakeSurvey.rawValue],
                    isEstimated: true
                )
            ],
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
        let grounded = ctx.withSkillResults(SleepAISkillRunner.run(context: ctx))
        let pack = grounded.llmContextPack()

        XCTAssertTrue(pack.contains("LOCAL_SLEEP_SKILL_RESULTS"))
        XCTAssertTrue(pack.contains("tool=sleep_status"))
        XCTAssertTrue(pack.contains("tool=evidence"))
        XCTAssertTrue(pack.contains("tool=adaptive_plan"))
        XCTAssertTrue(pack.contains("latest_microphone_snore_events=38"))
        XCTAssertTrue(pack.contains("Adaptive Sleep Model"))
        XCTAssertTrue(pack.contains("suggestedBedtime=23:10"))
        XCTAssertTrue(pack.localizedCaseInsensitiveContains("do not claim raw audio"))
        XCTAssertTrue(pack.contains("Current Sleep Plan"))

        let control = SleepProtocolPlanner.directiveInstructions
        XCTAssertTrue(control.contains(SleepProtocolPlanner.directiveOpen))
        XCTAssertTrue(control.contains("ask only the missing questions"))
        XCTAssertTrue(control.contains("Never invent travel dates"))
    }

    @MainActor
    func testViewModelBuildsPromptAwareLocalSkillContextForPlanning() async throws {
        let service = CapturingSleepAIService()
        let appState = AppState(
            engine: InMemorySleepEngineClient(),
            engineFallbackReason: nil,
            localStore: InMemoryLocalStore(),
            insights: LocalInsightsService(),
            connectivity: InMemoryConnectivityManager(),
            health: HealthPermissionService(),
            heartRateStream: MockHeartRateStream(),
            adaptiveSleepModel: AdaptiveSleepModelService(store: InMemoryAdaptiveSleepProfileStore()),
            protocolCheckIns: SleepProtocolCheckInService(store: InMemorySleepProtocolCheckInStore()),
            inferenceModel: FallbackHeuristicStageInferenceModel()
        )
        defer { appState.saveSleepPlan(.default) }
        appState.saveSleepPlan(SleepPlanConfiguration(
            autoTrackingEnabled: true,
            bedtimeHour: 23,
            bedtimeMinute: 30,
            wakeHour: 7,
            wakeMinute: 30,
            sleepGoalMinutes: 480,
            smartWakeWindowMinutes: 25,
            nightmareWakeEnabled: false
        ))

        let vm = SleepAIViewModel(serviceFactory: { _ in service })
        vm.attach(appState: appState)

        await vm.send(prompt: "帮我做一个倒时差睡眠计划")

        let captured = try XCTUnwrap(service.capturedContext)
        let plan = captured.skillResults.first { $0.id == "plan_requirements" }
        XCTAssertNotNil(plan)
        XCTAssertTrue(plan?.findings.contains { $0.contains("intent=jet_lag_sleep_plan") } == true)
        XCTAssertTrue(plan?.adviceInputs.contains("ask_for_route_or_time_zones") == true)
        XCTAssertTrue(plan?.adviceInputs.contains("ask_for_departure_and_arrival_times") == true)
    }

    @MainActor
    func testViewModelSavesPlanOnlyAfterExplicitApplyCommand() async throws {
        let proposed = SleepPlanConfiguration(
            autoTrackingEnabled: true,
            bedtimeHour: 22,
            bedtimeMinute: 45,
            wakeHour: 6,
            wakeMinute: 50,
            sleepGoalMinutes: 485,
            smartWakeWindowMinutes: 30,
            nightmareWakeEnabled: false
        )
        let service = DraftingSleepAIService(draft: SleepPlanDraft(plan: proposed))
        let appState = AppState(
            engine: InMemorySleepEngineClient(),
            engineFallbackReason: nil,
            localStore: InMemoryLocalStore(),
            insights: LocalInsightsService(),
            connectivity: InMemoryConnectivityManager(),
            health: HealthPermissionService(),
            heartRateStream: MockHeartRateStream(),
            adaptiveSleepModel: AdaptiveSleepModelService(store: InMemoryAdaptiveSleepProfileStore()),
            protocolCheckIns: SleepProtocolCheckInService(store: InMemorySleepProtocolCheckInStore()),
            inferenceModel: FallbackHeuristicStageInferenceModel()
        )
        defer { appState.saveSleepPlan(.default) }
        appState.saveSleepPlan(.default)

        let vm = SleepAIViewModel(serviceFactory: { _ in service })
        vm.attach(appState: appState)

        await vm.send(prompt: "我5月3日20:00从上海飞纽约，5月4日22:00到，5月5日上午9点开会，帮我保存倒时差计划")
        XCTAssertEqual(appState.currentSleepPlan().bedtimeHour, SleepPlanConfiguration.default.bedtimeHour)

        await vm.send(prompt: "保存")

        let saved = appState.currentSleepPlan()
        XCTAssertEqual(saved.bedtimeHour, 22)
        XCTAssertEqual(saved.bedtimeMinute, 45)
        XCTAssertEqual(saved.wakeHour, 6)
        XCTAssertEqual(saved.wakeMinute, 50)
        XCTAssertEqual(saved.sleepGoalMinutes, 485)
        XCTAssertEqual(saved.smartWakeWindowMinutes, 30)
        XCTAssertTrue(vm.messages.last?.text.contains("22:45") == true)
    }

    @MainActor
    func testViewModelActivatesProtocolCheckInOnlyAfterApplyCommand() async throws {
        let proposed = SleepPlanConfiguration(
            autoTrackingEnabled: true,
            bedtimeHour: 23,
            bedtimeMinute: 10,
            wakeHour: 7,
            wakeMinute: 10,
            sleepGoalMinutes: 500,
            smartWakeWindowMinutes: 20,
            nightmareWakeEnabled: false
        )
        let checkIn = SleepProtocolCheckInPlan(
            kind: .memory,
            title: "Memory Sleep Check-in",
            sleepPlan: proposed,
            reasons: ["protect_post_learning_sleep"],
            tasks: [
                SleepProtocolCheckInTask(id: "study_cutoff",
                                         category: .windDown,
                                         title: "Stop heavy studying",
                                         detail: "Stop 45 minutes before bed.")
            ]
        )
        let service = DraftingSleepAIService(draft: SleepPlanDraft(plan: proposed),
                                             checkIn: checkIn)
        let appState = AppState(
            engine: InMemorySleepEngineClient(),
            engineFallbackReason: nil,
            localStore: InMemoryLocalStore(),
            insights: LocalInsightsService(),
            connectivity: InMemoryConnectivityManager(),
            health: HealthPermissionService(),
            heartRateStream: MockHeartRateStream(),
            adaptiveSleepModel: AdaptiveSleepModelService(store: InMemoryAdaptiveSleepProfileStore()),
            protocolCheckIns: SleepProtocolCheckInService(store: InMemorySleepProtocolCheckInStore()),
            inferenceModel: FallbackHeuristicStageInferenceModel()
        )
        defer { appState.saveSleepPlan(.default) }
        appState.saveSleepPlan(.default)

        let vm = SleepAIViewModel(serviceFactory: { _ in service })
        vm.attach(appState: appState)

        await vm.send(prompt: "我明天考试，今晚想高效记忆，帮我保存计划")
        XCTAssertNil(appState.activeProtocolCheckInPlan)

        await vm.send(prompt: "保存")

        XCTAssertEqual(appState.activeProtocolCheckInPlan?.kind, .memory)
        XCTAssertEqual(appState.activeProtocolCheckInPlan?.tasks.first?.id, "study_cutoff")
    }

    @MainActor
    func testAppStateUpdatesAdaptiveModelAfterArchiveAndWakeSurvey() async throws {
        let adaptive = AdaptiveSleepModelService(store: InMemoryAdaptiveSleepProfileStore())
        let appState = AppState(
            engine: InMemorySleepEngineClient(),
            engineFallbackReason: nil,
            localStore: InMemoryLocalStore(),
            insights: LocalInsightsService(),
            connectivity: InMemoryConnectivityManager(),
            health: HealthPermissionService(),
            heartRateStream: MockHeartRateStream(),
            adaptiveSleepModel: adaptive,
            protocolCheckIns: SleepProtocolCheckInService(store: InMemorySleepProtocolCheckInStore()),
            inferenceModel: FallbackHeuristicStageInferenceModel()
        )
        defer { appState.saveSleepPlan(.default) }
        appState.saveSleepPlan(SleepPlanConfiguration(
            autoTrackingEnabled: true,
            bedtimeHour: 23,
            bedtimeMinute: 30,
            wakeHour: 7,
            wakeMinute: 30,
            sleepGoalMinutes: 480,
            smartWakeWindowMinutes: 25,
            nightmareWakeEnabled: false
        ))

        let start = Date(timeIntervalSince1970: 1_780_000_000)
        let summary = SessionSummary(
            sessionId: "adaptive-session",
            durationSec: 7 * 3600,
            timeInWakeSec: 30 * 60,
            timeInLightSec: 4 * 3600,
            timeInDeepSec: 75 * 60,
            timeInRemSec: 75 * 60,
            sleepScore: 72
        )
        let timeline = [
            TimelineEntry(stage: .light,
                          start: start,
                          end: start.addingTimeInterval(3600)),
            TimelineEntry(stage: .deep,
                          start: start.addingTimeInterval(3600),
                          end: start.addingTimeInterval(2 * 3600))
        ]

        await appState.archiveCompletedSession(
            summary: summary,
            startedAt: start,
            endedAt: start.addingTimeInterval(TimeInterval(summary.durationSec)),
            timeline: timeline,
            alarm: nil,
            source: .remoteWatch,
            runtimeMode: .live
        )
        var profile = await adaptive.snapshot()
        XCTAssertEqual(profile.sampleCount, 1)
        XCTAssertEqual(profile.feedbackSampleCount, 0)

        await appState.submitWakeSurvey(sessionId: "adaptive-session",
                                        survey: WakeSurvey(quality: 2,
                                                           alarmFeltGood: false))
        profile = await adaptive.snapshot()
        XCTAssertEqual(profile.sampleCount, 1)
        XCTAssertEqual(profile.feedbackSampleCount, 1)
        XCTAssertEqual(profile.recoveryQuality, 2)
        XCTAssertEqual(profile.alarmFeltGoodRate, 0)
    }
}

private final class CapturingSleepAIService: SleepAIServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _capturedContext: SleepAIContext?

    var capturedContext: SleepAIContext? {
        lock.lock()
        defer { lock.unlock() }
        return _capturedContext
    }

    var engineKind: SleepAIEngineKind { .ruleBased }

    func morningSummary(context: SleepAIContext) -> String { "summary" }

    func reply(to prompt: String, context: SleepAIContext) async -> String {
        capture(context)
        return "ok"
    }

    func suggestedFollowUps(context: SleepAIContext) -> [String] { [] }

    func streamReply(to prompt: String,
                     context: SleepAIContext) -> AsyncStream<SleepAIStreamEvent> {
        capture(context)
        return AsyncStream { continuation in
            continuation.yield(.final("ok"))
            continuation.finish()
        }
    }

    private func capture(_ context: SleepAIContext) {
        lock.lock()
        _capturedContext = context
        lock.unlock()
    }
}

private final class DraftingSleepAIService: SleepAIServiceProtocol, @unchecked Sendable {
    let draft: SleepPlanDraft
    let checkIn: SleepProtocolCheckInPlan?
    var engineKind: SleepAIEngineKind { .gemmaLocal }

    init(draft: SleepPlanDraft,
         checkIn: SleepProtocolCheckInPlan? = nil) {
        self.draft = draft
        self.checkIn = checkIn
    }

    func morningSummary(context: SleepAIContext) -> String { "summary" }

    func reply(to prompt: String, context: SleepAIContext) async -> String {
        "计划可以保存。"
    }

    func suggestedFollowUps(context: SleepAIContext) -> [String] { [] }

    func streamReply(to prompt: String,
                     context: SleepAIContext) -> AsyncStream<SleepAIStreamEvent> {
        AsyncStream { continuation in
            continuation.yield(.planDraft(draft))
            if let checkIn {
                continuation.yield(.checkInPlan(checkIn))
            }
            continuation.yield(.final("计划可以保存。"))
            continuation.finish()
        }
    }
}
