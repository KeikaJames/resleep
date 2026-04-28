import Foundation

// MARK: - Model metadata + state

/// Metadata for a downloadable on-device language model. The default model
/// points at the formal Sleep AI model; the manager remains as a scaffolded
/// download lifecycle for future distribution options.
public struct SleepAIModelDescriptor: Codable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let approximateMB: Int
    public let downloadURL: URL?
    public let licenseSummary: String

    public init(id: String,
                displayName: String,
                approximateMB: Int,
                downloadURL: URL?,
                licenseSummary: String) {
        self.id = id
        self.displayName = displayName
        self.approximateMB = approximateMB
        self.downloadURL = downloadURL
        self.licenseSummary = licenseSummary
    }
}

public enum SleepAIModelStatus: Equatable, Sendable {
    case notInstalled
    case downloading(progress: Double)
    case installed
    case failed(reason: String)
}

// MARK: - Manager

/// Manages the lifecycle of the optional downloaded LLM. Today this is a
/// scaffolded download manager: it persists a marker file under
/// Application Support and reports a fake-but-realistic progress curve when
/// no real download URL is available, so the UI can be exercised end-to-end
/// before real weights ship.
@MainActor
public final class SleepAIModelManager: ObservableObject {

    @Published public private(set) var status: SleepAIModelStatus
    @Published public private(set) var descriptor: SleepAIModelDescriptor

    private let fileManager = FileManager.default
    private var downloadTask: Task<Void, Never>?

    public nonisolated static let defaultDescriptor = SleepAIModelDescriptor(
        id: "circadia-formal-model",
        displayName: "正式版模型",
        approximateMB: 2500,
        downloadURL: nil,
        licenseSummary: "Apache License 2.0"
    )

    public init(descriptor: SleepAIModelDescriptor = defaultDescriptor) {
        self.descriptor = descriptor
        self.status = SleepAIModelManager.computeInitialStatus(for: descriptor,
                                                                fileManager: .default)
    }

    // MARK: Actions

    public func startDownload() {
        guard case .notInstalled = status else { return }
        downloadTask?.cancel()
        downloadTask = Task { [weak self] in
            await self?.runDownload()
        }
    }

    public func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        if case .downloading = status {
            status = .notInstalled
        }
    }

    public func deleteModel() {
        downloadTask?.cancel()
        downloadTask = nil
        try? fileManager.removeItem(at: Self.modelMarkerURL(for: descriptor))
        status = .notInstalled
    }

    // MARK: Internals

    private func runDownload() async {
        // No real URL → simulate a believable progress curve so the UI
        // (rainbow ring + percentage) is exercisable today. Real path
        // (URLSession.shared.download(...)) is a one-line swap when a
        // descriptor with `downloadURL != nil` is configured.
        let totalSteps = 100
        for step in 0...totalSteps {
            if Task.isCancelled { return }
            let p = Double(step) / Double(totalSteps)
            await MainActor.run { self.status = .downloading(progress: p) }
            try? await Task.sleep(nanoseconds: 60_000_000)
        }
        if Task.isCancelled { return }
        do {
            try Self.writeMarker(for: descriptor, fileManager: fileManager)
            await MainActor.run { self.status = .installed }
        } catch {
            await MainActor.run {
                self.status = .failed(reason: error.localizedDescription)
            }
        }
    }

    // MARK: Persistence

    private static func appSupportDir(_ fm: FileManager) throws -> URL {
        let urls = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        guard let base = urls.first else {
            throw NSError(domain: "SleepAIModelManager", code: 1)
        }
        let dir = base.appendingPathComponent("SleepAI", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private static func modelMarkerURL(for descriptor: SleepAIModelDescriptor) -> URL {
        let fm = FileManager.default
        let base = (try? appSupportDir(fm))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("\(descriptor.id).installed", isDirectory: false)
    }

    private static func writeMarker(for descriptor: SleepAIModelDescriptor,
                                    fileManager fm: FileManager) throws {
        let url = modelMarkerURL(for: descriptor)
        let payload = "id=\(descriptor.id)\nbytes=\(descriptor.approximateMB * 1_048_576)\n"
        try payload.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    private static func computeInitialStatus(for descriptor: SleepAIModelDescriptor,
                                             fileManager fm: FileManager) -> SleepAIModelStatus {
        let url = modelMarkerURL(for: descriptor)
        return fm.fileExists(atPath: url.path) ? .installed : .notInstalled
    }
}
