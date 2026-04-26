import SwiftUI
import SleepKit

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var vm = SettingsViewModel()
    @State private var showDeleteConfirm: Bool = false
    @State private var deleteError: String?
    @State private var deletedAt: Date?
    @State private var diagSummary: String = "—"
    @State private var clearedDiagAt: Date?

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
                    NavigationLink {
                        DiagnosticsView()
                    } label: {
                        Label("View Diagnostics", systemImage: "doc.text.magnifyingglass")
                    }
                    Button {
                        Task { await refreshDiagSummary() }
                    } label: {
                        Label("Refresh Summary", systemImage: "arrow.clockwise")
                    }
                    Text(diagSummary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(role: .destructive) {
                        Task { await clearDiagnostics() }
                    } label: {
                        Label("Clear Diagnostics", systemImage: "trash")
                    }
                    if let clearedDiagAt {
                        Text("Cleared \(relativeDate(clearedDiagAt))")
                            .font(.footnote).foregroundStyle(.tertiary)
                    }
                } header: {
                    Text("Diagnostics")
                } footer: {
                    Text("Local diagnostic events. Used to inspect what happened during unattended overnight tests.")
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

                Section {
                    Text("Offline-first. Health data stays on this device by default.")
                    Text("No raw audio is uploaded.")
                    Text("Not a medical device. Does not diagnose or treat sleep disorders.")
                } header: {
                    Text("Compliance")
                }

                Section("About") {
                    LabeledContent("App version", value: "0.1.0")
                    LabeledContent("Engine", value: "InMemory (rule-based)")
                }
            }
            .navigationTitle("Settings")
            .task { await refreshDiagSummary() }
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

    private func refreshDiagSummary() async {
        if let report = await appState.generateLatestUnattendedReport() {
            diagSummary = "Latest: \(report.sessionId ?? "—") · "
                + "HR \(report.hrSampleCount) · "
                + "accel \(report.accelWindowCount) · "
                + "alarm \(report.alarmFinalState ?? "—")"
        } else {
            diagSummary = "No diagnostic events yet."
        }
    }

    private func clearDiagnostics() async {
        await appState.diagnostics.clear()
        clearedDiagAt = Date()
        await refreshDiagSummary()
    }
}

// MARK: - Diagnostics view

private struct DiagnosticsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var text: String = "Loading…"

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(.footnote, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .textSelection(.enabled)
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    UIPasteboard.general.string = text
                } label: {
                    Image(systemName: "doc.on.doc")
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        if let report = await appState.generateLatestUnattendedReport() {
            text = UnattendedReportBuilder.renderText(report)
        } else {
            text = "No diagnostic events recorded yet."
        }
    }
}
