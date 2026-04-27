import Foundation
import SleepKit

/// iOS-side composition of engine + heart-rate source + connectivity. The
/// only place with knowledge of paths on disk and of which backend is picked.
enum EngineHost {

    @MainActor
    static func makeEngine() -> (SleepEngineClientProtocol, String?) {
        let dbPath = defaultDBPath()
        return SleepEngineFactory.makeDefault(
            dbPath: dbPath,
            modelPath: "",
            userId: resolveUserID()
        )
    }

    @MainActor
    static func makeHeartRateStream() -> HeartRateStreaming {
        #if canImport(HealthKit) && os(iOS)
        return HealthKitHeartRateStream()
        #else
        return MockHeartRateStream()
        #endif
    }

    @MainActor
    static func makeConnectivity() -> ConnectivityManagerProtocol {
        #if canImport(WatchConnectivity) && os(iOS)
        return ConnectivityManager.makeProductionDefault()
        #else
        return InMemoryConnectivityManager()
        #endif
    }

    @MainActor
    static func makeLocalStore() -> LocalStoreProtocol {
        return PersistentLocalStore(fileURL: PersistentLocalStore.defaultURL())
    }

    @MainActor
    static func makeDiagnosticsStore() -> DiagnosticsStoreProtocol {
        return DiagnosticsStore(fileURL: DiagnosticsStore.defaultURL())
    }

    @MainActor
    static func makeActiveSessionMarkerStore() -> ActiveSessionMarkerStoreProtocol {
        return ActiveSessionMarkerStore(fileURL: ActiveSessionMarkerStore.defaultURL())
    }

    @MainActor
    static func makeHealthKitSleepWriter() -> HealthKitSleepWriting {
        #if canImport(HealthKit) && os(iOS)
        return HealthKitSleepWriter()
        #else
        return NoopHealthKitSleepWriter()
        #endif
    }

    @MainActor
    static func makeSnoreDetector() -> SnoreDetectorProtocol {
        #if canImport(AVFoundation) && canImport(CoreML) && canImport(Accelerate) && os(iOS)
        return SleepKit.SnoreDetector()
        #else
        return NoopSnoreDetector()
        #endif
    }

    static func makePersonalizationService() -> PersonalizationService {
        let store = PersistentPersonalizationStore(
            fileURL: PersistentPersonalizationStore.defaultURL()
        )
        return PersonalizationService(store: store)
    }

    private static func defaultDBPath() -> String {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("sleep.db").path
    }

    private static func resolveUserID() -> String {
        let key = "sleepkit.localUserID"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }
}
