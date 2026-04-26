import Foundation

/// File-backed JSON store for offline-first local product data. Each
/// write rewrites the whole envelope to a temp file and atomically
/// renames it into place — the write surface is small (one record per
/// session) and we trade per-write cost for crash safety.
///
/// Schema is versioned via `schemaVersion` so future migrations stay
/// explicit. A corrupt file does not crash the app: `init` falls back
/// to an empty in-memory state and surfaces `loadError` so the UI can
/// offer a reset.
public actor PersistentLocalStore: LocalStoreProtocol {

    // MARK: Persisted envelope

    public struct StoredEnvelope: Codable, Sendable, Equatable {
        public var schemaVersion: Int
        public var sessions: [StoredSessionRecord]
        public init(schemaVersion: Int = 1, sessions: [StoredSessionRecord] = []) {
            self.schemaVersion = schemaVersion
            self.sessions = sessions
        }
    }

    // MARK: State

    public let fileURL: URL
    private(set) var sessions: [String: StoredSessionRecord] = [:]
    public private(set) var loadError: String?

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: Init

    public init(fileURL: URL) {
        self.fileURL = fileURL
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let env = try decoder.decode(StoredEnvelope.self, from: data)
            for r in env.sessions { sessions[r.id] = r }
        } catch {
            // Corrupt or unreadable. Quarantine the bad file so a fresh
            // write doesn't clobber forensic data, but keep running.
            let quarantine = fileURL.deletingPathExtension()
                .appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? fm.moveItem(at: fileURL, to: quarantine)
            loadError = "Local store unreadable; quarantined to \(quarantine.lastPathComponent)."
            sessions = [:]
        }
    }

    /// Convenience: standard Application Support path for the app.
    public static func defaultURL() -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("SleepTracker", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("local_store.json")
    }

    private func persist() throws {
        let env = StoredEnvelope(schemaVersion: 1,
                                 sessions: Array(sessions.values))
        let data = try encoder.encode(env)
        let tmp = fileURL.deletingPathExtension()
            .appendingPathExtension("tmp-\(UUID().uuidString).json")
        try data.write(to: tmp, options: .atomic)
        let fm = FileManager.default
        if fm.fileExists(atPath: fileURL.path) {
            _ = try? fm.replaceItemAt(fileURL, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: fileURL)
        }
        // Cleanup any leftover temp (replaceItemAt removes it; defensive).
        if fm.fileExists(atPath: tmp.path) { try? fm.removeItem(at: tmp) }
    }

    // MARK: LocalStoreProtocol

    public func listSessions(limit: Int) -> [SleepSession] {
        sessions.values
            .sorted { $0.startedAt > $1.startedAt }
            .prefix(limit)
            .map { $0.toSession() }
    }

    public func summary(for sessionId: String) -> SessionSummary? {
        sessions[sessionId]?.summary
    }

    public func recordLocalSummary(_ summary: SessionSummary, startedAt: Date) throws {
        let endedAt = startedAt.addingTimeInterval(TimeInterval(summary.durationSec))
        let prior = sessions[summary.sessionId]
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
        sessions[summary.sessionId] = merged
        try persist()
    }

    public func record(for sessionId: String) -> StoredSessionRecord? {
        sessions[sessionId]
    }

    public func recordSessionRecord(_ record: StoredSessionRecord) throws {
        sessions[record.id] = record
        try persist()
    }

    public func timeline(for sessionId: String) -> [TimelineEntry] {
        (sessions[sessionId]?.timeline ?? []).sorted { $0.start < $1.start }
    }

    public func recordTimelineEntries(_ entries: [TimelineEntry], for sessionId: String) throws {
        guard var rec = sessions[sessionId] else { return }
        rec.timeline.append(contentsOf: entries)
        rec.timeline.sort { $0.start < $1.start }
        sessions[sessionId] = rec
        try persist()
    }

    public func latestCompletedSummary() -> SessionSummary? {
        sessions.values
            .filter { $0.summary != nil && $0.endedAt != nil }
            .sorted { ($0.endedAt ?? .distantPast) > ($1.endedAt ?? .distantPast) }
            .first?.summary
    }

    public func clearAllLocalData() throws {
        sessions.removeAll()
        let fm = FileManager.default
        if fm.fileExists(atPath: fileURL.path) {
            try fm.removeItem(at: fileURL)
        }
        loadError = nil
    }
}
