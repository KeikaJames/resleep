import Foundation

/// Privacy defaults are explicitly conservative to match product principles:
/// - audioUploadEnabled = false
/// - saveRawAudio = false
/// - cloudSyncEnabled = false
/// - shareWithHealthKit = false (user must opt in)
@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var saveRawAudio: Bool = false
    @Published var audioUploadEnabled: Bool = false
    @Published var cloudSyncEnabled: Bool = false
    @Published var shareWithHealthKit: Bool = false
}
