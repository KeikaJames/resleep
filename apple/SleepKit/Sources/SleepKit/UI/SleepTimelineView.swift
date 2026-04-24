#if canImport(SwiftUI)
import SwiftUI

public struct TimelineEntry: Identifiable, Sendable, Equatable {
    public let id = UUID()
    public let stage: SleepStage
    public let start: Date
    public let end: Date
    public init(stage: SleepStage, start: Date, end: Date) {
        self.stage = stage
        self.start = start
        self.end = end
    }
}

/// Minimal timeline renderer so the iOS scenes have something to present while
/// the real Charts-based view is built out.
public struct SleepTimelineView: View {
    public let entries: [TimelineEntry]

    public init(entries: [TimelineEntry]) {
        self.entries = entries
    }

    public var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(entries) { entry in
                    Rectangle()
                        .fill(color(for: entry.stage))
                        .frame(width: max(2, width(for: entry, total: geo.size.width)))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .frame(height: 24)
    }

    private func color(for stage: SleepStage) -> Color {
        switch stage {
        case .wake:  return .red.opacity(0.6)
        case .light: return .blue.opacity(0.4)
        case .deep:  return .indigo
        case .rem:   return .purple
        }
    }

    private func width(for entry: TimelineEntry, total: CGFloat) -> CGFloat {
        let totalSpan = entries.last.map { $0.end.timeIntervalSince(entries.first?.start ?? $0.start) } ?? 1
        guard totalSpan > 0 else { return 0 }
        let span = entry.end.timeIntervalSince(entry.start)
        return CGFloat(span / totalSpan) * total
    }
}

#if DEBUG && canImport(SwiftUI)
// Xcode previews: invoke `SleepTimelineView(entries:)` with canned entries.
// We intentionally avoid the `#Preview` macro here so SleepKit builds both via
// Xcode and via `swift build` on macOS toolchains that lack the preview plugin.
#endif
#endif
