import Foundation
#if os(iOS)
import CoreMotion
#endif

/// Detects a "shake" gesture using the device accelerometer and fires a callback.
///
/// Used on the alarm-trigger screen so the user can snooze without finding the
/// snooze button in the dark. We deliberately use raw accelerometer rather than
/// the UIKit motion event so this works regardless of which screen is up.
@MainActor
public final class ShakeToSnoozeDetector {
    public typealias Handler = @MainActor () -> Void

    private let threshold: Double
    private let sustainSeconds: Double
    private var firstHitAt: Date?
    private var handler: Handler?

    #if os(iOS)
    private let manager = CMMotionManager()
    #endif

    /// - Parameters:
    ///   - threshold: |a| in g units required to count as a hit. 1.7 g is firm.
    ///   - sustainSeconds: minimum time the threshold must be exceeded to fire.
    public init(threshold: Double = 1.7, sustainSeconds: Double = 0.25) {
        self.threshold = threshold
        self.sustainSeconds = sustainSeconds
    }

    public func start(onShake: @escaping Handler) {
        self.handler = onShake
        #if os(iOS)
        guard manager.isAccelerometerAvailable, !manager.isAccelerometerActive else { return }
        manager.accelerometerUpdateInterval = 1.0 / 30.0
        manager.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
            guard let self, let d = data else { return }
            let mag = sqrt(d.acceleration.x * d.acceleration.x
                         + d.acceleration.y * d.acceleration.y
                         + d.acceleration.z * d.acceleration.z)
            if mag >= self.threshold {
                if let first = self.firstHitAt {
                    if Date().timeIntervalSince(first) >= self.sustainSeconds {
                        self.fire()
                    }
                } else {
                    self.firstHitAt = Date()
                }
            } else {
                self.firstHitAt = nil
            }
        }
        #endif
    }

    public func stop() {
        #if os(iOS)
        if manager.isAccelerometerActive {
            manager.stopAccelerometerUpdates()
        }
        #endif
        firstHitAt = nil
        handler = nil
    }

    private func fire() {
        let h = handler
        stop()
        h?()
    }
}
