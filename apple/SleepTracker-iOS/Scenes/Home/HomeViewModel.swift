import Foundation
import SleepKit

@MainActor
final class HomeViewModel: ObservableObject {

    @Published var isPreparingPermissions: Bool = false
    @Published var lastError: String?
    /// When non-nil, HomeView presents the wake-up survey sheet for this session.
    @Published var pendingSurveySessionId: String?
    /// When non-nil, HomeView presents the sleep-notes sheet for this session.
    @Published var pendingNotesSessionId: String?

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
        // After the system prompt closes, probe with a real query so we
        // know whether READ access was granted (HealthKit refuses to
        // tell us this through `authorizationStatus(for:)`).
        await appState.health.probeHeartRateReadAccess()
        // Republish the latest status immediately so the UI reflects
        // the new state without waiting for a foreground bounce.
        appState.refreshHealthAuthorization()

        let useWatch = appState.connectivity.isReachable && appState.connectivity.isWatchAppInstalled
        let source: TrackingSource = useWatch ? .remoteWatch : .localPhone

        do {
            try await appState.workout.startTracking(source: source)
        } catch {
            lastError = "Start failed: \(error)"
            await appState.diagnostics.append(
                DiagnosticEvent(type: .sessionStop, message: "start failed", error: "\(error)")
            )
            return
        }

        // Install trigger/dismiss/1Hz-status hooks — same set the simulation
        // path uses, so live and simulated exercise the identical product loop.
        appState.installRunningSessionHooks()

        let startedAt = appState.workout.sessionStartedAt ?? Date()
        if let sid = appState.workout.currentSessionID {
            await appState.writeActiveMarker(sessionId: sid,
                                              startedAt: startedAt,
                                              source: source,
                                              mode: appState.runtimeMode)
            await appState.diagnostics.append(
                DiagnosticEvent(type: .sessionStart,
                                sessionId: sid,
                                message: "source=\(source.rawValue)")
            )
        }

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
        let sessionId = appState.workout.currentSessionID

        if appState.alarm.state == .triggered || appState.alarm.state == .failedWatchUnreachable {
            _ = appState.router.sendStopAlarm(sessionId: sessionId)
        }

        // Snapshot alarm meta *before* clearing — so the persisted record
        // retains the final state, target, window, triggered/dismissed times.
        let alarmMeta = StoredAlarmMeta(
            enabled: appState.alarm.isEnabled,
            finalStateRaw: appState.alarm.state.rawValue,
            targetTsMs: appState.alarm.isEnabled
                ? Int64(appState.alarm.target.timeIntervalSince1970 * 1000)
                : nil,
            windowMinutes: appState.alarm.windowMinutes,
            triggeredAtTsMs: appState.alarm.triggeredAt.map { Int64($0.timeIntervalSince1970 * 1000) },
            dismissedAtTsMs: appState.alarm.watchAckedAt.map { Int64($0.timeIntervalSince1970 * 1000) }
        )
        appState.alarm.clear()

        if appState.workout.source == .remoteWatch {
            _ = appState.router.sendStop(sessionId: sessionId)
            try? await Task.sleep(nanoseconds: UInt64(stopFlushGraceSec * 1_000_000_000))
        }

        // Drain timeline buffer *before* tearing down hooks (which also
        // cancels the timeline tick task).
        let endedAt = Date()
        let timeline = appState.drainTimelineEntries(endedAt: endedAt)
        let source = appState.workout.source
        let runtimeMode = appState.runtimeMode

        appState.teardownRunningSessionHooks()

        do {
            let summary = try await appState.workout.stopTracking()
            if let summary {
                let startedAt = appState.workout.sessionStartedAt
                    ?? Date().addingTimeInterval(-TimeInterval(summary.durationSec))
                await appState.archiveCompletedSession(
                    summary: summary,
                    startedAt: startedAt,
                    endedAt: endedAt,
                    timeline: timeline,
                    alarm: alarmMeta,
                    source: source,
                    runtimeMode: runtimeMode
                )
                pendingSurveySessionId = summary.sessionId
                await appState.diagnostics.append(
                    DiagnosticEvent(type: .localStoreWrite,
                                    sessionId: summary.sessionId,
                                    message: "session record persisted")
                )
            }
            await appState.diagnostics.append(
                DiagnosticEvent(type: .sessionStop, sessionId: sessionId)
            )
            await appState.clearActiveMarker()
            appState.publishSnapshot()
        } catch {
            lastError = "Stop failed: \(error)"
            await appState.diagnostics.append(
                DiagnosticEvent(type: .sessionStop,
                                sessionId: sessionId,
                                error: "\(error)")
            )
            await appState.clearActiveMarker()
        }
    }
}
