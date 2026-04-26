import Foundation

/// Lightweight protocol for the diagnostic event log. All methods are
/// async / actor-isolated so the implementation can serialize disk writes
/// without exposing locking to callers.
public protocol DiagnosticsStoreProtocol: Sendable {
    func append(_ event: DiagnosticEvent) async
    func recent(limit: Int) async -> [DiagnosticEvent]
    func all() async -> [DiagnosticEvent]
    func clear() async
    func storedFileURL() async -> URL?
}

/// File-backed JSONL diagnostic log. One event per line so a corrupt /
/// truncated tail line does not invalidate the whole file. Writes are
/// append-only with a bounded total size; on overflow we rotate the
/// current file to `*.1` (overwriting any prior `*.1`) and start a fresh
/// file. Reads scan the rotated file first then the current one so the
/// returned timeline is chronological.
///
/// Policy:
/// - max bytes per file: ~2 MB (configurable)
/// - retains exactly one rotation (`.1`)
/// - corrupt lines are skipped, not fatal
/// - `clear()` removes both files
public actor DiagnosticsStore: DiagnosticsStoreProtocol {

    public let fileURL: URL
    public let maxBytesPerFile: Int

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public init(fileURL: URL, maxBytesPerFile: Int = 2 * 1024 * 1024) {
        self.fileURL = fileURL
        self.maxBytesPerFile = maxBytesPerFile
        let parent = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    }

    /// Standard Application Support path for the live app.
    public static func defaultURL() -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("SleepTracker", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("diagnostics.jsonl")
    }

    private var rotatedURL: URL {
        fileURL.appendingPathExtension("1")
    }

    // MARK: Append

    public func append(_ event: DiagnosticEvent) {
        guard let line = encodeLine(event) else { return }
        rotateIfNeeded(incomingBytes: line.count)
        appendLine(line)
    }

    private func encodeLine(_ event: DiagnosticEvent) -> Data? {
        guard var data = try? encoder.encode(event) else { return nil }
        data.append(0x0A) // '\n'
        return data
    }

    private func appendLine(_ line: Data) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: fileURL.path) {
            try? line.write(to: fileURL, options: .atomic)
            return
        }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } catch {
                // Disk full / permission issue — best effort.
            }
        } else {
            // Fallback: read+write.
            let existing = (try? Data(contentsOf: fileURL)) ?? Data()
            var combined = existing
            combined.append(line)
            try? combined.write(to: fileURL, options: .atomic)
        }
    }

    private func rotateIfNeeded(incomingBytes: Int) {
        let fm = FileManager.default
        let attrs = try? fm.attributesOfItem(atPath: fileURL.path)
        let size = (attrs?[.size] as? Int) ?? 0
        guard size + incomingBytes > maxBytesPerFile, size > 0 else { return }
        if fm.fileExists(atPath: rotatedURL.path) {
            try? fm.removeItem(at: rotatedURL)
        }
        try? fm.moveItem(at: fileURL, to: rotatedURL)
    }

    // MARK: Read

    public func recent(limit: Int) -> [DiagnosticEvent] {
        let events = readAllOrdered()
        if limit >= events.count { return events }
        return Array(events.suffix(limit))
    }

    public func all() -> [DiagnosticEvent] {
        readAllOrdered()
    }

    private func readAllOrdered() -> [DiagnosticEvent] {
        var events: [DiagnosticEvent] = []
        events.append(contentsOf: readLines(from: rotatedURL))
        events.append(contentsOf: readLines(from: fileURL))
        events.sort { $0.ts < $1.ts }
        return events
    }

    private func readLines(from url: URL) -> [DiagnosticEvent] {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return [] }
        var out: [DiagnosticEvent] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8) else { continue }
            if let ev = try? decoder.decode(DiagnosticEvent.self, from: lineData) {
                out.append(ev)
            }
            // else: corrupt line — skip silently. Not fatal.
        }
        return out
    }

    // MARK: Clear

    public func clear() {
        let fm = FileManager.default
        if fm.fileExists(atPath: fileURL.path) {
            try? fm.removeItem(at: fileURL)
        }
        if fm.fileExists(atPath: rotatedURL.path) {
            try? fm.removeItem(at: rotatedURL)
        }
    }

    public func storedFileURL() async -> URL? { fileURL }
}

/// In-memory backend for tests / previews.
public actor InMemoryDiagnosticsStore: DiagnosticsStoreProtocol {
    private var events: [DiagnosticEvent] = []

    public init() {}

    public func append(_ event: DiagnosticEvent) { events.append(event) }
    public func recent(limit: Int) -> [DiagnosticEvent] {
        if limit >= events.count { return events }
        return Array(events.suffix(limit))
    }
    public func all() -> [DiagnosticEvent] { events }
    public func clear() { events.removeAll() }
    public func storedFileURL() async -> URL? { nil }
}
