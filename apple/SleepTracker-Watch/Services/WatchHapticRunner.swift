import Foundation
#if canImport(WatchKit)
import WatchKit
#endif

/// Drives a repeating haptic while a smart-alarm is active on the Watch.
///
/// Contract:
/// - `start()` begins a 2s-cadence haptic, auto-stopping after `maxDurationSec`.
/// - `stop()` halts immediately.
/// - Re-entrant `start()` is a no-op while already active.
///
/// Intentionally `@MainActor` since `WKInterfaceDevice.current().play` is
/// main-thread-affine on watchOS and the UI state we publish must stay on
/// MainActor anyway.
@MainActor
final class WatchHapticRunner: ObservableObject {

    @Published private(set) var isActive: Bool = false

    /// Cadence between haptic pulses.
    var cadenceSec: TimeInterval = 2.0
    /// Upper bound on how long we'll buzz without a dismiss.
    var maxDurationSec: TimeInterval = 60.0

    private var task: Task<Void, Never>?

    func start() {
        guard !isActive else { return }
        isActive = true
        let cadence = cadenceSec
        let maxDur = maxDurationSec
        task = Task { [weak self] in
            let start = Date()
            while !Task.isCancelled {
                await MainActor.run { Self.playHaptic() }
                if Date().timeIntervalSince(start) >= maxDur { break }
                try? await Task.sleep(nanoseconds: UInt64(cadence * 1_000_000_000))
            }
            await MainActor.run { self?.isActive = false }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isActive = false
    }

    private static func playHaptic() {
        #if canImport(WatchKit) && os(watchOS)
        WKInterfaceDevice.current().play(.notification)
        #endif
    }
}
