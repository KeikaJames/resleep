import Foundation

// MARK: - Stored record types

/// Persisted alarm metadata for a finished session. All fields are
/// optional except `enabled` and `finalState`, so old records can be
/// migrated forward without breaking decode.
public struct StoredAlarmMeta: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var finalStateRaw: String
    public var targetTsMs: Int64?
    public var windowMinutes: Int
    public var triggeredAtTsMs: Int64?
    public var dismissedAtTsMs: Int64?

    public init(
        enabled: Bool,
        finalStateRaw: String,
        targetTsMs: Int64? = nil,
        windowMinutes: Int = 0,
        triggeredAtTsMs: Int64? = nil,
        dismissedAtTsMs: Int64? = nil
    ) {
        self.enabled = enabled
        self.finalStateRaw = finalStateRaw
        self.targetTsMs = targetTsMs
        self.windowMinutes = windowMinutes
        self.triggeredAtTsMs = triggeredAtTsMs
        self.dismissedAtTsMs = dismissedAtTsMs
    }

    public var finalState: AlarmState { AlarmState(rawValue: finalStateRaw) ?? .idle }
    public var target: Date? { targetTsMs.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) } }
    public var triggeredAt: Date? { triggeredAtTsMs.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) } }
    public var dismissedAt: Date? { dismissedAtTsMs.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) } }
}

/// One persisted local sleep session — the unit Home / History / Detail
/// read at app launch. Owns its own timeline so detail can render
/// without a second round-trip.
public struct StoredSessionRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var startedAt: Date
    public var endedAt: Date?
    public var summary: SessionSummary?
    public var alarm: StoredAlarmMeta?
    public var sourceRaw: String?           // TrackingSource raw
    public var runtimeModeRaw: String?      // "live" | "simulated"
    public var notes: String?
    public var timeline: [TimelineEntry]

    public init(
        id: String,
        startedAt: Date,
        endedAt: Date? = nil,
        summary: SessionSummary? = nil,
        alarm: StoredAlarmMeta? = nil,
        sourceRaw: String? = nil,
        runtimeModeRaw: String? = nil,
        notes: String? = nil,
        timeline: [TimelineEntry] = []
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.summary = summary
        self.alarm = alarm
        self.sourceRaw = sourceRaw
        self.runtimeModeRaw = runtimeModeRaw
        self.notes = notes
        self.timeline = timeline
    }

    public func toSession(fallbackStage: SleepStage = .wake) -> SleepSession {
        SleepSession(id: id, startedAt: startedAt, endedAt: endedAt, stage: fallbackStage)
    }
}

// MARK: - Protocol

/// Swift-side read/write surface over local product data. The default
/// app-runtime backend is `PersistentLocalStore` (file-backed JSON in
/// Application Support); `InMemoryLocalStore` is retained for tests
/// and previews. Existing `recordLocalSummary(_:startedAt:)` is kept
/// for back-compat with the M3-era flow but new callers should prefer
/// `recordSessionRecord(_:)`.
public protocol LocalStoreProtocol: Sendable {
    func listSessions(limit: Int) async throws -> [SleepSession]
    func summary(for sessionId: String) async throws -> SessionSummary?
    func recordLocalSummary(_ summary: SessionSummary, startedAt: Date) async throws

    /// Returns the full record (summary + alarm meta + timeline + source).
    func record(for sessionId: String) async throws -> StoredSessionRecord?

    /// Upserts a full session record. Replaces any prior record with the
    /// same `id`. New canonical write path used by the iOS app loop.
    func recordSessionRecord(_ record: StoredSessionRecord) async throws

    /// Returns timeline entries ordered by start time. Empty if none
    /// were persisted (caller may then synthesize from summary totals).
    func timeline(for sessionId: String) async throws -> [TimelineEntry]

    /// Atomically appends new timeline entries to a session record. Used
    /// by mid-session checkpoints if/when added; the iOS app currently
    /// flushes the whole timeline once at stop time.
    func recordTimelineEntries(_ entries: [TimelineEntry], for sessionId: String) async throws

    /// Returns the most recently completed session's summary (highest
    /// `endedAt`). Used by Home to restore Last Session card on launch.
    func latestCompletedSummary() async throws -> SessionSummary?

    /// Wipes every locally-stored sleep record, summary, and timeline.
    /// Used by Settings → Delete Local Sleep Data.
    func clearAllLocalData() async throws
}

// MARK: - In-memory backend (tests / previews)

public actor InMemoryLocalStore: LocalStoreProtocol {
    private var records: [String: StoredSessionRecord] = [:]

    public init() {}

    public func listSessions(limit: Int) -> [SleepSession] {
        records.values
            .sorted { $0.startedAt > $1.startedAt }
            .prefix(limit)
            .map { $0.toSession() }
    }

    public func summary(for sessionId: String) -> SessionSummary? {
        records[sessionId]?.summary
    }

    public func recordLocalSummary(_ summary: SessionSummary, startedAt: Date) {
        let endedAt = startedAt.addingTimeInterval(TimeInterval(summary.durationSec))
        let prior = records[summary.sessionId]
        let merged = StoredSessionRecord(
            id: summary.sessionId,
            startedAt: startedAt,
            endedAt: endedAt,
            summary: summary,
            alarm: prior?.alarm,
            sourceRaw: prior?.sourceRaw,
            runtimeModeRaw: prior?.runtimeModeRaw,
            notes: prior?.notes,
            timeline: prior?.timeline ?? []
        )
        records[summary.sessionId] = merged
    }

    public func record(for sessionId: String) -> StoredSessionRecord? {
        records[sessionId]
    }

    public func recordSessionRecord(_ record: StoredSessionRecord) {
        records[record.id] = record
    }

    public func timeline(for sessionId: String) -> [TimelineEntry] {
        (records[sessionId]?.timeline ?? []).sorted { $0.start < $1.start }
    }

    public func recordTimelineEntries(_ entries: [TimelineEntry], for sessionId: String) {
        guard var rec = records[sessionId] else { return }
        rec.timeline.append(contentsOf: entries)
        rec.timeline.sort { $0.start < $1.start }
        records[sessionId] = rec
    }

    public func latestCompletedSummary() -> SessionSummary? {
        records.values
            .filter { $0.summary != nil && $0.endedAt != nil }
            .sorted { ($0.endedAt ?? .distantPast) > ($1.endedAt ?? .distantPast) }
            .first?.summary
    }

    public func clearAllLocalData() {
        records.removeAll()
    }
}
