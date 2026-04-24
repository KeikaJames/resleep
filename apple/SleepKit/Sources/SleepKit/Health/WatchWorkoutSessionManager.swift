import Foundation
#if canImport(HealthKit)
import HealthKit
#endif

// MARK: - Protocol

public enum WatchWorkoutError: Error, Sendable, Equatable {
    case unavailable
    case unauthorized
    case alreadyRunning
    case notRunning
    case underlying(String)
}

/// Manages an `HKWorkoutSession` on the watch and exposes a per-sample
/// heart-rate callback. Abstracted as a protocol so the watch `WatchAppState`
/// can be unit-tested with a mock driver.
public protocol WatchWorkoutSessionManagerProtocol: AnyObject {
    var isRunning: Bool { get }
    var onHeartRate: (@Sendable (Double, Date) -> Void)? { get set }
    func start(sessionId: String) async throws
    func stop() async throws
}

// MARK: - Real implementation (watchOS only)

#if os(watchOS) && canImport(HealthKit)

/// Drives a `HKWorkoutSession` + `HKLiveWorkoutBuilder` on watchOS. The
/// workout is started as `.mindAndBody` / `.indoor` so background heart-rate
/// sampling stays active while the screen is off.
public final class HKWatchWorkoutSessionManager: NSObject,
                                                 WatchWorkoutSessionManagerProtocol,
                                                 @unchecked Sendable {

    public var onHeartRate: (@Sendable (Double, Date) -> Void)?
    public private(set) var isRunning: Bool = false

    private let store = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?

    public override init() { super.init() }

    public func start(sessionId: String) async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw WatchWorkoutError.unavailable
        }
        if isRunning { throw WatchWorkoutError.alreadyRunning }

        let config = HKWorkoutConfiguration()
        config.activityType = .mindAndBody
        config.locationType = .indoor

        let workoutSession: HKWorkoutSession
        do {
            workoutSession = try HKWorkoutSession(healthStore: store, configuration: config)
        } catch {
            throw WatchWorkoutError.underlying(error.localizedDescription)
        }

        let liveBuilder = workoutSession.associatedWorkoutBuilder()
        liveBuilder.dataSource = HKLiveWorkoutDataSource(
            healthStore: store,
            workoutConfiguration: config
        )
        liveBuilder.delegate = self
        workoutSession.delegate = self

        self.session = workoutSession
        self.builder = liveBuilder

        let startDate = Date()
        workoutSession.startActivity(with: startDate)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            liveBuilder.beginCollection(withStart: startDate) { success, error in
                if success {
                    cont.resume()
                } else {
                    cont.resume(throwing: WatchWorkoutError.underlying(
                        error?.localizedDescription ?? "beginCollection failed"))
                }
            }
        }

        isRunning = true
    }

    public func stop() async throws {
        guard isRunning, let session = session, let builder = builder else {
            throw WatchWorkoutError.notRunning
        }
        session.end()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            builder.endCollection(withEnd: Date()) { success, error in
                if success {
                    cont.resume()
                } else {
                    cont.resume(throwing: WatchWorkoutError.underlying(
                        error?.localizedDescription ?? "endCollection failed"))
                }
            }
        }
        // We don't care about the saved workout; discard.
        builder.finishWorkout { _, _ in }
        self.session = nil
        self.builder = nil
        isRunning = false
    }
}

extension HKWatchWorkoutSessionManager: HKWorkoutSessionDelegate {
    public func workoutSession(_ workoutSession: HKWorkoutSession,
                               didChangeTo toState: HKWorkoutSessionState,
                               from fromState: HKWorkoutSessionState,
                               date: Date) {
        // No-op; lifecycle is driven explicitly via start/stop.
    }

    public func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        NSLog("[HKWatchWorkoutSessionManager] session failed: \(error.localizedDescription)")
    }
}

extension HKWatchWorkoutSessionManager: HKLiveWorkoutBuilderDelegate {
    public func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    public func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder,
                               didCollectDataOf collectedTypes: Set<HKSampleType>) {
        guard let hrType = HKObjectType.quantityType(forIdentifier: .heartRate),
              collectedTypes.contains(hrType),
              let stats = workoutBuilder.statistics(for: hrType),
              let quantity = stats.mostRecentQuantity()
        else { return }
        let bpm = quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
        let endDate = stats.mostRecentQuantityDateInterval()?.end ?? Date()
        onHeartRate?(bpm, endDate)
    }
}

#endif // os(watchOS) && canImport(HealthKit)

// MARK: - Mock

/// Test / preview driver. Call `emit(bpm:at:)` to simulate watch HR samples.
public final class MockWatchWorkoutSessionManager: WatchWorkoutSessionManagerProtocol,
                                                   @unchecked Sendable {
    public var onHeartRate: (@Sendable (Double, Date) -> Void)?
    public private(set) var isRunning: Bool = false
    public private(set) var lastStartedSessionId: String?

    public init() {}

    public func start(sessionId: String) async throws {
        if isRunning { throw WatchWorkoutError.alreadyRunning }
        isRunning = true
        lastStartedSessionId = sessionId
    }

    public func stop() async throws {
        if !isRunning { throw WatchWorkoutError.notRunning }
        isRunning = false
    }

    public func emit(bpm: Double, at date: Date = Date()) {
        onHeartRate?(bpm, date)
    }
}
