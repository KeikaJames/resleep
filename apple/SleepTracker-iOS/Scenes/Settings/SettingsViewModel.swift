import Foundation
import Combine

/// Privacy defaults are explicitly conservative to match product principles:
/// - audioUploadEnabled = false
/// - saveRawAudio = false
/// - cloudSyncEnabled = false
/// - shareWithHealthKit = false (user must opt in)
///
/// Values are persisted to `UserDefaults` so user choices survive across
/// launches. Uses keyed `@Published` properties wired to UserDefaults via
/// a small adapter rather than `@AppStorage` so the model is testable and
/// view-agnostic.
@MainActor
final class SettingsViewModel: ObservableObject {
    private enum Key {
        static let saveRawAudio       = "settings.saveRawAudio"
        static let audioUploadEnabled = "settings.audioUploadEnabled"
        static let cloudSyncEnabled   = "settings.cloudSyncEnabled"
        static let shareWithHealthKit = "settings.shareWithHealthKit"
    }

    private let defaults: UserDefaults
    private var bag: Set<AnyCancellable> = []

    @Published var saveRawAudio: Bool
    @Published var audioUploadEnabled: Bool
    @Published var cloudSyncEnabled: Bool
    @Published var shareWithHealthKit: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.saveRawAudio       = defaults.bool(forKey: Key.saveRawAudio)
        self.audioUploadEnabled = defaults.bool(forKey: Key.audioUploadEnabled)
        self.cloudSyncEnabled   = defaults.bool(forKey: Key.cloudSyncEnabled)
        self.shareWithHealthKit = defaults.bool(forKey: Key.shareWithHealthKit)

        $saveRawAudio.dropFirst()
            .sink { [defaults] in defaults.set($0, forKey: Key.saveRawAudio) }
            .store(in: &bag)
        $audioUploadEnabled.dropFirst()
            .sink { [defaults] in defaults.set($0, forKey: Key.audioUploadEnabled) }
            .store(in: &bag)
        $cloudSyncEnabled.dropFirst()
            .sink { [defaults] in defaults.set($0, forKey: Key.cloudSyncEnabled) }
            .store(in: &bag)
        $shareWithHealthKit.dropFirst()
            .sink { [defaults] in defaults.set($0, forKey: Key.shareWithHealthKit) }
            .store(in: &bag)
    }
}
