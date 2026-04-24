import SwiftUI
import SleepKit

struct HistoryView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var vm = HistoryViewModel()

    var body: some View {
        NavigationStack {
            Group {
                if vm.sessions.isEmpty {
                    ContentUnavailableView("No sessions yet",
                                           systemImage: "moon.zzz",
                                           description: Text("Start a night of tracking to see it here."))
                } else {
                    List(vm.sessions) { session in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(session.startedAt, style: .date).font(.headline)
                            if let end = session.endedAt {
                                Text("\(session.startedAt, style: .time) – \(end, style: .time)")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            } else {
                                Text("In progress").font(.subheadline).foregroundStyle(.green)
                            }
                        }
                    }
                }
            }
            .navigationTitle("History")
            .task { await vm.load(appState: appState) }
            .refreshable { await vm.load(appState: appState) }
        }
    }
}
