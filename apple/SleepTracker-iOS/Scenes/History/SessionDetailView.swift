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
            VStack(spacing: 16) {
                headerCard
                breakdownCard
                timelineCard
                alarmCard
                notesCard
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("Session")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Cards

    private var headerCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                if let startedAt {
                    Text(startedAt, format: .dateTime.weekday(.wide).month().day())
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(formatDuration(summary.durationSec))
                            .font(.system(size: 34, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text("Total sleep").font(.caption).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(summary.sleepScore)")
                            .font(.system(size: 34, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text("Score").font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private var breakdownCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader(title: "Stages", systemImage: "chart.bar")
                StageRow(label: "Awake", color: .red.opacity(0.7), seconds: summary.timeInWakeSec, total: summary.durationSec)
                StageRow(label: "Light", color: .blue.opacity(0.5),  seconds: summary.timeInLightSec, total: summary.durationSec)
                StageRow(label: "Deep",  color: .indigo,             seconds: summary.timeInDeepSec, total: summary.durationSec)
                StageRow(label: "REM",   color: .purple,             seconds: summary.timeInRemSec, total: summary.durationSec)
            }
        }
    }

    private var timelineCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                CardHeader(title: "Timeline", systemImage: "waveform.path")
                if !realTimeline.isEmpty {
                    SleepTimelineView(entries: realTimeline)
                } else if let entries = syntheticEntries() {
                    SleepTimelineView(entries: entries)
                    Text("Approximate timeline")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("Timeline not available for this session.")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var alarmCard: some View {
        Card {
            VStack(spacing: 10) {
                CardHeader(title: "Smart Alarm", systemImage: "alarm")
                Row(label: "Result", value: alarmResultText, valueColor: alarmResultColor)
                if let alarmTarget {
                    Row(label: "Target",
                        value: alarmTarget.formatted(date: .omitted, time: .shortened))
                }
                Row(label: "Window", value: "\(alarmWindowMinutes) min")
            }
        }
    }

    private var notesCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                CardHeader(title: "Notes", systemImage: "note.text")
                Text("No notes yet.")
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
        case .idle: return "Disabled"
        case .armed: return "Armed (no trigger)"
        case .triggered: return "Triggered"
        case .dismissed: return "Triggered & dismissed"
        case .failedWatchUnreachable: return "Watch unreachable"
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
            Image(systemName: systemImage).font(.footnote).foregroundStyle(.tertiary)
            Text(title).font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary).textCase(.uppercase)
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

private struct StageRow: View {
    let label: String
    let color: Color
    let seconds: Int
    let total: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.subheadline)
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
