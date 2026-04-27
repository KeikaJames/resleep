import SwiftUI
import Charts
import SleepKit

/// Apple-style trends view. Quiet typography, system colors, no decoration.
/// Two charts:
///   1. Sleep score (last 30 nights) – line chart with current average
///   2. Stage composition (last 7 nights) – horizontal stacked bar
struct TrendsView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var model = TrendsViewModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if model.records.isEmpty {
                        EmptyState()
                            .padding(.top, 80)
                    } else {
                        ScoreCard(records: model.records)
                        StagesCard(records: model.records)
                        AveragesCard(records: model.records)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle(Text("trends.title"))
            .task { await model.refresh(localStore: appState.localStore) }
            .refreshable { await model.refresh(localStore: appState.localStore) }
        }
    }
}

@MainActor
final class TrendsViewModel: ObservableObject {
    @Published private(set) var records: [StoredSessionRecord] = []

    func refresh(localStore: LocalStoreProtocol) async {
        let recent = (try? await localStore.listSessions(limit: 30)) ?? []
        var fetched: [StoredSessionRecord] = []
        for s in recent {
            if let r = try? await localStore.record(for: s.id) { fetched.append(r) }
        }
        // Sort newest first; charts will reverse for x-axis when needed.
        records = fetched.sorted { $0.startedAt > $1.startedAt }
    }
}

// MARK: - Subviews

private struct EmptyState: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("trends.empty.title")
                .font(.title3.weight(.semibold))
            Text("trends.empty.subtitle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ScoreCard: View {
    let records: [StoredSessionRecord]

    private var points: [(date: Date, score: Int)] {
        records.compactMap { r in
            guard let s = r.summary else { return nil }
            return (r.startedAt, s.sleepScore)
        }
        .sorted { $0.date < $1.date }
    }

    var body: some View {
        Card(title: "trends.score.title", subtitle: "trends.score.subtitle") {
            Chart(points, id: \.date) { p in
                LineMark(x: .value("Date", p.date),
                         y: .value("Score", p.score))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                PointMark(x: .value("Date", p.date),
                          y: .value("Score", p.score))
                    .symbolSize(26)
            }
            .chartYScale(domain: 0...100)
            .chartYAxis {
                AxisMarks(values: [0, 50, 100]) { _ in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel()
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 5)) { _ in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day(),
                                   centered: true)
                }
            }
            .frame(height: 200)
        }
    }
}

private struct StagesCard: View {
    let records: [StoredSessionRecord]

    private struct Slice: Identifiable {
        let id = UUID()
        let date: Date
        let stage: String
        let seconds: Int
        let order: Int
    }

    private var slices: [Slice] {
        records.prefix(7).flatMap { r -> [Slice] in
            guard let s = r.summary else { return [] }
            return [
                Slice(date: r.startedAt, stage: NSLocalizedString("stage.deep", comment: ""),
                      seconds: s.timeInDeepSec, order: 0),
                Slice(date: r.startedAt, stage: NSLocalizedString("stage.rem", comment: ""),
                      seconds: s.timeInRemSec, order: 1),
                Slice(date: r.startedAt, stage: NSLocalizedString("stage.light", comment: ""),
                      seconds: s.timeInLightSec, order: 2),
                Slice(date: r.startedAt, stage: NSLocalizedString("stage.wake", comment: ""),
                      seconds: s.timeInWakeSec, order: 3),
            ]
        }
    }

    var body: some View {
        Card(title: "trends.stages.title", subtitle: "trends.stages.subtitle") {
            Chart(slices) { s in
                BarMark(
                    x: .value("Hours", Double(s.seconds) / 3600.0),
                    y: .value("Date", s.date, unit: .day)
                )
                .foregroundStyle(by: .value("Stage", s.stage))
                .position(by: .value("Order", s.order))
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel()
                }
            }
            .chartLegend(position: .bottom, alignment: .center, spacing: 8)
            .frame(height: 220)
        }
    }
}

private struct AveragesCard: View {
    let records: [StoredSessionRecord]

    private var avgScore: Int {
        let s = records.compactMap { $0.summary?.sleepScore }
        guard !s.isEmpty else { return 0 }
        return s.reduce(0, +) / s.count
    }

    private var avgDurationHours: Double {
        let d = records.compactMap { $0.summary?.durationSec }
        guard !d.isEmpty else { return 0 }
        return Double(d.reduce(0, +)) / Double(d.count) / 3600.0
    }

    var body: some View {
        Card(title: "trends.averages.title") {
            HStack(alignment: .top, spacing: 24) {
                StatColumn(label: "trends.averages.score",
                           value: "\(avgScore)",
                           sub: "trends.averages.scoreSub")
                Divider().frame(height: 44)
                StatColumn(label: "trends.averages.duration",
                           value: String(format: "%.1f", avgDurationHours),
                           sub: "trends.averages.durationSub")
                Divider().frame(height: 44)
                StatColumn(label: "trends.averages.nights",
                           value: "\(records.count)",
                           sub: "trends.averages.nightsSub")
            }
        }
    }
}

private struct StatColumn: View {
    let label: LocalizedStringKey
    let value: String
    let sub: LocalizedStringKey
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
            Text(sub)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct Card<Content: View>: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey? = nil
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }
}
