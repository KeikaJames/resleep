import Foundation
#if canImport(HealthKit)
import HealthKit
#endif

/// Continuous heart-rate sample stream. SleepKit consumes these to drive the
/// sleep engine's per-sample pushes.
///
/// Implementations are expected to deliver `onSample` on an arbitrary thread.
/// Callers are responsible for hopping to the correct actor before touching
/// shared state (see `WorkoutSessionManager`).
public protocol HeartRateStreaming: AnyObject {
    /// Invoked for each new heart-rate sample. `bpm` is beats per minute,
    /// `date` is the sample's end-date.
    var onSample: (@Sendable (Double, Date) -> Void)? { get set }

    /// Starts delivery. Throws if the underlying source is unavailable or
    /// unauthorized. Safe to call multiple times; a second call replaces the
    /// previous query.
    func start() async throws

    /// Stops delivery. Safe to call when already stopped.
    func stop()
}

public enum HeartRateStreamError: Error, Sendable, Equatable {
    case unavailable
    case unauthorized
    case underlying(String)
}

// MARK: - HealthKit-backed stream

#if canImport(HealthKit)

/// HealthKit-backed heart rate stream.
///
/// Uses `HKAnchoredObjectQuery` with a non-nil `updateHandler` so that new
/// samples flow in as they are written to the HealthKit store (both from
/// the paired Watch and from the Health app).
///
/// Thread safety: the HK callbacks are dispatched on an internal queue.
/// `start()`/`stop()` are `@MainActor`-isolated to keep the `query`
/// reference consistent; the `onSample` closure must be `@Sendable` because
/// it hops off the main actor.
@MainActor
public final class HealthKitHeartRateStream: @preconcurrency HeartRateStreaming {

    public var onSample: (@Sendable (Double, Date) -> Void)?

    private let store: HKHealthStore
    private var query: HKAnchoredObjectQuery?
    private var anchor: HKQueryAnchor?

    public init(store: HKHealthStore = HKHealthStore()) {
        self.store = store
    }

    public func start() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HeartRateStreamError.unavailable
        }
        guard let hrType = HKObjectType.quantityType(forIdentifier: .heartRate) else {
            throw HeartRateStreamError.unavailable
        }
        let status = store.authorizationStatus(for: hrType)
        guard status == .sharingAuthorized else {
            throw HeartRateStreamError.unauthorized
        }

        stop()

        // Only deliver new samples; anything already in the store is ignored
        // so the engine isn't flooded by historical data at session start.
        let predicate = HKQuery.predicateForSamples(
            withStart: Date(),
            end: nil,
            options: .strictStartDate
        )

        let q = HKAnchoredObjectQuery(
            type: hrType,
            predicate: predicate,
            anchor: anchor,
            limit: HKObjectQueryNoLimit
        ) { [weak self] _, samples, _, newAnchor, error in
            self?.handle(samples: samples, newAnchor: newAnchor, error: error)
        }
        q.updateHandler = { [weak self] _, samples, _, newAnchor, error in
            self?.handle(samples: samples, newAnchor: newAnchor, error: error)
        }
        self.query = q
        store.execute(q)
    }

    public func stop() {
        if let q = query {
            store.stop(q)
        }
        query = nil
    }

    // Called on HealthKit's internal queue.
    private nonisolated func handle(samples: [HKSample]?, newAnchor: HKQueryAnchor?, error: Error?) {
        if let error = error {
            // Surfacing the error via logging; we intentionally do not bubble
            // it to the caller here — the stream stays armed for recovery.
            NSLog("[HealthKitHeartRateStream] delivery error: \(error.localizedDescription)")
            return
        }
        guard let samples = samples as? [HKQuantitySample], !samples.isEmpty else { return }
        let unit = HKUnit.count().unitDivided(by: .minute())
        let handler = Self.snapshotOnSample(self)
        for s in samples {
            let bpm = s.quantity.doubleValue(for: unit)
            handler?(bpm, s.endDate)
        }
        Task { @MainActor [weak self] in
            self?.anchor = newAnchor
        }
    }

    // Reads `onSample` on the MainActor without requiring the nonisolated
    // delivery path to await. This is safe because `onSample` is only
    // re-assigned on the main actor and the closure itself is `@Sendable`.
    private nonisolated static func snapshotOnSample(
        _ stream: HealthKitHeartRateStream?
    ) -> (@Sendable (Double, Date) -> Void)? {
        guard let stream = stream else { return nil }
        return MainActor.assumeIsolated { stream.onSample }
    }
}

#endif // canImport(HealthKit)

// MARK: - Mock stream (for tests & previews)

/// Test/preview-friendly stream. Tests can call `emit(_:)` directly to push
/// synthetic samples through the rest of the pipeline.
@MainActor
public final class MockHeartRateStream: @preconcurrency HeartRateStreaming {
    public var onSample: (@Sendable (Double, Date) -> Void)?
    public private(set) var isRunning = false

    public init() {}

    public func start() async throws { isRunning = true }
    public func stop() { isRunning = false }

    public func emit(_ bpm: Double, at date: Date = Date()) {
        onSample?(bpm, date)
    }
}
