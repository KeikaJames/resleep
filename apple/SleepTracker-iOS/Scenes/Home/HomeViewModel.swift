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

    /// Cadence for status-snapshot re-publication while tracking. Matches the
    /// spec (1 Hz). Major state changes also publish immediately out-of-band.
    private let statusTickSec: Double = 1.0

    private var statusTickTask: Task<Void, Never>?

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
        publishSnapshot(appState: appState)
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

        // Wire the trigger sink. The closure weakly captures AppState so we
        // don't keep it alive past the session.
        appState.alarm.setTriggerHandler { [weak appState] in
            guard let appState else { return false }
            let sid = appState.workout.currentSessionID
            return appState.router.sendTriggerAlarm(sessionId: sid)
        }

        // Arm the Rust engine if the user enabled the alarm; also echo the
        // arm to the Watch as a hint (Watch doesn't decide, but it can show
        // "alarm armed").
        if appState.alarm.isEnabled {
            _ = appState.alarm.armIfEnabled(engine: appState.engine)
            _ = appState.router.sendArmAlarm(
                sessionId: appState.workout.currentSessionID,
                target: appState.alarm.target,
                windowMinutes: appState.alarm.windowMinutes
            )
        }

        // Route watch dismiss → controller.
        appState.router.onAlarmDismissed = { [weak appState] in
            guard let appState else { return }
            appState.alarm.noteDismissedByWatch()
        }

        if let sessionId = appState.workout.currentSessionID, useWatch {
            if !appState.router.sendStart(sessionId: sessionId) {
                lastError = "Watch unreachable — enqueued start for guaranteed delivery."
            }
        }
        publishSnapshot(appState: appState)
        startStatusTickLoop(appState: appState)
    }

    private func stop(appState: AppState) async {
        statusTickTask?.cancel()
        statusTickTask = nil

        let sessionId = appState.workout.currentSessionID

        // Clear alarm on both sides first — otherwise the Watch could keep
        // buzzing after endSession.
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
            publishSnapshot(appState: appState)
        } catch {
            lastError = "Stop failed: \(error)"
        }
    }

    // MARK: Status tick loop

    private func startStatusTickLoop(appState: AppState) {
        statusTickTask?.cancel()
        let period = statusTickSec
        statusTickTask = Task { [weak self, weak appState] in
            while !Task.isCancelled {
                guard let self, let appState else { return }
                await MainActor.run {
                    self.publishSnapshot(appState: appState)
                }
                try? await Task.sleep(nanoseconds: UInt64(period * 1_000_000_000))
            }
        }
    }

    private func publishSnapshot(appState: AppState) {
        appState.router.pushStatusSnapshot(
            sessionId: appState.workout.currentSessionID,
            isTracking: appState.workout.isTracking,
            source: appState.workout.source,
            stage: appState.workout.isTracking ? appState.workout.currentStage : nil,
            confidence: appState.workout.isTracking ? appState.workout.currentConfidence : nil,
            alarmState: appState.alarm.state,
            alarmTarget: appState.alarm.isEnabled ? appState.alarm.target : nil,
            alarmWindowMinutes: appState.alarm.isEnabled ? appState.alarm.windowMinutes : nil,
            alarmTriggeredAt: appState.alarm.triggeredAt
        )
    }
}
