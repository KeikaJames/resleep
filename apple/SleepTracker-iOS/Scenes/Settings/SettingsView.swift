import SwiftUI
import SleepKit

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var vm = SettingsViewModel()

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
        }
    }

    private func relativeDate(_ d: Date?) -> String {
        guard let d else { return "—" }
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .abbreviated
        return fmt.localizedString(for: d, relativeTo: Date())
    }
}
