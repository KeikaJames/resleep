import Foundation
import SleepKit

@MainActor
final class HistoryViewModel: ObservableObject {
    @Published var sessions: [SleepSession] = []

    func load(appState: AppState) async {
        do {
            sessions = try await appState.localStore.listSessions(limit: 50)
        } catch {
            print("listSessions failed: \(error)")
        }
    }
}
