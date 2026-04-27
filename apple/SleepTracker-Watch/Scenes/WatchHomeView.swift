import SwiftUI
import SleepKit

/// Companion-only watch UI. The phone is the product; the watch is just a
/// sensor + alarm actuator. Show only what the wrist actually needs at
/// 3am: tracking state, phone link, current stage, alarm state, and a
/// big Dismiss when the alarm is firing.
struct WatchHomeView: View {
    @EnvironmentObject private var state: WatchAppState

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                if state.isAlarmActive {
                    alarmBanner
                }
                stateRow
                stageRow
                linkRow
                if state.alarmState != .idle && !state.isAlarmActive {
                    Text(alarmLabel(state.alarmState))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                controlButton
                if let mode = state.runtimeModeRaw {
                    Text(mode == "simulated" ? "SIM" : "LIVE")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(mode == "simulated" ? .orange : .secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                if let err = state.lastError {
                    Text(err).font(.caption2).foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 6)
        }
        .navigationTitle("watch.title")
    }

    // MARK: Rows

    private var stateRow: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(state.isTracking ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
            Text(state.isTracking ? "watch.state.tracking" : "watch.state.idle")
                .font(.caption.weight(.semibold))
            Spacer()
        }
    }

    private var stageRow: some View {
        HStack {
            Text(stageLabel)
                .font(.title3.weight(.semibold))
            Spacer()
        }
    }

    private var linkRow: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(state.phoneReachable ? Color.green : Color.orange)
                .frame(width: 6, height: 6)
            Text(state.phoneReachable ? "watch.link.reachable" : "watch.link.offline")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var alarmBanner: some View {
        VStack(spacing: 6) {
            Text("watch.alarm.banner")
                .font(.headline)
                .foregroundStyle(.white)
            Button(role: .destructive) {
                state.dismissAlarmFromWatch()
            } label: {
                Text("watch.alarm.dismiss")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(.white)
            .foregroundStyle(.red)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(Color.red, in: RoundedRectangle(cornerRadius: 10))
    }

    private var controlButton: some View {
        Button {
            Task {
                if state.isTracking { await state.manualStop() }
                else { await state.manualStart() }
            }
        } label: {
            Text(state.isTracking ? "watch.action.stop" : "watch.action.start")
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(state.isTracking ? .red : .accentColor)
    }

    // MARK: Helpers

    private var stageLabel: String {
        guard state.isTracking else { return NSLocalizedString("watch.stage.dash", comment: "") }
        guard let s = state.currentStage else { return NSLocalizedString("watch.stage.loading", comment: "") }
        switch s {
        case .wake:  return NSLocalizedString("stage.wake", comment: "")
        case .light: return NSLocalizedString("stage.light", comment: "")
        case .deep:  return NSLocalizedString("stage.deep", comment: "")
        case .rem:   return NSLocalizedString("stage.rem", comment: "")
        }
    }

    private func alarmLabel(_ s: AlarmState) -> String {
        switch s {
        case .idle:                    return ""
        case .armed:                   return NSLocalizedString("watch.alarm.armed", comment: "")
        case .triggered:               return NSLocalizedString("watch.alarm.triggered", comment: "")
        case .dismissed:               return NSLocalizedString("watch.alarm.dismissed", comment: "")
        case .failedWatchUnreachable:  return NSLocalizedString("watch.alarm.linkFailure", comment: "")
        }
    }
}
