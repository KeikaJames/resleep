import SwiftUI
import SleepKit

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var vm = SettingsViewModel()
    @State private var showDeleteConfirm: Bool = false
    @State private var deleteError: String?
    @State private var deletedAt: Date?

    var body: some View {
        NavigationStack {
            Form {
                Section("Permissions") {
                    Toggle("Share with HealthKit", isOn: $vm.shareWithHealthKit)
                }

                Section("Privacy") {
                    Toggle("Save raw audio", isOn: $vm.saveRawAudio)
                    Toggle("Allow audio upload", isOn: $vm.audioUploadEnabled)
                    Toggle("Cloud sync (future)", isOn: $vm.cloudSyncEnabled).disabled(true)
                }

                Section("Apple Watch") {
                    LabeledContent("Reachable",
                                   value: appState.router.watchReachable ? "Yes" : "No")
                    LabeledContent("Last sync",
                                   value: relativeDate(appState.router.lastBatchAt))
                }

                Section("Model") {
                    LabeledContent("Backend",
                                   value: appState.inferencePipeline.descriptor.isRealModel
                                            ? "Core ML" : "Heuristic fallback")
                    LabeledContent("Name", value: appState.inferencePipeline.descriptor.name)
                    if let v = appState.inferencePipeline.descriptor.version {
                        LabeledContent("Version", value: v)
                    }
                    if let reason = appState.inferenceFallbackReason {
                        Text(reason).font(.footnote).foregroundStyle(.orange)
                    }
                }

                Section {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("Delete Local Sleep Data", systemImage: "trash")
                    }
                    if let deletedAt {
                        Text("Cleared \(relativeDate(deletedAt))")
                            .font(.footnote).foregroundStyle(.tertiary)
                    }
                    if let err = deleteError {
                        Text(err).font(.footnote).foregroundStyle(.red)
                    }
                } header: {
                    Text("Local Data")
                } footer: {
                    Text("Removes all sessions, summaries, and timeline entries stored on this device. This cannot be undone.")
                }

                Section("Developer") {
                    LabeledContent("Runtime",
                                   value: appState.runtimeMode == .simulated ? "Simulated" : "Live")
                    Text("Simulation controls live in the Developer section on Home.")
                        .font(.footnote).foregroundStyle(.tertiary)
                }

                Section("About") {
                    LabeledContent("App version", value: "0.1.0")
                    LabeledContent("Engine", value: "InMemory (rule-based)")
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog(
                "Delete all local sleep data?",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    Task { await deleteAllLocalData() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Sessions, summaries, and timelines stored on this device will be removed.")
            }
        }
    }

    private func relativeDate(_ d: Date?) -> String {
        guard let d else { return "—" }
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .abbreviated
        return fmt.localizedString(for: d, relativeTo: Date())
    }

    private func deleteAllLocalData() async {
        do {
            try await appState.localStore.clearAllLocalData()
            appState.latestSummary = nil
            deletedAt = Date()
            deleteError = nil
        } catch {
            deleteError = "Delete failed: \(error)"
        }
    }
}
