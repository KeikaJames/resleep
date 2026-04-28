import Foundation
import Combine
import UIKit
import SleepKit

/// Privacy defaults are explicitly conservative to match product principles:
/// - audio is never recorded, saved or uploaded (no toggles exposed)
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
        static let cloudSyncEnabled   = "settings.cloudSyncEnabled"
        static let shareWithHealthKit = "settings.shareWithHealthKit"
        static let snoreDetection     = "settings.enableSnoreDetection"
        static let personalization    = "settings.personalizationEnabled"
        static let bedtimeEnabled     = "settings.bedtimeReminderEnabled"
        static let bedtimeHour        = "settings.bedtimeReminderHour"
        static let bedtimeMinute      = "settings.bedtimeReminderMinute"
        static let profileAvatarData  = "settings.profile.avatarData"
        static let profileNickname    = "settings.profile.nickname"
        static let profileBirthday    = "settings.profile.birthday"
        // Legacy keys retained only so we can wipe stale `true` values.
        static let legacySaveRawAudio       = "settings.saveRawAudio"
        static let legacyAudioUploadEnabled = "settings.audioUploadEnabled"
    }

    private let defaults: UserDefaults
    private let sleepPlanStore: SleepPlanUserDefaultsStore
    private var bag: Set<AnyCancellable> = []

    @Published var cloudSyncEnabled: Bool
    @Published var shareWithHealthKit: Bool
    @Published var snoreDetectionEnabled: Bool
    @Published var personalizationEnabled: Bool
    @Published var bedtimeReminderEnabled: Bool
    @Published var bedtimeReminderTime: Date
    @Published var sleepPlanAutoTrackingEnabled: Bool
    @Published var sleepPlanBedtime: Date
    @Published var sleepPlanWakeTime: Date
    @Published var sleepPlanGoalMinutes: Int
    @Published var sleepPlanSmartWakeWindowMinutes: Int
    @Published var sleepPlanNightmareWakeEnabled: Bool
    @Published var profileAvatarData: Data?
    @Published var profileNickname: String
    @Published var profileBirthday: Date?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.sleepPlanStore = SleepPlanUserDefaultsStore(defaults: defaults)
        // Privacy invariant: raw audio is never persisted and never uploaded.
        // Wipe any stale `true` left over from older builds so the on-disk
        // state matches the published policy and the docs.
        defaults.removeObject(forKey: Key.legacySaveRawAudio)
        defaults.removeObject(forKey: Key.legacyAudioUploadEnabled)
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
        let plan = sleepPlanStore.load()
        self.sleepPlanAutoTrackingEnabled = plan.autoTrackingEnabled
        self.sleepPlanBedtime = Self.timeOnlyDate(hour: plan.bedtimeHour, minute: plan.bedtimeMinute)
        self.sleepPlanWakeTime = Self.timeOnlyDate(hour: plan.wakeHour, minute: plan.wakeMinute)
        self.sleepPlanGoalMinutes = plan.sleepGoalMinutes
        self.sleepPlanSmartWakeWindowMinutes = plan.smartWakeWindowMinutes
        self.sleepPlanNightmareWakeEnabled = plan.nightmareWakeEnabled
        self.profileAvatarData = defaults.data(forKey: Key.profileAvatarData)
        self.profileNickname = defaults.string(forKey: Key.profileNickname) ?? ""
        if let storedBirthday = defaults.object(forKey: Key.profileBirthday) as? TimeInterval {
            self.profileBirthday = Date(timeIntervalSince1970: storedBirthday)
        } else {
            self.profileBirthday = nil
        }

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
        Publishers.CombineLatest4($sleepPlanAutoTrackingEnabled,
                                  $sleepPlanBedtime,
                                  $sleepPlanWakeTime,
                                  $sleepPlanGoalMinutes)
            .dropFirst()
            .sink { [weak self] _, _, _, _ in self?.persistSleepPlan() }
            .store(in: &bag)
        Publishers.CombineLatest($sleepPlanSmartWakeWindowMinutes,
                                 $sleepPlanNightmareWakeEnabled)
            .dropFirst()
            .sink { [weak self] _, _ in self?.persistSleepPlan() }
            .store(in: &bag)
        $profileAvatarData.dropFirst()
            .sink { [defaults] data in
                if let data {
                    defaults.set(data, forKey: Key.profileAvatarData)
                } else {
                    defaults.removeObject(forKey: Key.profileAvatarData)
                }
            }
            .store(in: &bag)
        $profileNickname.dropFirst()
            .sink { [defaults] nickname in
                let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    defaults.removeObject(forKey: Key.profileNickname)
                } else {
                    defaults.set(nickname, forKey: Key.profileNickname)
                }
            }
            .store(in: &bag)
        $profileBirthday.dropFirst()
            .sink { [defaults] birthday in
                if let birthday {
                    defaults.set(birthday.timeIntervalSince1970, forKey: Key.profileBirthday)
                } else {
                    defaults.removeObject(forKey: Key.profileBirthday)
                }
            }
            .store(in: &bag)
    }

    func updateProfileAvatar(with imageData: Data) {
        guard let image = UIImage(data: imageData) else { return }
        let maxSide: CGFloat = 320
        let size = image.size
        guard size.width > 0, size.height > 0 else { return }
        let scale = min(maxSide / size.width, maxSide / size.height, 1)
        let targetSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let rendered = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        profileAvatarData = rendered.jpegData(compressionQuality: 0.82)
    }

    func clearProfileAvatar() {
        profileAvatarData = nil
    }

    var currentSleepPlan: SleepPlanConfiguration {
        makeSleepPlan()
    }

    func persistCurrentSleepPlan() {
        persistSleepPlan()
    }

    private func persistSleepPlan() {
        sleepPlanStore.save(makeSleepPlan())
    }

    private func makeSleepPlan() -> SleepPlanConfiguration {
        let bed = Calendar.current.dateComponents([.hour, .minute], from: sleepPlanBedtime)
        let wake = Calendar.current.dateComponents([.hour, .minute], from: sleepPlanWakeTime)
        return SleepPlanConfiguration(
            autoTrackingEnabled: sleepPlanAutoTrackingEnabled,
            bedtimeHour: bed.hour ?? 23,
            bedtimeMinute: bed.minute ?? 0,
            wakeHour: wake.hour ?? 7,
            wakeMinute: wake.minute ?? 0,
            sleepGoalMinutes: sleepPlanGoalMinutes,
            smartWakeWindowMinutes: sleepPlanSmartWakeWindowMinutes,
            nightmareWakeEnabled: sleepPlanNightmareWakeEnabled
        )
    }

    private static func timeOnlyDate(hour: Int, minute: Int) -> Date {
        var comps = DateComponents()
        comps.hour = hour
        comps.minute = minute
        return Calendar.current.date(from: comps) ?? Date()
    }
}
