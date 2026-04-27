import Foundation
#if canImport(HealthKit)
import HealthKit
#endif

public enum HealthPermissionError: Error, Sendable, Equatable {
    case unavailable
    case denied
    case underlying(String)
}

public enum HealthAuthorizationStatus: Sendable, Equatable {
    case unknown
    case notDetermined
    case sharingDenied
    case sharingAuthorized
}

/// Thin, protocol-based permission surface. Real HK calls are gated behind
/// `#if canImport(HealthKit)` so SleepKit still builds on macOS / previews.
public protocol HealthPermissionServiceProtocol: AnyObject {
    func isAvailable() -> Bool
    func heartRateAuthorization() -> HealthAuthorizationStatus
    func requestAuthorization() async throws
    func authorizationStatusDescription() -> String
    /// Probes the actual read permission state with a sample query and
    /// caches the result. HealthKit's `authorizationStatus(for:)` does
    /// not reflect read grants on its own; call this on launch and on
    /// every foreground transition to keep the cached state honest.
    func probeHeartRateReadAccess() async
}

@MainActor
public final class HealthPermissionService: @preconcurrency HealthPermissionServiceProtocol {

    #if canImport(HealthKit)
    private let store = HKHealthStore()
    #endif

    public init() {}

    public nonisolated func isAvailable() -> Bool {
        #if canImport(HealthKit)
        return HKHealthStore.isHealthDataAvailable()
        #else
        return false
        #endif
    }

    public func heartRateAuthorization() -> HealthAuthorizationStatus {
        #if canImport(HealthKit)
        guard HKHealthStore.isHealthDataAvailable(),
              let hr = HKObjectType.quantityType(forIdentifier: .heartRate) else {
            return .unknown
        }
        // NOTE: HealthKit's `authorizationStatus(for:)` reflects only the
        // WRITE permission. For read-only types it returns `.sharingDenied`
        // even when the user has granted access — Apple's deliberate
        // privacy design ("never tell apps that they were denied reads").
        // We therefore use it only to detect the `.notDetermined` state
        // (i.e. we still need to prompt). For "is read working?" we cache
        // a probe result populated by `probeHeartRateReadAccess()`.
        let raw = store.authorizationStatus(for: hr)
        if raw == .notDetermined && cachedReadAccess == nil {
            return .notDetermined
        }
        switch cachedReadAccess {
        case .some(true):  return .sharingAuthorized
        case .some(false): return .sharingDenied
        case .none:
            // Haven't probed yet. Treat as notDetermined so the UI
            // surfaces the "Grant access" affordance instead of a
            // misleading "Denied".
            return raw == .notDetermined ? .notDetermined : .unknown
        }
        #else
        return .unknown
        #endif
    }

    #if canImport(HealthKit)
    /// Cached result of the last probe query. `nil` = not yet probed,
    /// `true` = HealthKit returned data (or empty success) → read is
    /// effectively granted, `false` = query errored with authorization-
    /// denied. Updated by `probeHeartRateReadAccess()`.
    private var cachedReadAccess: Bool?
    #endif

    /// Issues a one-shot lookback query for heart-rate samples to determine
    /// whether the read permission was actually granted (HealthKit hides
    /// this fact from `authorizationStatus(for:)`). Idempotent and cheap;
    /// safe to call from `appForeground` and after `requestAuthorization`.
    public func probeHeartRateReadAccess() async {
        #if canImport(HealthKit)
        guard HKHealthStore.isHealthDataAvailable(),
              let hr = HKObjectType.quantityType(forIdentifier: .heartRate)
        else {
            cachedReadAccess = nil
            return
        }
        // Window: last 14 days. Most users with a Watch have *some* HR
        // sample in that range; success-with-zero-results also implies
        // read access on iOS 17+ (the query simply succeeds rather than
        // erroring with "authorization denied").
        let end = Date()
        let start = end.addingTimeInterval(-14 * 86_400)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])

        let granted: Bool = await withCheckedContinuation { cont in
            let q = HKSampleQuery(
                sampleType: hr,
                predicate: predicate,
                limit: 1,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error = error as? HKError,
                   error.code == .errorAuthorizationDenied ||
                   error.code == .errorAuthorizationNotDetermined {
                    cont.resume(returning: false); return
                }
                if error != nil {
                    // Other errors (e.g. data unavailable) — don't lock
                    // the user out; assume "we don't know" → false-ish
                    // but treated as "not yet authorized" by the caller.
                    cont.resume(returning: false); return
                }
                // Success (samples nil-or-non-nil): read is granted.
                _ = samples
                cont.resume(returning: true)
            }
            store.execute(q)
        }
        cachedReadAccess = granted
        #endif
    }

    /// Requests the read permissions SleepKit needs. This is the full set the
    /// app may ever request; the heart rate stream can start as soon as `.heartRate`
    /// is authorized even if others aren't.
    public func requestAuthorization() async throws {
        #if canImport(HealthKit)
        guard HKHealthStore.isHealthDataAvailable() else { throw HealthPermissionError.unavailable }

        var readTypes: Set<HKObjectType> = []
        if let hr  = HKObjectType.quantityType(forIdentifier: .heartRate) { readTypes.insert(hr) }
        if let hrv = HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN) { readTypes.insert(hrv) }
        if let sa  = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { readTypes.insert(sa) }

        var writeTypes: Set<HKSampleType> = []
        if let sa  = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { writeTypes.insert(sa) }

        do {
            try await store.requestAuthorization(toShare: writeTypes, read: readTypes)
        } catch {
            throw HealthPermissionError.underlying(error.localizedDescription)
        }
        #else
        throw HealthPermissionError.unavailable
        #endif
    }

    public nonisolated func authorizationStatusDescription() -> String {
        #if canImport(HealthKit)
        return "HealthKit available: \(HKHealthStore.isHealthDataAvailable())"
        #else
        return "HealthKit unavailable on this platform"
        #endif
    }
}
