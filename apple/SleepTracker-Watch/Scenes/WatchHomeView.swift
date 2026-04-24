import SwiftUI
import SleepKit

struct WatchHomeView: View {
    @EnvironmentObject private var state: WatchAppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if state.isAlarmActive {
                    alarmBanner
                }
                header
                metricsBlock
                linkBlock
                controlButton
                if let err = state.lastError {
                    Text(err).font(.caption2).foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 6)
        }
        .navigationTitle("Sleep")
    }

    private var header: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(state.isTracking ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
            Text(state.isTracking ? "Tracking" : "Idle")
                .font(.caption).bold()
            Spacer()
            if let stage = state.currentStage {
                Text(stage.displayName)
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.gray.opacity(0.3), in: Capsule())
            }
        }
    }

    private var metricsBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let hr = state.latestHeartRate {
                Text("\(Int(hr.rounded())) bpm").font(.title3).bold()
            } else {
                Text("— bpm").font(.title3).foregroundStyle(.secondary)
            }
            if let t = state.latestHeartRateAt {
                Text("hr \(t.formatted(.relative(presentation: .numeric)))")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var linkBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Circle()
                    .fill(state.phoneReachable ? Color.green : Color.orange)
                    .frame(width: 6, height: 6)
                Text(state.phoneReachable ? "Phone reachable" : "Phone offline")
                    .font(.caption2)
            }
            if let t = state.lastBatchSentAt {
                Text("last batch \(t.formatted(.relative(presentation: .numeric)))")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            if state.pendingGuaranteedCount > 0 {
                Text("pending \(state.pendingGuaranteedCount)")
                    .font(.caption2).foregroundStyle(.orange)
            }
            if state.smartAlarmArmed {
                Text("alarm armed").font(.caption2).foregroundStyle(.blue)
            }
            if state.alarmState != .idle && state.alarmState != .armed {
                Text("alarm: \(state.alarmState.rawValue)")
                    .font(.caption2).foregroundStyle(.orange)
            }
            debugStrip
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var debugStrip: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let conf = state.currentConfidence {
                Text(String(format: "conf %.2f", conf))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let sid = state.currentSessionId {
                Text("sess \(sid.prefix(6))")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private var alarmBanner: some View {
        VStack(spacing: 6) {
            Text("⏰ Wake up")
                .font(.headline)
                .foregroundStyle(.white)
            Button(role: .destructive) {
                state.dismissAlarmFromWatch()
            } label: {
                Text("Dismiss")
                    .font(.body).bold()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
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
            Text(state.isTracking ? "Stop" : "Start")
                .font(.caption).bold()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(state.isTracking ? .red : .accentColor)
    }
}
