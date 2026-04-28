import Foundation
#if canImport(HealthKit)
import HealthKit
#endif

/// A nightly sleep summary backfilled from HealthKit when Circadia itself
/// did not actively track that night. The source is typically Apple Watch's
/// first-party sleep analysis (asleepCore / asleepDeep / asleepREM / awake /
/// inBed), available since watchOS 9.
///
/// This is the "even if the user forgot to start Circadia, we still have
/// something" path. Passive nights are kept separate from actively-tracked
/// `SleepSession`s so the History tab can show a clear provenance badge
/// and so the on-device engine score is not contaminated by Apple's
/// classifier output (which uses different definitions).
public struct PassiveSleepNight: Identifiable, Hashable, Sendable {
    public let id: String
    public let startedAt: Date
    public let endedAt: Date
    public let inBedSec: Int
    public let asleepSec: Int
    public let awakeSec: Int
    public let coreSec: Int
    public let deepSec: Int
    public let remSec: Int
    /// Bundle identifiers of HealthKit sources that contributed samples.
    /// Useful to differentiate Apple Watch from third-party trackers.
    public let sourceBundleIDs: [String]

    public init(
        id: String,
        startedAt: Date,
        endedAt: Date,
        inBedSec: Int,
        asleepSec: Int,
        awakeSec: Int,
        coreSec: Int,
        deepSec: Int,
        remSec: Int,
        sourceBundleIDs: [String]
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.inBedSec = inBedSec
        self.asleepSec = asleepSec
        self.awakeSec = awakeSec
        self.coreSec = coreSec
        self.deepSec = deepSec
        self.remSec = remSec
        self.sourceBundleIDs = sourceBundleIDs
    }

    public var durationSec: Int { max(0, Int(endedAt.timeIntervalSince(startedAt))) }

    /// Whether the dominant source looks like Apple Watch (com.apple.health
    /// or com.apple.healthkit). Used by the UI to badge "Apple Watch" vs a
    /// third-party tracker.
    public var isAppleWatchOriginated: Bool {
        sourceBundleIDs.contains { id in
            id.hasPrefix("com.apple.health") || id.hasPrefix("com.apple.healthkit")
        }
    }
}

public enum PassiveSleepImportError: Error, Sendable {
    case unavailable
    case denied
    case underlying(String)
}

public protocol PassiveSleepImporterProtocol: AnyObject, Sendable {
    /// Reads HealthKit sleep analysis samples in `[start, end)` and returns
    /// one `PassiveSleepNight` per detected night. Returns an empty array
    /// when HealthKit is unavailable or no samples exist; throws only for
    /// hard authorization errors.
    func importNights(start: Date, end: Date) async throws -> [PassiveSleepNight]
}

/// HealthKit-backed importer. Safe to call repeatedly; nights are derived
/// from per-sample stages and grouped by a 90-minute gap heuristic so that
/// a single fragmented night does not split into multiple "sessions".
public final class PassiveSleepImporter: PassiveSleepImporterProtocol, @unchecked Sendable {

    public init() {}

    public func importNights(start: Date, end: Date) async throws -> [PassiveSleepNight] {
        #if canImport(HealthKit)
        guard HKHealthStore.isHealthDataAvailable(),
              let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            return []
        }
        let store = HKHealthStore()
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let sortByStart = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)

        let samples: [HKCategorySample] = try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(
                sampleType: sleepType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sortByStart]
            ) { _, raw, error in
                if let error = error as? HKError,
                   error.code == .errorAuthorizationDenied ||
                   error.code == .errorAuthorizationNotDetermined {
                    cont.resume(throwing: PassiveSleepImportError.denied); return
                }
                if let error = error {
                    cont.resume(throwing: PassiveSleepImportError.underlying(error.localizedDescription))
                    return
                }
                cont.resume(returning: (raw as? [HKCategorySample]) ?? [])
            }
            store.execute(q)
        }

        if samples.isEmpty { return [] }
        return Self.groupIntoNights(samples)
        #else
        _ = (start, end)
        return []
        #endif
    }

    #if canImport(HealthKit)
    /// Collapses raw category samples into nightly buckets. We split when
    /// the gap between consecutive samples exceeds 90 minutes — that's
    /// long enough that an evening nap and a night-long sleep don't fuse
    /// into one phantom 14-hour "night", short enough that a brief 03:00
    /// bathroom wake doesn't break a single night into two.
    static func groupIntoNights(_ samples: [HKCategorySample]) -> [PassiveSleepNight] {
        let nightGap: TimeInterval = 90 * 60
        var nights: [[HKCategorySample]] = []
        var bucket: [HKCategorySample] = []
        var lastEnd: Date?

        for s in samples {
            if let prev = lastEnd, s.startDate.timeIntervalSince(prev) > nightGap {
                if !bucket.isEmpty { nights.append(bucket); bucket = [] }
            }
            bucket.append(s)
            lastEnd = max(lastEnd ?? s.endDate, s.endDate)
        }
        if !bucket.isEmpty { nights.append(bucket) }

        return nights.compactMap { Self.summarize($0) }
    }

    private static func summarize(_ samples: [HKCategorySample]) -> PassiveSleepNight? {
        guard let first = samples.first, let last = samples.last else { return nil }
        let start = samples.map(\.startDate).min() ?? first.startDate
        let end   = samples.map(\.endDate).max()   ?? last.endDate

        var inBed = 0, asleep = 0, awake = 0, core = 0, deep = 0, rem = 0

        for s in samples {
            let dur = max(0, Int(s.endDate.timeIntervalSince(s.startDate)))
            guard let v = HKCategoryValueSleepAnalysis(rawValue: s.value) else { continue }
            switch v {
            case .inBed:
                inBed += dur
            case .asleepUnspecified:
                asleep += dur
            case .awake:
                awake += dur
            case .asleepCore:
                core += dur; asleep += dur
            case .asleepDeep:
                deep += dur; asleep += dur
            case .asleepREM:
                rem  += dur; asleep += dur
            @unknown default:
                continue
            }
        }

        // Drop nights with negligible signal — Apple Watch occasionally
        // emits a sub-5-minute "inBed" stub when the user briefly puts
        // the watch on the nightstand. Surfacing those as full nights
        // would clutter History.
        if asleep < 15 * 60 && inBed < 30 * 60 { return nil }

        let bundles = Array(Set(samples.map { $0.sourceRevision.source.bundleIdentifier }))
            .sorted()

        // Stable id derived from the night's UTC start to second precision,
        // so re-importing the same night doesn't create duplicates.
        let idStamp = Int(start.timeIntervalSince1970)
        let id = "passive-\(idStamp)"

        return PassiveSleepNight(
            id: id,
            startedAt: start,
            endedAt: end,
            inBedSec: inBed,
            asleepSec: asleep,
            awakeSec: awake,
            coreSec: core,
            deepSec: deep,
            remSec: rem,
            sourceBundleIDs: bundles
        )
    }
    #endif
}
