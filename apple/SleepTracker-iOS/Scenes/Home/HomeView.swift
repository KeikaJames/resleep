import SwiftUI
import SleepKit

/// iPhone home screen. Quiet, Apple-style, dark-first. Sections, in order:
///   A. Tonight Status        — mode/source/stage/confidence + primary action
///   B. Smart Alarm           — enable, wake-by, window, current state
///   C. Last Session Summary  — score / duration / view details
///   D. Device & Sync         — watch reachable, model backend, last sync
///   E. Developer Debug       — collapsed by default; scenarios + diagnostics
struct HomeView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var model = HomeViewModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if appState.interruptedSessionStart != nil {
                        InterruptedSessionCard()
                    }
                    TonightStatusCard()
                    SmartAlarmCard()
                    LastSummaryCard()
                    DeviceSyncCard()
                    DeveloperDebugCard()
                    if let err = model.lastError {
                        Text(err)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Sleep")
            .navigationBarTitleDisplayMode(.large)
            .onAppear { model.bind(appState: appState) }
            .environmentObject(model)
        }
    }
}

// MARK: - Tonight status

private struct TonightStatusCard: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var model: HomeViewModel

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    StatusDot(color: statusColor)
                    Text(statusTitle)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(sourceLabel)
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }

                HStack(alignment: .firstTextBaseline) {
                    Text(stageLabel)
                        .font(.system(size: 40, weight: .semibold, design: .rounded))
                    Spacer()
                    if appState.workout.isTracking {
                        Text(String(format: "conf %.2f", appState.workout.currentConfidence))
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }

                Button(action: {
                    Task { await model.toggleSession() }
                }) {
                    Text(appState.workout.isTracking ? "Stop Tracking" : "Start Tracking")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(appState.workout.isTracking ? .red : .accentColor)
                .disabled(model.isPreparingPermissions)
            }
        }
    }

    private var statusColor: Color {
        if appState.runtimeMode == .simulated { return .orange }
        if appState.workout.isTracking { return .green }
        if model.isPreparingPermissions { return .yellow }
        return .secondary
    }

    private var statusTitle: String {
        if model.isPreparingPermissions { return "Preparing" }
        if appState.runtimeMode == .simulated { return "Simulated" }
        if appState.workout.isTracking { return "Tracking" }
        if appState.latestSummary != nil { return "Ended" }
        return "Idle"
    }

    private var sourceLabel: String {
        if appState.runtimeMode == .simulated { return "Simulation" }
        switch appState.workout.source {
        case .idle: return "—"
        case .localPhone: return "iPhone fallback"
        case .remoteWatch: return "Apple Watch"
        }
    }

    private var stageLabel: String {
        guard appState.workout.isTracking else { return "—" }
        switch appState.workout.currentStage {
        case .wake:  return "Awake"
        case .light: return "Light"
        case .deep:  return "Deep"
        case .rem:   return "REM"
        }
    }
}

// MARK: - Smart alarm

private struct SmartAlarmCard: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var model: HomeViewModel

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader(title: "Smart Alarm", systemImage: "alarm")

                Toggle("Enabled", isOn: $appState.alarm.isEnabled)
                    .tint(.accentColor)

                DatePicker(
                    "Wake by",
                    selection: $appState.alarm.target,
                    displayedComponents: [.hourAndMinute]
                )
                .disabled(!appState.alarm.isEnabled)

                Stepper(
                    "Window: \(appState.alarm.windowMinutes) min",
                    value: $appState.alarm.windowMinutes,
                    in: 5...45,
                    step: 5
                )
                .disabled(!appState.alarm.isEnabled)

                Divider().opacity(0.5)

                HStack {
                    Text("State").foregroundStyle(.secondary).font(.subheadline)
                    Spacer()
                    Text(alarmLabel(appState.alarm.state))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(alarmColor(appState.alarm.state))
                }

                if appState.alarm.state == .triggered
                    || appState.alarm.state == .failedWatchUnreachable {
                    Button(role: .destructive) {
                        model.dismissAlarmFromPhone()
                    } label: {
                        Text("Dismiss Alarm")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
            }
        }
    }

    private func alarmLabel(_ s: AlarmState) -> String {
        switch s {
        case .idle: return "Idle"
        case .armed: return "Armed"
        case .triggered: return "Triggered"
        case .dismissed: return "Dismissed"
        case .failedWatchUnreachable: return "Watch unreachable"
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
}

// MARK: - Last summary

private struct LastSummaryCard: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader(title: "Last Session", systemImage: "moon.zzz")

                if let summary = appState.latestSummary {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(formatDuration(summary.durationSec))
                                .font(.system(size: 30, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                            Text("Total sleep")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(summary.sleepScore)")
                                .font(.system(size: 30, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                            Text("Score")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    HStack(spacing: 14) {
                        StatChip(label: "Deep",  value: formatDuration(summary.timeInDeepSec))
                        StatChip(label: "REM",   value: formatDuration(summary.timeInRemSec))
                        StatChip(label: "Light", value: formatDuration(summary.timeInLightSec))
                    }

                    NavigationLink {
                        SessionDetailView(summary: summary,
                                          startedAt: appState.workout.sessionStartedAt,
                                          alarmState: appState.alarm.state,
                                          alarmTarget: appState.alarm.target,
                                          alarmWindowMinutes: appState.alarm.windowMinutes)
                    } label: {
                        HStack {
                            Text("View Details")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .font(.subheadline)
                    }
                    .padding(.top, 2)
                } else {
                    Text("Start a sleep session tonight. Your summary will appear here in the morning.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - Device & sync

private struct DeviceSyncCard: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Card {
            VStack(spacing: 10) {
                CardHeader(title: "Device & Sync", systemImage: "applewatch.radiowaves.left.and.right")

                Row(label: "Apple Watch",
                    value: appState.router.watchReachable ? "Reachable" : "Not reachable",
                    valueColor: appState.router.watchReachable ? .green : .secondary)
                Row(label: "Last sync", value: relativeDate(appState.router.lastBatchAt))
                Row(label: "Source", value: sourceLabel)
                Row(label: "Model",
                    value: appState.inferencePipeline.descriptor.isRealModel ? "Core ML" : "Fallback",
                    valueColor: appState.inferencePipeline.descriptor.isRealModel ? .green : .orange)
            }
        }
    }

    private var sourceLabel: String {
        if appState.runtimeMode == .simulated { return "Simulation" }
        switch appState.workout.source {
        case .idle: return "—"
        case .localPhone: return "iPhone fallback"
        case .remoteWatch: return "Apple Watch"
        }
    }
}

// MARK: - Developer debug (collapsed)

private struct DeveloperDebugCard: View {
    @EnvironmentObject private var appState: AppState
    @State private var expanded: Bool = false
    @State private var pickedScenario: ScenarioType = .fallingAsleep

    var body: some View {
        Card {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 12) {
                    Divider().opacity(0.5)

                    Row(label: "Runtime",
                        value: appState.runtimeMode == .simulated ? "Simulated" : "Live",
                        valueColor: appState.runtimeMode == .simulated ? .orange : .green)

                    Picker("Scenario", selection: $pickedScenario) {
                        ForEach(ScenarioType.allCases) { s in
                            Text(s.displayName).tag(s)
                        }
                    }
                    .pickerStyle(.menu)

                    HStack {
                        if appState.scenarioRunner.isRunning {
                            Button(role: .destructive) {
                                Task { await appState.stopSimulation() }
                            } label: {
                                Text("Stop scenario").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        } else {
                            Button {
                                Task { await appState.startSimulation(pickedScenario) }
                            } label: {
                                Text("Run scenario").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    HStack {
                        Button("Force disconnect") {
                            appState.scenarioRunner.onReachability?(false)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        Button("Force reconnect") {
                            appState.scenarioRunner.onReachability?(true)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        Button("Arm in 30s") {
                            let t = Date().addingTimeInterval(30)
                            appState.scenarioRunner.onArmAlarm?(t, 1)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    if let mark = appState.lastScenarioMark {
                        Row(label: "Last mark", value: mark)
                    }

                    Divider().opacity(0.5)

                    let m = appState.inferencePipeline.metrics
                    Row(label: "Inferences", value: "\(m.inferenceCount)")
                    Row(label: "Last latency", value: String(format: "%.2f ms", m.lastPredictMs))
                    Row(label: "Avg latency",  value: String(format: "%.2f ms", m.rollingAvgPredictMs))
                    Row(label: "Model load",   value: String(format: "%.1f ms", m.modelLoadMs))
                    if let reason = appState.inferenceFallbackReason {
                        Text(reason).font(.caption).foregroundStyle(.orange)
                    }
                }
                .padding(.top, 8)
            } label: {
                CardHeader(title: "Developer", systemImage: "wrench.and.screwdriver")
            }
        }
    }
}

// MARK: - Generic UI atoms

private struct Card<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct CardHeader: View {
    let title: String
    let systemImage: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.footnote)
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
        }
    }
}

private struct Row: View {
    let label: String
    let value: String
    var valueColor: Color = .secondary
    var body: some View {
        HStack {
            Text(label).font(.subheadline).foregroundStyle(.primary)
            Spacer()
            Text(value).font(.subheadline).foregroundStyle(valueColor)
        }
    }
}

private struct StatChip: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.subheadline.weight(.medium)).monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct StatusDot: View {
    let color: Color
    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
    }
}

// MARK: - Helpers

func formatDuration(_ seconds: Int) -> String {
    let h = seconds / 3600
    let m = (seconds % 3600) / 60
    if h > 0 { return "\(h)h \(m)m" }
    return "\(m)m"
}

private func relativeDate(_ d: Date?) -> String {
    guard let d else { return "—" }
    let fmt = RelativeDateTimeFormatter()
    fmt.unitsStyle = .abbreviated
    return fmt.localizedString(for: d, relativeTo: Date())
}

// MARK: - Interrupted session

private struct InterruptedSessionCard: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Previous session interrupted")
                        .font(.subheadline.weight(.semibold))
                }
                if let m = appState.interruptedSessionStart {
                    Text("Started \(formattedDate(m.startedAt)). The app was terminated before stop.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 12) {
                    Button {
                        Task { await appState.finishInterruptedAndSave() }
                    } label: {
                        Text("Finish & Save")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)

                    Button(role: .destructive) {
                        Task { await appState.discardInterruptedSession() }
                    } label: {
                        Text("Discard")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private func formattedDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: d)
    }
}
