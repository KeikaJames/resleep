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
        static let snoreDetection     = "settings.enableSnoreDetection"
        static let personalization    = "settings.personalizationEnabled"
        static let bedtimeEnabled     = "settings.bedtimeReminderEnabled"
        static let bedtimeHour        = "settings.bedtimeReminderHour"
        static let bedtimeMinute      = "settings.bedtimeReminderMinute"
    }

    private let defaults: UserDefaults
    private var bag: Set<AnyCancellable> = []

    @Published var saveRawAudio: Bool
    @Published var audioUploadEnabled: Bool
    @Published var cloudSyncEnabled: Bool
    @Published var shareWithHealthKit: Bool
    @Published var snoreDetectionEnabled: Bool
    @Published var personalizationEnabled: Bool
    @Published var bedtimeReminderEnabled: Bool
    @Published var bedtimeReminderTime: Date

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.saveRawAudio       = defaults.bool(forKey: Key.saveRawAudio)
        self.audioUploadEnabled = defaults.bool(forKey: Key.audioUploadEnabled)
        self.cloudSyncEnabled   = defaults.bool(forKey: Key.cloudSyncEnabled)
        self.shareWithHealthKit = defaults.bool(forKey: Key.shareWithHealthKit)
        self.snoreDetectionEnabled = defaults.bool(forKey: Key.snoreDetection)
        // personalization defaults to ON (key absent -> true)
        if defaults.object(forKey: Key.personalization) == nil {
            self.personalizationEnabled = true
        } else {
            self.personalizationEnabled = defaults.bool(forKey: Key.personalization)
        }
        self.bedtimeReminderEnabled = defaults.bool(forKey: Key.bedtimeEnabled)
        let hour = defaults.object(forKey: Key.bedtimeHour) as? Int ?? 22
        let minute = defaults.object(forKey: Key.bedtimeMinute) as? Int ?? 30
        var comps = DateComponents()
        comps.hour = hour
        comps.minute = minute
        self.bedtimeReminderTime = Calendar.current.date(from: comps) ?? Date()

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
        $snoreDetectionEnabled.dropFirst()
            .sink { [defaults] in defaults.set($0, forKey: Key.snoreDetection) }
            .store(in: &bag)
        $personalizationEnabled.dropFirst()
            .sink { [defaults] in defaults.set($0, forKey: Key.personalization) }
            .store(in: &bag)
        $bedtimeReminderEnabled.dropFirst()
            .sink { [defaults] in defaults.set($0, forKey: Key.bedtimeEnabled) }
            .store(in: &bag)
        $bedtimeReminderTime.dropFirst()
            .sink { [defaults] d in
                let comps = Calendar.current.dateComponents([.hour, .minute], from: d)
                defaults.set(comps.hour ?? 22, forKey: Key.bedtimeHour)
                defaults.set(comps.minute ?? 30, forKey: Key.bedtimeMinute)
            }
            .store(in: &bag)
    }
}
