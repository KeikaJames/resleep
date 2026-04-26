import SwiftUI
import SleepKit

struct HistoryView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var vm = HistoryViewModel()

    var body: some View {
        NavigationStack {
            Group {
                if vm.sessions.isEmpty {
                    ContentUnavailableView(
                        "No sleep records yet",
                        systemImage: "moon.zzz",
                        description: Text("Track a night to see it here.")
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 14) {
                            ForEach(vm.sessions) { session in
                                NavigationLink {
                                    detailFor(session)
                                } label: {
                                    SessionRow(session: session,
                                               summary: vm.summary(for: session.id))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                        .padding(.bottom, 32)
                    }
                    .background(Color(.systemGroupedBackground).ignoresSafeArea())
                }
            }
            .navigationTitle("History")
            .task { await vm.load(appState: appState) }
            .refreshable { await vm.load(appState: appState) }
        }
    }

    @ViewBuilder
    private func detailFor(_ session: SleepSession) -> some View {
        if let summary = vm.summary(for: session.id) {
            let rec = vm.record(for: session.id)
            SessionDetailView(
                summary: summary,
                startedAt: session.startedAt,
                alarmState: rec?.alarm?.finalState ?? .idle,
                alarmTarget: rec?.alarm?.target,
                alarmWindowMinutes: rec?.alarm?.windowMinutes ?? appState.alarm.windowMinutes,
                realTimeline: rec?.timeline ?? []
            )
        } else {
            ContentUnavailableView(
                "Summary unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text("This session has no stored summary yet.")
            )
        }
    }
}

private struct SessionRow: View {
    let session: SleepSession
    let summary: SessionSummary?

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.startedAt, format: .dateTime.weekday(.abbreviated).month().day())
                    .font(.headline)
                    .foregroundStyle(.primary)
                if let end = session.endedAt {
                    Text("\(session.startedAt, style: .time) – \(end, style: .time)")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("In progress")
                        .font(.subheadline)
                        .foregroundStyle(.green)
                }
            }
            Spacer()
            if let summary {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(formatDuration(summary.durationSec))
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                    Text("Score \(summary.sleepScore)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }
}
