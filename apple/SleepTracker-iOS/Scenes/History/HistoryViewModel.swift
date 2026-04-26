import Foundation
import SleepKit

@MainActor
final class HistoryViewModel: ObservableObject {
    @Published private(set) var sessions: [SleepSession] = []
    @Published private(set) var summaries: [String: SessionSummary] = [:]
    @Published private(set) var records: [String: StoredSessionRecord] = [:]

    func load(appState: AppState) async {
        do {
            let list = try await appState.localStore.listSessions(limit: 50)
            self.sessions = list
            var resolvedSummaries: [String: SessionSummary] = [:]
            var resolvedRecords: [String: StoredSessionRecord] = [:]
            for s in list {
                if let rec = try? await appState.localStore.record(for: s.id) {
                    resolvedRecords[s.id] = rec
                    if let sum = rec.summary { resolvedSummaries[s.id] = sum }
                } else if let summary = try? await appState.localStore.summary(for: s.id) {
                    resolvedSummaries[s.id] = summary
                }
            }
            self.summaries = resolvedSummaries
            self.records = resolvedRecords
        } catch {
            print("listSessions failed: \(error)")
        }
    }

    func summary(for id: String) -> SessionSummary? { summaries[id] }
    func record(for id: String) -> StoredSessionRecord? { records[id] }
}
