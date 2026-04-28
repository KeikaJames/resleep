import SwiftUI
import SleepKit

/// Watch is the wrist remote: one glance, one primary action.
/// Detailed sleep analysis belongs on iPhone.
struct WatchHomeView: View {
    @EnvironmentObject private var state: WatchAppState

    var body: some View {
        Group {
            if state.isAlarmActive {
                alarmScreen
            } else {
                sleepRemote
            }
        }
    }

    private var sleepRemote: some View {
        VStack(spacing: 7) {
            connectionPill

            Spacer(minLength: 1)

            Image(systemName: state.isTracking ? "moon.zzz.fill" : "moon.stars.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(state.isTracking ? .blue : .indigo)
                .frame(height: 42)

            VStack(spacing: 2) {
                Text(heroTitleKey)
                    .font(.headline.weight(.bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                Text(heroSubtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(height: 42)

            Spacer(minLength: 1)

            primaryButton

            if let alarmStatus = alarmStatusText {
                compactNotice(text: alarmStatus, tint: .orange, systemImage: "alarm.fill")
            }

            if let err = state.lastError {
                compactNotice(text: err, tint: .red, systemImage: "exclamationmark.triangle.fill")
            }

        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    private var alarmScreen: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 2)
            Image(systemName: "alarm.fill")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(.white)
                .symbolEffect(.pulse)
            Text("watch.alarm.banner")
                .font(.title3.weight(.bold))
                .multilineTextAlignment(.center)
            Text("watch.alarm.subtitle")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.78))
                .multilineTextAlignment(.center)
                .lineLimit(1)
            Spacer(minLength: 2)
            Button {
                state.dismissAlarmFromWatch()
            } label: {
                Text("watch.alarm.dismiss")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(.white)
            .foregroundStyle(.red)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(colors: [.red, .red.opacity(0.78), .black],
                           startPoint: .top,
                           endPoint: .bottom)
        )
    }

    private var connectionPill: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(state.phoneReachable ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            Text(state.phoneReachable ? "watch.link.reachable" : "watch.link.offline")
                .font(.caption2.weight(.medium))
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.white.opacity(0.1)))
    }

    private var primaryButton: some View {
        Button {
            Task {
                if state.isTracking { await state.manualStop() }
                else { await state.manualStart() }
            }
        } label: {
            HStack(spacing: 8) {
                if state.isStarting {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: state.isTracking ? "stop.fill" : "bed.double.fill")
                }
                Text(primaryActionKey)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
        }
        .buttonStyle(.borderedProminent)
        .tint(state.isTracking ? .red : .blue)
        .disabled(state.isStarting)
    }

    private var heroTitleKey: LocalizedStringKey {
        if state.isStarting { return "watch.hero.starting" }
        return state.isTracking ? "watch.hero.tracking" : "watch.hero.ready"
    }

    private var heroSubtitle: String {
        if state.isStarting {
            return NSLocalizedString("watch.hero.startingSubtitle", comment: "")
        }
        if state.isTracking { return trackingSummary }
        if state.sleepPlan.autoTrackingEnabled {
            let bedtime = state.sleepPlan.decision().window.bedtime
                .formatted(date: .omitted, time: .shortened)
            return String(format: NSLocalizedString("watch.hero.autoSubtitle", comment: ""), bedtime)
        }
        return NSLocalizedString("watch.hero.readySubtitle", comment: "")
    }

    private var primaryActionKey: LocalizedStringKey {
        if state.isStarting { return "watch.action.starting" }
        return state.isTracking ? "watch.action.stop" : "watch.action.start"
    }

    private var trackingSummary: String {
        let stage = stageLabel
        guard let bpm = state.latestHeartRate else { return stage }
        let heart = String(format: NSLocalizedString("watch.metric.bpm", comment: ""), Int(bpm.rounded()))
        return "\(stage) · \(heart)"
    }

    private var stageLabel: String {
        guard state.isTracking else { return NSLocalizedString("watch.stage.idle", comment: "") }
        guard let stage = state.currentStage else { return NSLocalizedString("watch.stage.loading", comment: "") }
        switch stage {
        case .wake:  return NSLocalizedString("stage.wake", comment: "")
        case .light: return NSLocalizedString("stage.light", comment: "")
        case .deep:  return NSLocalizedString("stage.deep", comment: "")
        case .rem:   return NSLocalizedString("stage.rem", comment: "")
        }
    }

    private var alarmStatusText: String? {
        guard state.alarmState != .idle else { return nil }
        switch state.alarmState {
        case .idle:                   return nil
        case .armed:                  return NSLocalizedString("watch.alarm.armed", comment: "")
        case .triggered:              return NSLocalizedString("watch.alarm.triggered", comment: "")
        case .dismissed:              return NSLocalizedString("watch.alarm.dismissed", comment: "")
        case .failedWatchUnreachable: return NSLocalizedString("watch.alarm.linkFailure", comment: "")
        }
    }

    private func compactNotice(text: String, tint: Color, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(text)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .font(.caption2)
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(tint.opacity(0.15))
        )
    }
}
