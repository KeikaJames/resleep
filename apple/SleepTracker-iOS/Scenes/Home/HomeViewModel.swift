import Foundation
import SleepKit

@MainActor
final class HomeViewModel: ObservableObject {

    @Published var isPreparingPermissions: Bool = false
    @Published var lastError: String?

    private weak var appState: AppState?

    /// Grace period after `stopTracking` — gives the Watch a chance to flush
    /// any pending telemetry batches before we close the engine session.
    private let stopFlushGraceSec: Double = 2.5

    func bind(appState: AppState) {
        self.appState = appState
    }

    // MARK: Tracking

    func toggleSession() async {
        guard let appState else { return }
        if appState.workout.isTracking {
            await stop(appState: appState)
        } else {
            await start(appState: appState)
        }
    }

    // MARK: Alarm controls (called from HomeView)

    /// Called when the user hits "dismiss alarm" on the phone UI — for
    /// debugging convenience. Sends a stopAlarm to the Watch and transitions
    /// the controller to `.dismissed`.
    func dismissAlarmFromPhone() {
        guard let appState else { return }
        _ = appState.router.sendStopAlarm(sessionId: appState.workout.currentSessionID)
        appState.alarm.dismissLocally()
        appState.publishSnapshot()
    }

    // MARK: - Internals

    private func start(appState: AppState) async {
        lastError = nil
        isPreparingPermissions = true
        defer { isPreparingPermissions = false }

        do {
            try await appState.health.requestAuthorization()
        } catch {
            lastError = "HealthKit permission: \(error)"
        }

        let useWatch = appState.connectivity.isReachable && appState.connectivity.isWatchAppInstalled
        let source: TrackingSource = useWatch ? .remoteWatch : .localPhone

        do {
            try await appState.workout.startTracking(source: source)
        } catch {
            lastError = "Start failed: \(error)"
            return
        }

        // Install trigger/dismiss/1Hz-status hooks — same set the simulation
        // path uses, so live and simulated exercise the identical product loop.
        appState.installRunningSessionHooks()

        // Arm the Rust engine if the user enabled the alarm; also echo the
        // arm to the Watch as a hint.
        if appState.alarm.isEnabled {
            _ = appState.alarm.armIfEnabled(engine: appState.engine)
            _ = appState.router.sendArmAlarm(
                sessionId: appState.workout.currentSessionID,
                target: appState.alarm.target,
                windowMinutes: appState.alarm.windowMinutes
            )
        }

        if let sessionId = appState.workout.currentSessionID, useWatch {
            if !appState.router.sendStart(sessionId: sessionId) {
                lastError = "Watch unreachable — enqueued start for guaranteed delivery."
            }
        }
        appState.publishSnapshot()
    }

    private func stop(appState: AppState) async {
        appState.teardownRunningSessionHooks()

        let sessionId = appState.workout.currentSessionID

        if appState.alarm.state == .triggered || appState.alarm.state == .failedWatchUnreachable {
            _ = appState.router.sendStopAlarm(sessionId: sessionId)
        }
        appState.alarm.clear()

        if appState.workout.source == .remoteWatch {
            _ = appState.router.sendStop(sessionId: sessionId)
            try? await Task.sleep(nanoseconds: UInt64(stopFlushGraceSec * 1_000_000_000))
        }

        do {
            let summary = try await appState.workout.stopTracking()
            if let summary {
                let startedAt = appState.workout.sessionStartedAt
                    ?? Date().addingTimeInterval(-TimeInterval(summary.durationSec))
                try? await appState.localStore.recordLocalSummary(summary, startedAt: startedAt)
                appState.latestSummary = summary
            }
            appState.publishSnapshot()
        } catch {
            lastError = "Stop failed: \(error)"
        }
    }
}
