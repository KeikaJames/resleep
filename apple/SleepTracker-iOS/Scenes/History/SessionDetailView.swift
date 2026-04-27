import SwiftUI
import SleepKit

/// Read-only detail screen for a single session summary. The on-disk
/// timeline lives in the Rust-side `stage_timeline` table and is not yet
/// surfaced through `LocalStoreProtocol`; until that wire is plumbed we
/// render a low-fidelity placeholder so the layout is locked in.
struct SessionDetailView: View {
    let summary: SessionSummary
    let startedAt: Date?
    let alarmState: AlarmState
    let alarmTarget: Date?
    let alarmWindowMinutes: Int
    /// Real persisted timeline. Empty array → synthetic fallback (labelled).
    var realTimeline: [TimelineEntry] = []

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                headerCard
                breakdownCard
                timelineCard
                alarmCard
                notesCard
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(Text("detail.title"))
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Cards

    private var headerCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                if let startedAt {
                    Text(startedAt, format: .dateTime.weekday(.wide).month().day())
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                }
                Text(formatDuration(summary.durationSec))
                    .font(.system(size: 56, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("detail.score")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("\(summary.sleepScore)")
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                }
            }
        }
    }

    private var breakdownCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader(titleKey: "detail.stages")
                StageRow(labelKey: "stage.wake",  color: .red.opacity(0.7), seconds: summary.timeInWakeSec, total: summary.durationSec)
                StageRow(labelKey: "stage.light", color: .blue.opacity(0.5),  seconds: summary.timeInLightSec, total: summary.durationSec)
                StageRow(labelKey: "stage.deep",  color: .indigo,             seconds: summary.timeInDeepSec, total: summary.durationSec)
                StageRow(labelKey: "stage.rem",   color: .purple,             seconds: summary.timeInRemSec, total: summary.durationSec)
            }
        }
    }

    private var timelineCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                CardHeader(titleKey: "detail.timeline")
                if !realTimeline.isEmpty {
                    SleepTimelineView(entries: realTimeline)
                } else if let entries = syntheticEntries() {
                    SleepTimelineView(entries: entries)
                    Text("detail.timeline.approx")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("detail.timeline.none")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var alarmCard: some View {
        Card {
            VStack(spacing: 10) {
                CardHeader(titleKey: "detail.alarm")
                Row(labelKey: "detail.alarm.result", value: alarmResultText, valueColor: alarmResultColor)
                if let alarmTarget {
                    Row(labelKey: "detail.alarm.target",
                        value: alarmTarget.formatted(date: .omitted, time: .shortened))
                }
                Row(labelKey: "detail.alarm.window",
                    value: String(format: NSLocalizedString("detail.alarm.windowVal", comment: ""),
                                  alarmWindowMinutes))
            }
        }
    }

    private var notesCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                CardHeader(titleKey: "detail.notes")
                Text("detail.notes.empty")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Helpers

    /// Builds a coarse 4-block placeholder timeline from the per-stage
    /// totals. Replaced by real `stage_timeline` data when the Rust read
    /// path is exposed through `LocalStoreProtocol`.
    private func syntheticEntries() -> [TimelineEntry]? {
        guard summary.durationSec > 0 else { return nil }
        let start = startedAt ?? Date().addingTimeInterval(-TimeInterval(summary.durationSec))
        var t = start
        var out: [TimelineEntry] = []
        let buckets: [(SleepStage, Int)] = [
            (.wake,  summary.timeInWakeSec),
            (.light, summary.timeInLightSec),
            (.deep,  summary.timeInDeepSec),
            (.rem,   summary.timeInRemSec)
        ].filter { $0.1 > 0 }
        guard !buckets.isEmpty else { return nil }
        for (stage, sec) in buckets {
            let end = t.addingTimeInterval(TimeInterval(sec))
            out.append(TimelineEntry(stage: stage, start: t, end: end))
            t = end
        }
        return out
    }

    private var alarmResultText: String {
        switch alarmState {
        case .idle: return NSLocalizedString("detail.alarm.idle", comment: "")
        case .armed: return NSLocalizedString("detail.alarm.armed", comment: "")
        case .triggered: return NSLocalizedString("detail.alarm.triggered", comment: "")
        case .dismissed: return NSLocalizedString("detail.alarm.dismissed", comment: "")
        case .failedWatchUnreachable: return NSLocalizedString("detail.alarm.unreachable", comment: "")
        }
    }

    private var alarmResultColor: Color {
        switch alarmState {
        case .idle: return .secondary
        case .armed: return .blue
        case .triggered: return .red
        case .dismissed: return .green
        case .failedWatchUnreachable: return .orange
        }
    }
}

// MARK: - Local atoms (kept private to detail scene)

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
    let titleKey: LocalizedStringKey
    var body: some View {
        Text(titleKey)
            .font(.title3.weight(.bold))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 2)
    }
}

private struct Row: View {
    let labelKey: LocalizedStringKey
    let value: String
    var valueColor: Color = .secondary
    var body: some View {
        HStack {
            Text(labelKey).font(.subheadline).foregroundStyle(.primary)
            Spacer()
            Text(value).font(.subheadline).foregroundStyle(valueColor)
        }
    }
}

private struct StageRow: View {
    let labelKey: LocalizedStringKey
    let color: Color
    let seconds: Int
    let total: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(labelKey).font(.subheadline)
                Spacer()
                Text(formatDuration(seconds))
                    .font(.subheadline.weight(.medium)).monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.15))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color)
                        .frame(width: geo.size.width * CGFloat(fraction))
                }
            }
            .frame(height: 6)
        }
    }
    private var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1.0, Double(seconds) / Double(total))
    }
}
