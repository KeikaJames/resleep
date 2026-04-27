import XCTest
@testable import SleepKit

/// Verifies that `LocalInsightsService` fires the right rule mix and
/// surfaces the expected stable suggestion ids. Localization itself is
/// validated via the `Bundle.main` lookup happening in the host app —
/// here we only assert that titles/details are non-empty (i.e. a key
/// was found) and that ids are stable for downstream UI dispatch.
final class LocalInsightsServiceTests: XCTestCase {
    private let svc = LocalInsightsService()

    private func summary(durationSec: Int,
                         deep: Int = 5400,
                         rem: Int = 5400,
                         light: Int = 14400,
                         wake: Int = 600,
                         score: Int = 80) -> SessionSummary {
        SessionSummary(
            sessionId: "test",
            durationSec: durationSec,
            timeInWakeSec: wake,
            timeInLightSec: light,
            timeInDeepSec: deep,
            timeInRemSec: rem,
            sleepScore: score
        )
    }

    func testHealthyNightHasNoSuggestions() {
        let s = summary(durationSec: 8 * 3600,
                        deep: 5400, rem: 5400, light: 14400, wake: 600)
        XCTAssertEqual(svc.suggestions(from: s), [])
    }

    func testShortNightFiresDurationSuggestion() {
        let s = summary(durationSec: 5 * 3600)
        let ids = svc.suggestions(from: s).map(\.id)
        XCTAssertTrue(ids.contains("duration.short"))
    }

    func testLowDeepFiresDeepSuggestion() {
        let s = summary(durationSec: 8 * 3600, deep: 1200)
        let ids = svc.suggestions(from: s).map(\.id)
        XCTAssertTrue(ids.contains("deep.low"))
    }

    func testHighWakeFiresRestlessSuggestion() {
        let s = summary(durationSec: 8 * 3600, wake: 5400)
        let ids = svc.suggestions(from: s).map(\.id)
        XCTAssertTrue(ids.contains("wake.high"))
    }

    func testSuggestionTitlesAreNonEmpty() {
        let s = summary(durationSec: 4 * 3600,
                        deep: 600, rem: 600, light: 7200, wake: 6000)
        let suggestions = svc.suggestions(from: s)
        XCTAssertFalse(suggestions.isEmpty)
        for sug in suggestions {
            XCTAssertFalse(sug.title.isEmpty, "suggestion '\(sug.id)' has empty title")
            XCTAssertFalse(sug.detail.isEmpty, "suggestion '\(sug.id)' has empty detail")
        }
    }

    func testWeeklyAverage() {
        let nights = (0..<7).map {
            summary(durationSec: 7 * 3600, score: 70 + $0)
        }
        let avg = svc.weeklyAverageScore(summaries: nights)
        XCTAssertEqual(avg, 73.0, accuracy: 0.001)
    }
}
