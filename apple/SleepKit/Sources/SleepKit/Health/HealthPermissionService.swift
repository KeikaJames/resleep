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
        switch store.authorizationStatus(for: hr) {
        case .notDetermined:      return .notDetermined
        case .sharingDenied:      return .sharingDenied
        case .sharingAuthorized:  return .sharingAuthorized
        @unknown default:         return .unknown
        }
        #else
        return .unknown
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
