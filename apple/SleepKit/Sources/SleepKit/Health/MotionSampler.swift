import Foundation
#if canImport(CoreMotion)
import CoreMotion
#endif

// MARK: - Models

public struct MotionSample: Sendable, Equatable {
    public let tsMs: UInt64
    public let x: Double
    public let y: Double
    public let z: Double
    public init(tsMs: UInt64, x: Double, y: Double, z: Double) {
        self.tsMs = tsMs; self.x = x; self.y = y; self.z = z
    }
}

// MARK: - Window aggregator

/// Rolling 1-second window aggregator. Call `append(_:)` for every raw sample
/// and `drainWindow(endTsMs:)` at the window boundary to emit a summarized
/// `AccelWindow`. Empty windows return `nil`.
public struct AccelAggregator: Sendable {

    private var bucket: [MotionSample] = []

    public init() {}

    public mutating func append(_ sample: MotionSample) {
        bucket.append(sample)
    }

    public var isEmpty: Bool { bucket.isEmpty }
    public var count: Int { bucket.count }

    public mutating func drainWindow(endTsMs: UInt64) -> AccelWindow? {
        guard !bucket.isEmpty else { return nil }
        let count = Double(bucket.count)
        var sumX = 0.0, sumY = 0.0, sumZ = 0.0
        var sumMag = 0.0, sumEnergy = 0.0
        for s in bucket {
            sumX += s.x; sumY += s.y; sumZ += s.z
            let mag2 = s.x * s.x + s.y * s.y + s.z * s.z
            sumMag    += mag2.squareRoot()
            sumEnergy += mag2
        }
        let window = AccelWindow(
            tsMs: endTsMs,
            meanX: sumX / count,
            meanY: sumY / count,
            meanZ: sumZ / count,
            magnitudeMean: sumMag / count,
            energy: sumEnergy / count,
            sampleCount: bucket.count
        )
        bucket.removeAll(keepingCapacity: true)
        return window
    }
}

// MARK: - Sampler protocol

public enum MotionSamplerError: Error, Sendable, Equatable {
    case unavailable
    case alreadyRunning
    case underlying(String)
}

/// Continuous accelerometer source that emits pre-aggregated 1-second windows.
public protocol MotionSampling: AnyObject {
    var onWindow: (@Sendable (AccelWindow) -> Void)? { get set }
    var isRunning: Bool { get }
    func start() throws
    func stop()
}

// MARK: - CoreMotion implementation

#if canImport(CoreMotion) && (os(iOS) || os(watchOS))

/// CoreMotion-backed sampler. Samples at 10 Hz (watchOS power-budget friendly)
/// and emits an `AccelWindow` every second. Raw samples never leave this
/// object — only the aggregated window is exposed.
public final class CoreMotionSampler: MotionSampling, @unchecked Sendable {

    public var onWindow: (@Sendable (AccelWindow) -> Void)?
    public private(set) var isRunning: Bool = false

    private let motion: CMMotionManager
    private let queue: OperationQueue
    private let lock = NSLock()

    private var aggregator = AccelAggregator()
    private var lastFlushMs: UInt64 = 0
    private let windowMs: UInt64 = 1000

    public init() {
        self.motion = CMMotionManager()
        self.motion.accelerometerUpdateInterval = 1.0 / 10.0 // 10 Hz
        self.queue = OperationQueue()
        self.queue.name = "sleepkit.motion.sampler"
        self.queue.maxConcurrentOperationCount = 1
    }

    public func start() throws {
        guard motion.isAccelerometerAvailable else {
            throw MotionSamplerError.unavailable
        }
        if isRunning { return }
        lastFlushMs = WallClock.nowMs()
        motion.startAccelerometerUpdates(to: queue) { [weak self] data, error in
            guard let self, let data = data, error == nil else { return }
            self.ingest(x: data.acceleration.x,
                        y: data.acceleration.y,
                        z: data.acceleration.z)
        }
        isRunning = true
    }

    public func stop() {
        guard isRunning else { return }
        motion.stopAccelerometerUpdates()
        isRunning = false
        // Flush partial window before shutting down.
        flushIfDue(force: true)
    }

    private func ingest(x: Double, y: Double, z: Double) {
        let nowMs = WallClock.nowMs()
        lock.lock()
        aggregator.append(MotionSample(tsMs: nowMs, x: x, y: y, z: z))
        lock.unlock()
        flushIfDue(force: false)
    }

    private func flushIfDue(force: Bool) {
        let nowMs = WallClock.nowMs()
        lock.lock()
        let shouldFlush = force || nowMs - lastFlushMs >= windowMs
        guard shouldFlush else { lock.unlock(); return }
        let window = aggregator.drainWindow(endTsMs: nowMs)
        lastFlushMs = nowMs
        lock.unlock()
        if let window, let handler = onWindow {
            handler(window)
        }
    }
}

#endif // canImport(CoreMotion) && (os(iOS) || os(watchOS))

// MARK: - Mock sampler

public final class MockMotionSampler: MotionSampling, @unchecked Sendable {
    public var onWindow: (@Sendable (AccelWindow) -> Void)?
    public private(set) var isRunning: Bool = false
    public init() {}
    public func start() throws { isRunning = true }
    public func stop() { isRunning = false }

    public func emit(_ window: AccelWindow) { onWindow?(window) }
}
