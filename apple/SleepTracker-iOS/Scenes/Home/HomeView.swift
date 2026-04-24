import SwiftUI
import SleepKit

struct HomeView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var model = HomeViewModel()
    @State private var pickedScenario: ScenarioType = .fallingAsleep

    var body: some View {
        NavigationStack {
            Form {
                sessionSection
                watchSection
                alarmSection
                modelSection
                debugSection
                if let summary = appState.latestSummary {
                    summarySection(summary)
                }
                if let err = model.lastError {
                    Section { Text(err).font(.footnote).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Sleep Tracker")
            .onAppear { model.bind(appState: appState) }
        }
    }

    // MARK: Sections

    private var sessionSection: some View {
        Section("Session") {
            HStack {
                Text("Status")
                Spacer()
                Text(appState.workout.isTracking ? "Tracking" : "Idle")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Source")
                Spacer()
                Text(sourceLabel(appState.workout.source))
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Stage / Confidence")
                Spacer()
                Text("\(stageLabel(appState.workout.currentStage)) · \(String(format: "%.2f", appState.workout.currentConfidence))")
                    .foregroundStyle(.secondary)
            }
            Button(appState.workout.isTracking ? "Stop Tracking" : "Start Tracking") {
                Task { await model.toggleSession() }
            }
            .disabled(model.isPreparingPermissions)
        }
    }

    private var watchSection: some View {
        Section("Watch link") {
            HStack {
                Text("Reachable")
                Spacer()
                Text(appState.router.watchReachable ? "Yes" : "No")
                    .foregroundStyle(appState.router.watchReachable ? .green : .secondary)
            }
            HStack {
                Text("Last batch")
                Spacer()
                Text(relativeDate(appState.router.lastBatchAt))
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Last HR / Accel")
                Spacer()
                Text("\(appState.router.lastBatchHRCount) / \(appState.router.lastBatchAccelCount)")
                    .foregroundStyle(.secondary)
            }
            if let ack = appState.router.lastAlarmAckAt {
                HStack {
                    Text("Watch alarm ack")
                    Spacer()
                    Text(relativeDate(ack)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var alarmSection: some View {
        Section("Smart alarm") {
            Toggle("Enabled", isOn: $appState.alarm.isEnabled)
            DatePicker(
                "Wake by",
                selection: $appState.alarm.target,
                displayedComponents: [.hourAndMinute]
            )
            Stepper(
                "Window: \(appState.alarm.windowMinutes) min",
                value: $appState.alarm.windowMinutes,
                in: 5...45,
                step: 5
            )
            HStack {
                Text("State")
                Spacer()
                Text(alarmLabel(appState.alarm.state))
                    .foregroundStyle(alarmColor(appState.alarm.state))
            }
            if appState.alarm.state == .triggered
                || appState.alarm.state == .failedWatchUnreachable {
                Button("Dismiss from phone", role: .destructive) {
                    model.dismissAlarmFromPhone()
                }
            }
        }
    }

    private var modelSection: some View {
        let pipeline = appState.inferencePipeline
        let desc = pipeline.descriptor
        let m = pipeline.metrics
        return Section("Model (debug)") {
            HStack {
                Text("Backend")
                Spacer()
                Text(desc.isRealModel ? "Core ML" : "Heuristic fallback")
                    .foregroundStyle(desc.isRealModel ? .green : .orange)
            }
            HStack {
                Text("Name")
                Spacer()
                Text(desc.name).foregroundStyle(.secondary)
            }
            if let v = desc.version {
                HStack {
                    Text("Version")
                    Spacer()
                    Text(v).foregroundStyle(.secondary)
                }
            }
            HStack {
                Text("Load time")
                Spacer()
                Text(String(format: "%.1f ms", m.modelLoadMs))
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Inferences")
                Spacer()
                Text("\(m.inferenceCount)").foregroundStyle(.secondary)
            }
            HStack {
                Text("Last / avg latency")
                Spacer()
                Text(String(format: "%.2f / %.2f ms",
                            m.lastPredictMs, m.rollingAvgPredictMs))
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("Feature build")
                Spacer()
                Text(String(format: "%.2f ms", m.lastFeatureBuildMs))
                    .foregroundStyle(.secondary)
            }
            if let reason = appState.inferenceFallbackReason {
                Text(reason).font(.footnote).foregroundStyle(.orange)
            }
            if let err = m.lastErrorMessage {
                Text(err).font(.footnote).foregroundStyle(.red)
            }
        }
    }

    private var debugSection: some View {
        Section("Debug / Simulation") {
            HStack {
                Text("Runtime")
                Spacer()
                Text(appState.runtimeMode == .simulated ? "Simulated" : "Live")
                    .foregroundStyle(appState.runtimeMode == .simulated ? .orange : .green)
            }
            Picker("Scenario", selection: $pickedScenario) {
                ForEach(ScenarioType.allCases) { s in
                    Text(s.displayName).tag(s)
                }
            }
            if appState.scenarioRunner.isRunning {
                Button("Stop scenario", role: .destructive) {
                    Task { await appState.stopSimulation() }
                }
                HStack {
                    Text("Step")
                    Spacer()
                    Text("\(appState.scenarioRunner.stepIndex)")
                        .foregroundStyle(.secondary)
                }
            } else {
                Button("Run scenario") {
                    Task { await appState.startSimulation(pickedScenario) }
                }
            }
            if let mark = appState.lastScenarioMark {
                HStack {
                    Text("Last mark")
                    Spacer()
                    Text(mark).foregroundStyle(.secondary)
                }
            }
            Button("Force watch disconnect") {
                appState.scenarioRunner.onReachability?(false)
            }
            Button("Force watch reconnect") {
                appState.scenarioRunner.onReachability?(true)
            }
            Button("Arm smart alarm in 30 s") {
                let t = Date().addingTimeInterval(30)
                appState.scenarioRunner.onArmAlarm?(t, 1)
            }
        }
    }

    private func summarySection(_ summary: SessionSummary) -> some View {
        Section("Last summary") {
            Text("Duration: \(summary.durationSec)s")
            Text("Score: \(summary.sleepScore)")
        }
    }

    // MARK: Helpers

    private func sourceLabel(_ s: TrackingSource) -> String {
        switch s {
        case .idle: return "—"
        case .localPhone: return "iPhone local"
        case .remoteWatch: return "Apple Watch"
        }
    }

    private func stageLabel(_ s: SleepStage) -> String {
        switch s {
        case .wake: return "Wake"
        case .light: return "Light"
        case .deep: return "Deep"
        case .rem: return "REM"
        }
    }

    private func alarmLabel(_ s: AlarmState) -> String {
        switch s {
        case .idle: return "Idle"
        case .armed: return "Armed"
        case .triggered: return "Triggered"
        case .dismissed: return "Dismissed"
        case .failedWatchUnreachable: return "Failed (watch unreachable)"
        }
    }

    private func alarmColor(_ s: AlarmState) -> Color {
        switch s {
        case .idle, .dismissed: return .secondary
        case .armed: return .blue
        case .triggered: return .red
        case .failedWatchUnreachable: return .orange
        }
    }

    private func relativeDate(_ d: Date?) -> String {
        guard let d else { return "—" }
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .abbreviated
        return fmt.localizedString(for: d, relativeTo: Date())
    }
}
