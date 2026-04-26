import Foundation

/// Persistable shape of a marker written when a session starts and cleared
/// when it ends cleanly. Used by `AppState` on launch to detect sessions
/// that were interrupted (app force-killed / device rebooted overnight).
public struct ActiveSessionMarker: Codable, Sendable, Equatable {
    public var sessionId: String
    public var startedAt: Date
    public var sourceRaw: String
    public var runtimeModeRaw: String
    public var smartAlarmEnabled: Bool
    public var alarmTargetTsMs: Int64?
    public var alarmWindowMinutes: Int?
    public var schemaVersion: Int

    public init(
        sessionId: String,
        startedAt: Date,
        sourceRaw: String,
        runtimeModeRaw: String,
        smartAlarmEnabled: Bool,
        alarmTargetTsMs: Int64? = nil,
        alarmWindowMinutes: Int? = nil,
        schemaVersion: Int = 1
    ) {
        self.sessionId = sessionId
        self.startedAt = startedAt
        self.sourceRaw = sourceRaw
        self.runtimeModeRaw = runtimeModeRaw
        self.smartAlarmEnabled = smartAlarmEnabled
        self.alarmTargetTsMs = alarmTargetTsMs
        self.alarmWindowMinutes = alarmWindowMinutes
        self.schemaVersion = schemaVersion
    }
}

public protocol ActiveSessionMarkerStoreProtocol: Sendable {
    func write(_ marker: ActiveSessionMarker) async
    func read() async -> ActiveSessionMarker?
    func clear() async
}

/// File-backed marker. Atomic write (temp + replace) so a power-loss does
/// not leave a half-written marker. A corrupt file is treated as "no
/// marker" (and quarantined) rather than crashing the launch path.
public actor ActiveSessionMarkerStore: ActiveSessionMarkerStoreProtocol {

    public let fileURL: URL

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public init(fileURL: URL) {
        self.fileURL = fileURL
        let parent = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    }

    public static func defaultURL() -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("SleepTracker", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("active_session.json")
    }

    public func write(_ marker: ActiveSessionMarker) {
        guard let data = try? encoder.encode(marker) else { return }
        let tmp = fileURL.deletingPathExtension()
            .appendingPathExtension("tmp-\(UUID().uuidString).json")
        do {
            try data.write(to: tmp, options: .atomic)
            let fm = FileManager.default
            if fm.fileExists(atPath: fileURL.path) {
                _ = try? fm.replaceItemAt(fileURL, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: fileURL)
            }
            if FileManager.default.fileExists(atPath: tmp.path) {
                try? FileManager.default.removeItem(at: tmp)
            }
        } catch {
            // Best effort — marker is advisory data.
        }
    }

    public func read() -> ActiveSessionMarker? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL) else { return nil }
        do {
            return try decoder.decode(ActiveSessionMarker.self, from: data)
        } catch {
            // Quarantine corrupt marker so we don't churn on it forever.
            let q = fileURL.deletingPathExtension()
                .appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? fm.moveItem(at: fileURL, to: q)
            return nil
        }
    }

    public func clear() {
        let fm = FileManager.default
        if fm.fileExists(atPath: fileURL.path) {
            try? fm.removeItem(at: fileURL)
        }
    }
}

/// In-memory backend for tests / previews.
public actor InMemoryActiveSessionMarkerStore: ActiveSessionMarkerStoreProtocol {
    private var current: ActiveSessionMarker?
    public init() {}
    public func write(_ marker: ActiveSessionMarker) { current = marker }
    public func read() -> ActiveSessionMarker? { current }
    public func clear() { current = nil }
}
