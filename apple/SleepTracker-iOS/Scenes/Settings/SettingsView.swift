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
                    LabeledContent("App version", value: Self.versionString)
                    LabeledContent("Build", value: Self.buildString)
                    LabeledContent("Engine", value: "InMemory (rule-based)")
                    NavigationLink("Privacy Policy") {
                        LegalDocumentView(title: "Privacy Policy", text: LegalCopy.privacy)
                    }
                    NavigationLink("Terms of Use") {
                        LegalDocumentView(title: "Terms of Use", text: LegalCopy.terms)
                    }
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

    private static var versionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private static var buildString: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }
}

// MARK: - Legal document viewer

private struct LegalDocumentView: View {
    let title: String
    let text: String

    var body: some View {
        ScrollView {
            Text(text)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .textSelection(.enabled)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private enum LegalCopy {
    static let privacy = """
    Sleep is offline-first. Everything you record stays on your device by default.

    What stays local
    • Heart rate, motion, and derived sleep stages.
    • Session history and diagnostic logs.
    • Any audio captured for breathing detection.

    What we never do
    • We never upload raw audio. The microphone, when enabled, runs on-device only.
    • We do not include third-party analytics, advertising, or tracking SDKs.
    • We do not run a backend for your data.

    HealthKit
    If you allow it, Sleep can read heart rate and HRV from HealthKit and write a sleep analysis sample back. You can revoke either at any time in the iOS Settings → Health → Data Access & Devices.

    Diagnostics
    A local diagnostic log records events such as session start/stop and Watch reachability so you can review what happened overnight. The log lives in this app's container and can be cleared from Settings → Diagnostics.

    Children
    Sleep is not directed at children under 13.

    Contact
    If you have questions, contact the developer through the App Store listing.
    """

    static let terms = """
    Sleep is provided as-is for personal wellness use.

    Not a medical device
    Sleep does not diagnose, treat, cure, or prevent any disease or condition. The sleep stages, score, and alarm features are estimates based on consumer sensors. Do not rely on Sleep for any medical decision. If you have a sleep disorder or any health concern, consult a qualified clinician.

    Use at your own risk
    Sleep may produce inaccurate results, miss alarms, or stop tracking unexpectedly. Do not rely on the smart alarm if missing it would cause harm.

    Your data
    You are responsible for your device and your data. Sleep stores data locally; if you delete the app or your device, that data is lost.

    Changes
    These terms may change in future versions of Sleep. Continued use after an update means you accept the updated terms.
    """
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
