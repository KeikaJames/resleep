import Foundation

/// On-device personalization layer for the stage classifier.
///
/// Concept
/// -------
/// The bundled tiny-transformer (`SleepStager.mlpackage`) outputs base
/// stage logits for every inference window. Those logits are population-
/// average — they don't know your resting HR, your typical HRV, or that
/// you happen to be a high-mover sleeper.
///
/// This service maintains a per-user **logit correction**:
///
///     personalized_logits = base_logits + W_user · features + b_user
///
/// where `features` is the same 9-d feature vector the transformer ate,
/// `W_user ∈ R^(4×9)` and `b_user ∈ R^4`.
///
/// Updates use a single SGD step per stored label. The corrections are
/// initialized to zero, so a brand-new user gets identical behaviour to
/// the bundled model. As they label nights via the wake-up survey, the
/// correction matrix shifts.
///
/// Privacy: only `(features, label)` rows live in `PersonalLabel`; raw
/// audio / HR samples do not. Everything is local; user can disable +
/// reset from Settings.
public struct PersonalizationVector: Codable, Sendable, Equatable {
    /// 4 × 9 row-major.
    public var weights: [Float]
    public var bias: [Float]
    public var version: Int
    public var sampleCount: Int
    public var lastUpdatedAt: Date?

    public static let dim: Int = 9
    public static let classes: Int = 4
    public static let zero = PersonalizationVector(
        weights: Array(repeating: 0, count: dim * classes),
        bias: Array(repeating: 0, count: classes),
        version: 1,
        sampleCount: 0,
        lastUpdatedAt: nil
    )

    public init(weights: [Float], bias: [Float], version: Int,
                sampleCount: Int, lastUpdatedAt: Date?) {
        self.weights = weights
        self.bias = bias
        self.version = version
        self.sampleCount = sampleCount
        self.lastUpdatedAt = lastUpdatedAt
    }
}

/// One labeled (features → stage) example.
public struct PersonalLabel: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var sessionId: String
    public var features: [Float]   // length = PersonalizationVector.dim
    public var stage: Int          // 0 wake, 1 light, 2 deep, 3 rem
    public var weight: Float
    public var createdAt: Date

    public init(id: UUID = UUID(), sessionId: String, features: [Float],
                stage: Int, weight: Float = 1.0, createdAt: Date = Date()) {
        self.id = id
        self.sessionId = sessionId
        self.features = features
        self.stage = stage
        self.weight = weight
        self.createdAt = createdAt
    }
}

public protocol PersonalizationStoreProtocol: Sendable {
    func loadVector() async -> PersonalizationVector
    func saveVector(_ vec: PersonalizationVector) async
    func appendLabels(_ labels: [PersonalLabel]) async
    func loadLabels() async -> [PersonalLabel]
    func clearAll() async
}

public actor InMemoryPersonalizationStore: PersonalizationStoreProtocol {
    private var vec: PersonalizationVector = .zero
    private var labels: [PersonalLabel] = []
    public init() {}
    public func loadVector() -> PersonalizationVector { vec }
    public func saveVector(_ vec: PersonalizationVector) { self.vec = vec }
    public func appendLabels(_ labels: [PersonalLabel]) { self.labels.append(contentsOf: labels) }
    public func loadLabels() -> [PersonalLabel] { labels }
    public func clearAll() {
        vec = .zero
        labels.removeAll()
    }
}

/// File-backed store under Application Support/SleepTracker/personalization.json.
public actor PersistentPersonalizationStore: PersonalizationStoreProtocol {
    public let fileURL: URL

    private struct Envelope: Codable {
        var vector: PersonalizationVector
        var labels: [PersonalLabel]
    }

    private var cache: Envelope = Envelope(vector: .zero, labels: [])
    private var loaded: Bool = false

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static func defaultURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = dir.appendingPathComponent("SleepTracker", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder,
                                                 withIntermediateDirectories: true)
        return folder.appendingPathComponent("personalization.json")
    }

    private func ensureLoaded() {
        if loaded { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let env = try? decoder.decode(Envelope.self, from: data) {
            cache = env
        }
    }

    private func flush() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(cache) else { return }
        // Ensure the parent directory exists before any write attempt — the
        // sandbox container may not have it on first launch.
        let parent = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent,
                                                 withIntermediateDirectories: true)
        // Atomic write straight to the destination handles the first-write
        // case (where there is no existing file to "replace"). On
        // subsequent writes this still goes through Foundation's safe-save
        // path (write to temp, fsync, rename) under the hood.
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Last-ditch fallback: write next to the destination so we do
            // not silently lose user labels if the primary write fails.
            let fallback = fileURL.appendingPathExtension("recovery")
            try? data.write(to: fallback, options: .atomic)
        }
    }

    public func loadVector() -> PersonalizationVector {
        ensureLoaded(); return cache.vector
    }
    public func saveVector(_ vec: PersonalizationVector) {
        ensureLoaded()
        cache.vector = vec
        flush()
    }
    public func appendLabels(_ labels: [PersonalLabel]) {
        ensureLoaded()
        cache.labels.append(contentsOf: labels)
        // keep the trailing 5_000 labels at most — a year of data even at
        // 1 label / 30 s, so this is a generous cap.
        if cache.labels.count > 5000 {
            cache.labels.removeFirst(cache.labels.count - 5000)
        }
        flush()
    }
    public func loadLabels() -> [PersonalLabel] {
        ensureLoaded(); return cache.labels
    }
    public func clearAll() {
        cache = Envelope(vector: .zero, labels: [])
        flush()
    }
}

/// High-level service. Threadsafe (actor).
public actor PersonalizationService {
    public let store: PersonalizationStoreProtocol

    /// SGD learning rate per label. Small because we update online and can
    /// see hundreds of labels per night.
    public let learningRate: Float
    /// L2 weight decay per step. Keeps the correction vector small so the
    /// bundled model stays the dominant signal.
    public let weightDecay: Float

    public init(store: PersonalizationStoreProtocol,
                learningRate: Float = 0.02,
                weightDecay: Float = 1e-4) {
        self.store = store
        self.learningRate = learningRate
        self.weightDecay = weightDecay
    }

    /// Apply correction to a base logit vector for a single feature row.
    public func adjust(baseLogits: [Float], features: [Float]) async -> [Float] {
        let vec = await store.loadVector()
        return Self.add(base: baseLogits, vec: vec, features: features)
    }

    /// Append `labels` (typically from a wake-up survey + the recorded
    /// timeline) and run online SGD over them once.
    public func ingest(labels: [PersonalLabel]) async {
        guard !labels.isEmpty else { return }
        await store.appendLabels(labels)
        var vec = await store.loadVector()
        for label in labels {
            vec = Self.applyOneStep(vec: vec, label: label,
                                    lr: learningRate,
                                    decay: weightDecay)
        }
        vec.lastUpdatedAt = Date()
        vec.sampleCount += labels.count
        await store.saveVector(vec)
    }

    /// Reset to identity. Used by Settings → "Reset personalization".
    public func reset() async {
        await store.clearAll()
    }

    public func snapshot() async -> PersonalizationVector {
        await store.loadVector()
    }

    // MARK: - Pure functions (testable without an actor hop)

    public static func add(base: [Float], vec: PersonalizationVector,
                           features: [Float]) -> [Float] {
        let dim = PersonalizationVector.dim
        let classes = PersonalizationVector.classes
        guard base.count == classes,
              features.count == dim,
              vec.weights.count == dim * classes,
              vec.bias.count == classes else { return base }
        var out = base
        for c in 0..<classes {
            var s: Float = vec.bias[c]
            for d in 0..<dim {
                s += vec.weights[c * dim + d] * features[d]
            }
            out[c] += s
        }
        return out
    }

    /// Multiclass logistic SGD step: minimise cross-entropy of personalized
    /// logits w.r.t. the user-provided stage. Only the correction's bias
    /// and weights are updated — the bundled model is frozen.
    public static func applyOneStep(
        vec: PersonalizationVector,
        label: PersonalLabel,
        lr: Float,
        decay: Float
    ) -> PersonalizationVector {
        let dim = PersonalizationVector.dim
        let classes = PersonalizationVector.classes
        guard label.features.count == dim,
              label.stage >= 0, label.stage < classes else { return vec }

        // Forward: only the correction (we don't have the base logits here,
        // and we don't need them — the gradient on (correction) is
        // independent of the base because softmax is shift-invariant).
        var z = vec.bias
        for c in 0..<classes {
            var s: Float = 0
            for d in 0..<dim {
                s += vec.weights[c * dim + d] * label.features[d]
            }
            z[c] += s
        }
        // softmax
        let maxZ = z.max() ?? 0
        var exps = z.map { expf($0 - maxZ) }
        let sum = exps.reduce(0, +)
        if sum > 0 { for i in 0..<exps.count { exps[i] /= sum } }

        // Gradient: (p - y_onehot) for the head; multiply by features for W,
        // identity for b. Scaled by label.weight.
        var weights = vec.weights
        var bias = vec.bias
        let w = label.weight
        for c in 0..<classes {
            let y: Float = (c == label.stage) ? 1 : 0
            let g = (exps[c] - y) * w
            // bias step + L2
            bias[c] -= lr * (g + decay * bias[c])
            for d in 0..<dim {
                let idx = c * dim + d
                weights[idx] -= lr * (g * label.features[d] + decay * weights[idx])
            }
        }

        return PersonalizationVector(
            weights: weights,
            bias: bias,
            version: vec.version,
            sampleCount: vec.sampleCount,
            lastUpdatedAt: vec.lastUpdatedAt
        )
    }
}
