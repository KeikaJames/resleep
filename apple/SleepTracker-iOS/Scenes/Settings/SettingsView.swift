import SwiftUI
import SleepKit

struct SettingsView: View {
    @StateObject private var vm = SettingsViewModel()

    var body: some View {
        NavigationStack {
            Form {
                Section("Privacy") {
                    Toggle("Save raw audio", isOn: $vm.saveRawAudio)
                    Toggle("Allow audio upload", isOn: $vm.audioUploadEnabled)
                    Toggle("Share with HealthKit", isOn: $vm.shareWithHealthKit)
                    Toggle("Cloud sync (future)", isOn: $vm.cloudSyncEnabled).disabled(true)
                }
                Section("About") {
                    LabeledContent("App version", value: "0.1.0")
                    LabeledContent("Engine", value: "InMemory (rule-based)")
                }
            }
            .navigationTitle("Settings")
        }
    }
}
