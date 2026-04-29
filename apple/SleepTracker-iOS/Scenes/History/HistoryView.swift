import SwiftUI
import SleepKit

struct HistoryView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var vm = HistoryViewModel()

    var body: some View {
        NavigationStack {
            Group {
                if vm.sessions.isEmpty && appState.passiveNights.isEmpty {
                    ContentUnavailableView(
                        "history.empty.title",
                        systemImage: "moon.zzz",
                        description: Text("history.empty.subtitle")
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 14) {
                            if !appState.passiveNights.isEmpty {
                                PassiveNightsSection(nights: appState.passiveNights)
                            }
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
            .navigationTitle("history.title")
            .task {
                await vm.load(appState: appState)
                await appState.refreshPassiveNights()
            }
            .refreshable {
                await vm.load(appState: appState)
                await appState.refreshPassiveNights()
            }
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
                "history.summaryUnavailable.title",
                systemImage: "moon.zzz",
                description: Text("history.summaryUnavailable.body")
            )
        }
    }
}

private struct PassiveNightsSection: View {
    let nights: [PassiveSleepNight]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "applewatch")
                    .font(.caption.weight(.semibold))
                Text("history.passive.title")
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .tracking(0.4)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)

            ForEach(nights) { night in
                PassiveNightRow(night: night)
            }
        }
    }
}

private struct PassiveNightRow: View {
    let night: PassiveSleepNight
    private var evidence: NightEvidenceAssessment {
        NightEvidence(passiveNight: night).assessment
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(night.startedAt, format: .dateTime.weekday(.abbreviated).month().day())
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text("\(night.startedAt, style: .time) – \(night.endedAt, style: .time)")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                HStack(spacing: 6) {
                    passiveBadge
                    confidenceBadge
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(formatDuration(night.asleepSec))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                Text("history.passive.asleep")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.16), lineWidth: 1)
        )
    }

    private var passiveBadge: some View {
        HStack(spacing: 5) {
            Image(systemName: night.isAppleWatchOriginated ? "applewatch.watchface" : "heart.text.square")
                .font(.caption2.weight(.semibold))
            Text(night.isAppleWatchOriginated
                 ? NSLocalizedString("history.passive.source.appleWatch", comment: "")
                 : NSLocalizedString("history.passive.source.health", comment: ""))
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.accentColor.opacity(0.10)))
    }

    private var confidenceBadge: some View {
        Text(String(format: NSLocalizedString("history.evidence.confidence", comment: ""),
                    evidence.confidencePercent))
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(evidence.quality == .low ? .orange : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill((evidence.quality == .low ? Color.orange : Color.accentColor)
                    .opacity(0.10))
            )
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
                    Text("history.inProgress")
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
                    Text("\(NSLocalizedString("history.score", comment: "")) \(summary.sleepScore)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
    }
}
