import XCTest
@testable import SleepTracker_iOS

final class SettingsPrivacyTests: XCTestCase {

    @MainActor
    func testCloudSyncIsForcedOffEvenIfLegacyDefaultWasTrue() {
        let suiteName = "settings-privacy-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "settings.cloudSyncEnabled")

        let vm = SettingsViewModel(defaults: defaults)

        XCTAssertFalse(vm.cloudSyncEnabled)
        XCTAssertNil(defaults.object(forKey: "settings.cloudSyncEnabled"))
    }
}
