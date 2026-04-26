import Foundation
import SleepKit

@MainActor
final class HistoryViewModel: ObservableObject {
    @Published private(set) var sessions: [SleepSession] = []
    @Published private(set) var summaries: [String: SessionSummary] = [:]

    func load(appState: AppState) async {
        do {
            let list = try await appState.localStore.listSessions(limit: 50)
            self.sessions = list
            // Eagerly cache summaries so the row can show duration/score
            // and the detail view doesn't have to re-query on tap.
            var resolved: [String: SessionSummary] = [:]
            for s in list {
                if let summary = try? await appState.localStore.summary(for: s.id) {
                    resolved[s.id] = summary
                }
            }
            self.summaries = resolved
        } catch {
            print("listSessions failed: \(error)")
        }
    }

    func summary(for id: String) -> SessionSummary? { summaries[id] }
}
