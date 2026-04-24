import Foundation

/// Swift-side read model over the local store. The authoritative writer is the
/// Rust engine (sleep-core) writing to the SQLite file; this protocol is the
/// read/query surface SwiftUI uses to render lists and trends. The default
/// implementation is an in-memory stub; a SQLite-backed reader will replace it
/// once the Rust xcframework is wired in.
public protocol LocalStoreProtocol: Sendable {
    func listSessions(limit: Int) async throws -> [SleepSession]
    func summary(for sessionId: String) async throws -> SessionSummary?
    func recordLocalSummary(_ summary: SessionSummary, startedAt: Date) async throws
}

public actor InMemoryLocalStore: LocalStoreProtocol {
    private var sessions: [SleepSession] = []
    private var summaries: [String: SessionSummary] = [:]

    public init() {}

    public func listSessions(limit: Int) -> [SleepSession] {
        Array(sessions.sorted { $0.startedAt > $1.startedAt }.prefix(limit))
    }

    public func summary(for sessionId: String) -> SessionSummary? {
        summaries[sessionId]
    }

    public func recordLocalSummary(_ summary: SessionSummary, startedAt: Date) {
        let endedAt = startedAt.addingTimeInterval(TimeInterval(summary.durationSec))
        sessions.append(SleepSession(id: summary.sessionId, startedAt: startedAt, endedAt: endedAt, stage: .wake))
        summaries[summary.sessionId] = summary
    }
}
