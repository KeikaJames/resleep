import XCTest
@testable import SleepKit

#if canImport(HealthKit)
import HealthKit

final class PassiveSleepImporterTests: XCTestCase {

    func testOverlappingDuplicateStageSamplesAreNotDoubleCounted() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(60 * 60)
        let samples = [
            sample(.asleepCore, start: start, end: end),
            sample(.asleepCore, start: start, end: end)
        ]

        let nights = PassiveSleepImporter.groupIntoNights(samples)

        XCTAssertEqual(nights.count, 1)
        XCTAssertEqual(nights[0].asleepSec, 60 * 60)
        XCTAssertEqual(nights[0].coreSec, 60 * 60)
    }

    func testAwakeOverlapWinsOverAsleepStage() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(2 * 60 * 60)
        let awakeStart = start.addingTimeInterval(60 * 60)
        let awakeEnd = start.addingTimeInterval(90 * 60)
        let samples = [
            sample(.asleepCore, start: start, end: end),
            sample(.awake, start: awakeStart, end: awakeEnd)
        ]

        let nights = PassiveSleepImporter.groupIntoNights(samples)

        XCTAssertEqual(nights.count, 1)
        XCTAssertEqual(nights[0].awakeSec, 30 * 60)
        XCTAssertEqual(nights[0].coreSec, 90 * 60)
        XCTAssertEqual(nights[0].asleepSec, 90 * 60)
    }

    func testGroupingIsStableForUnsortedSamples() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let samples = [
            sample(.asleepCore,
                   start: start.addingTimeInterval(2 * 3600),
                   end: start.addingTimeInterval(3 * 3600)),
            sample(.asleepDeep,
                   start: start,
                   end: start.addingTimeInterval(3600)),
            sample(.asleepREM,
                   start: start.addingTimeInterval(3600),
                   end: start.addingTimeInterval(2 * 3600))
        ]

        let nights = PassiveSleepImporter.groupIntoNights(samples)

        XCTAssertEqual(nights.count, 1)
        XCTAssertEqual(nights[0].startedAt, start)
        XCTAssertEqual(nights[0].endedAt, start.addingTimeInterval(3 * 3600))
        XCTAssertEqual(nights[0].asleepSec, 3 * 3600)
        XCTAssertEqual(nights[0].deepSec, 3600)
        XCTAssertEqual(nights[0].remSec, 3600)
        XCTAssertEqual(nights[0].coreSec, 3600)
    }

    private func sample(_ value: HKCategoryValueSleepAnalysis,
                        start: Date,
                        end: Date) -> HKCategorySample {
        let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!
        return HKCategorySample(type: type,
                                value: value.rawValue,
                                start: start,
                                end: end)
    }
}
#endif
