import Foundation
#if canImport(HealthKit)
import HealthKit
#endif

/// Writes a finished session's stage timeline back to Apple Health as
/// `HKCategoryTypeIdentifierSleepAnalysis` samples, one per contiguous span.
///
/// Per Apple Health conventions:
///   wake  → .awake
///   light → .asleepCore
///   deep  → .asleepDeep
///   rem   → .asleepREM
///
/// Failures are non-fatal: the local store remains the source of truth.
public protocol HealthKitSleepWriting: Sendable {
    func writeTimeline(_ timeline: [TimelineEntry], sessionId: String) async throws
}

public enum HealthKitSleepWriterError: Error, Sendable, Equatable {
    case unavailable
    case notAuthorized
    case underlying(String)
}

@MainActor
public final class HealthKitSleepWriter: @preconcurrency HealthKitSleepWriting {

    #if canImport(HealthKit)
    private let store = HKHealthStore()
    #endif

    public init() {}

    public func writeTimeline(_ timeline: [TimelineEntry], sessionId: String) async throws {
        #if canImport(HealthKit)
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthKitSleepWriterError.unavailable
        }
        guard let categoryType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            throw HealthKitSleepWriterError.unavailable
        }
        switch store.authorizationStatus(for: categoryType) {
        case .sharingAuthorized:
            break
        default:
            throw HealthKitSleepWriterError.notAuthorized
        }

        let samples: [HKCategorySample] = timeline.compactMap { entry in
            guard entry.end > entry.start else { return nil }
            let value: Int
            switch entry.stage {
            case .wake:  value = HKCategoryValueSleepAnalysis.awake.rawValue
            case .light: value = HKCategoryValueSleepAnalysis.asleepCore.rawValue
            case .deep:  value = HKCategoryValueSleepAnalysis.asleepDeep.rawValue
            case .rem:   value = HKCategoryValueSleepAnalysis.asleepREM.rawValue
            }
            return HKCategorySample(
                type: categoryType,
                value: value,
                start: entry.start,
                end: entry.end,
                metadata: [HKMetadataKeyExternalUUID: sessionId]
            )
        }
        guard !samples.isEmpty else { return }

        do {
            try await store.save(samples)
        } catch {
            throw HealthKitSleepWriterError.underlying(error.localizedDescription)
        }
        #else
        throw HealthKitSleepWriterError.unavailable
        #endif
    }
}

/// No-op implementation for previews/tests/non-iOS targets.
public final class NoopHealthKitSleepWriter: HealthKitSleepWriting {
    public init() {}
    public func writeTimeline(_ timeline: [TimelineEntry], sessionId: String) async throws {}
}
