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
                VStack(spacing: 28) {
                    if appState.interruptedSessionStart != nil {
                        InterruptedSessionCard()
                    }
                    TonightStatusCard()
                    SmartAlarmCard()
                    LastSummaryCard()
                    InsightsCard()
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
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle(Text("home.title"))
            .navigationBarTitleDisplayMode(.large)
            .onAppear { model.bind(appState: appState) }
            .sheet(item: Binding<IdentifiedString?>(
                get: { model.pendingSurveySessionId.map(IdentifiedString.init) },
                set: { newValue in model.pendingSurveySessionId = newValue?.id }
            )) { wrapped in
                WakeUpSurveySheet(sessionId: wrapped.id) {
                    model.pendingSurveySessionId = nil
                }
                .environmentObject(appState)
                .presentationDetents([.large])
            }
            .sheet(item: Binding<IdentifiedString?>(
                get: { model.pendingNotesSessionId.map(IdentifiedString.init) },
                set: { newValue in model.pendingNotesSessionId = newValue?.id }
            )) { wrapped in
                SleepNotesSheet(sessionId: wrapped.id) {
                    model.pendingNotesSessionId = nil
                }
                .environmentObject(appState)
                .presentationDetents([.medium, .large])
            }
            .environmentObject(model)
        }
    }
}

private struct IdentifiedString: Identifiable, Hashable {
    let id: String
}

// MARK: - Tonight status

private struct TonightStatusCard: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var model: HomeViewModel

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 18) {
                if let eyebrow = eyebrowLabel as LocalizedStringKey? {
                    Text(eyebrow)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .tracking(0.5)
                }

                Text(stageLabel)
                    .font(.system(size: 56, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)

                HStack(spacing: 6) {
                    StatusDot(color: statusColor)
                    Text(statusTitle)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    if let src = sourceLabel {
                        Text("·").foregroundStyle(.tertiary)
                        Text(src)
                            .font(.subheadline)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if appState.workout.isTracking {
                        Text(String(format: "%.0f%%", appState.workout.currentConfidence * 100))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }

                Button(action: {
                    Task { await model.toggleSession() }
                }) {
                    Text(appState.workout.isTracking ? LocalizedStringKey("home.action.stop") : LocalizedStringKey("home.action.start"))
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
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

    private var statusTitle: LocalizedStringKey {
        if model.isPreparingPermissions { return "home.status.preparing" }
        if appState.runtimeMode == .simulated { return "home.status.simulated" }
        if appState.workout.isTracking { return "home.status.tracking" }
        if appState.latestSummary != nil { return "home.status.ended" }
        return "home.status.idle"
    }

    private var sourceLabel: LocalizedStringKey? {
        if appState.runtimeMode == .simulated { return "home.source.simulation" }
        switch appState.workout.source {
        case .idle: return nil
        case .localPhone: return "home.source.iphone"
        case .remoteWatch: return "home.source.watch"
        }
    }

    private var eyebrowLabel: LocalizedStringKey {
        if appState.workout.isTracking { return "home.eyebrow.tracking" }
        if appState.latestSummary != nil { return "home.eyebrow.last" }
        return "home.eyebrow.tonight"
    }

    private var stageLabel: LocalizedStringKey {
        if appState.workout.isTracking {
            switch appState.workout.currentStage {
            case .wake:  return "stage.wake"
            case .light: return "stage.light"
            case .deep:  return "stage.deep"
            case .rem:   return "stage.rem"
            }
        }
        if appState.latestSummary != nil { return "home.stage.ended" }
        return "home.stage.ready"
    }
}

// MARK: - Smart alarm

private struct SmartAlarmCard: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var model: HomeViewModel

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader(title: "card.smartAlarm")

                Toggle("card.smartAlarm.enabled", isOn: $appState.alarm.isEnabled)
                    .tint(.accentColor)

                DatePicker(
                    "card.smartAlarm.wakeBy",
                    selection: $appState.alarm.target,
                    displayedComponents: [.hourAndMinute]
                )
                .disabled(!appState.alarm.isEnabled)

                Stepper(
                    String(format: NSLocalizedString("card.smartAlarm.windowFmt", comment: ""),
                           appState.alarm.windowMinutes),
                    value: $appState.alarm.windowMinutes,
                    in: 5...45,
                    step: 5
                )
                .disabled(!appState.alarm.isEnabled)

                Divider().opacity(0.5)

                HStack {
                    Text("card.smartAlarm.state").foregroundStyle(.secondary).font(.subheadline)
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
                        Text("card.smartAlarm.dismiss")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)

                    Text("alarm.shake.hint")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .modifier(ShakeToSnoozeModifier(
                isActive: appState.alarm.state == .triggered
                    || appState.alarm.state == .failedWatchUnreachable,
                onShake: { model.dismissAlarmFromPhone() }
            ))
        }
    }

    private func alarmLabel(_ s: AlarmState) -> LocalizedStringKey {
        switch s {
        case .idle: return "alarm.state.idle"
        case .armed: return "alarm.state.armed"
        case .triggered: return "alarm.state.triggered"
        case .dismissed: return "alarm.state.dismissed"
        case .failedWatchUnreachable: return "alarm.state.unreachable"
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
    @EnvironmentObject private var model: HomeViewModel

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader(title: "card.lastSession")

                if let summary = appState.latestSummary {
                    HStack(alignment: .center, spacing: 18) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(formatDuration(summary.durationSec))
                                .font(.system(size: 30, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                            Text("card.lastSession.total")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        ScoreRing(score: summary.sleepScore)
                            .frame(width: 76, height: 76)
                            .accessibilityLabel(Text("card.lastSession.score"))
                            .accessibilityValue(Text("\(summary.sleepScore)"))
                    }

                    HStack(spacing: 14) {
                        StatChip(label: "stage.deep",  value: formatDuration(summary.timeInDeepSec))
                        StatChip(label: "stage.rem",   value: formatDuration(summary.timeInRemSec))
                        StatChip(label: "stage.light", value: formatDuration(summary.timeInLightSec))
                    }

                    NavigationLink {
                        SessionDetailView(summary: summary,
                                          startedAt: appState.workout.sessionStartedAt,
                                          alarmState: appState.alarm.state,
                                          alarmTarget: appState.alarm.target,
                                          alarmWindowMinutes: appState.alarm.windowMinutes)
                    } label: {
                        HStack {
                            Text("card.lastSession.viewDetails")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .font(.subheadline)
                    }
                    .padding(.top, 2)

                    Button {
                        model.pendingNotesSessionId = summary.sessionId
                    } label: {
                        HStack {
                            Image(systemName: "tag")
                            Text("home.notes")
                        }
                        .font(.subheadline)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Text("card.lastSession.empty")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - Insights

/// Surfaces personalized rule-based suggestions from `LocalInsightsService`
/// for the most recent session. Hidden when there's no current summary or
/// no suggestions fire.
private struct InsightsCard: View {
    @EnvironmentObject private var appState: AppState

    private var suggestions: [Suggestion] {
        guard let s = appState.latestSummary else { return [] }
        return appState.insights.suggestions(from: s)
    }

    var body: some View {
        if suggestions.isEmpty {
            EmptyView()
        } else {
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.tint)
                        Text("insights.header")
                            .font(.headline)
                    }
                    ForEach(suggestions) { suggestion in
                        InsightRow(suggestion: suggestion)
                        if suggestion.id != suggestions.last?.id {
                            Divider().opacity(0.4)
                        }
                    }
                }
            }
        }
    }
}

private struct InsightRow: View {
    let suggestion: Suggestion
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: glyph(for: suggestion.id))
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .center)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: suggestion.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(verbatim: suggestion.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func glyph(for id: String) -> String {
        switch id {
        case "duration.short": return "moon.zzz"
        case "deep.low":       return "waveform.path.ecg"
        case "wake.high":      return "exclamationmark.triangle"
        default:               return "lightbulb"
        }
    }
}

// MARK: - Device & sync

private struct DeviceSyncCard: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Card {
            VStack(spacing: 10) {
                CardHeader(title: "card.deviceSync")

                Row(label: "home.source.watch",
                    value: appState.router.watchReachable
                        ? NSLocalizedString("card.deviceSync.reachable", comment: "")
                        : NSLocalizedString("card.deviceSync.no", comment: ""),
                    valueColor: appState.router.watchReachable ? .green : .secondary)
                Row(label: "card.deviceSync.lastSync", value: relativeDate(appState.router.lastBatchAt))
                Row(label: "settings.section.model",
                    value: appState.inferencePipeline.descriptor.isRealModel
                        ? NSLocalizedString("settings.model.coreml", comment: "")
                        : NSLocalizedString("settings.model.heuristic", comment: ""),
                    valueColor: appState.inferencePipeline.descriptor.isRealModel ? .green : .orange)
            }
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
                CardHeader(title: "Developer")
            }
        }
    }
}

// MARK: - Generic UI atoms

private struct Card<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .padding(.horizontal, 18)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct CardHeader: View {
    let title: LocalizedStringKey
    var body: some View {
        Text(title)
            .font(.title3.weight(.bold))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 2)
    }
}

private struct Row: View {
    let label: LocalizedStringKey
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
    let label: LocalizedStringKey
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

/// Apple Health-style circular score indicator. The arc length encodes
/// the score (0-100) and the color shifts from amber to green across
/// the same range. Uses `design: .rounded` for the numeric SF style.
private struct ScoreRing: View {
    let score: Int

    private var fraction: Double {
        Double(min(max(score, 0), 100)) / 100.0
    }

    private var tint: Color {
        switch score {
        case ..<50:  return .orange
        case 50..<75: return .yellow
        default:     return .green
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.15), lineWidth: 6)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(tint, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.6), value: fraction)
            VStack(spacing: 0) {
                Text("\(score)")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                Text("card.lastSession.score")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
            }
        }
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
                Text("recovery.title")
                    .font(.headline)
                    .foregroundStyle(.primary)
                if let m = appState.interruptedSessionStart {
                    Text(String(format: NSLocalizedString("recovery.bodyFormat", comment: ""),
                                formattedDate(m.startedAt)))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 12) {
                    Button {
                        Task { await appState.finishInterruptedAndSave() }
                    } label: {
                        Text("recovery.finish")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)

                    Button(role: .destructive) {
                        Task { await appState.discardInterruptedSession() }
                    } label: {
                        Text("recovery.discard")
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

// MARK: - Shake to snooze (alarm)

/// Wires a `ShakeToSnoozeDetector` to a view's lifecycle. Active only while
/// `isActive == true`, so we never poll accelerometer outside the trigger UI.
private struct ShakeToSnoozeModifier: ViewModifier {
    let isActive: Bool
    let onShake: () -> Void

    @State private var detector = ShakeToSnoozeDetector()

    func body(content: Content) -> some View {
        content
            .onAppear { restart() }
            .onDisappear { detector.stop() }
            .onChange(of: isActive) { _, _ in restart() }
    }

    private func restart() {
        detector.stop()
        if isActive {
            detector.start { onShake() }
        }
    }
}
