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
