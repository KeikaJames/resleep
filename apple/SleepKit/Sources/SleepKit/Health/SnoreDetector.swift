import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(Accelerate)
import Accelerate
#endif
#if canImport(CoreML)
import CoreML
#endif

/// Privacy-first acoustic event detector.
///
/// Lives entirely on-device. Microphone tap delivers PCM frames; we compute
/// log-mel spectrograms in 1 s windows and run a tiny CNN classifier. The
/// pipeline emits two signals to its consumer:
///   - `event` — `true` when the latest window scored above threshold
///   - `count` — running count since `start()`
///
/// **Audio bytes are never persisted, never logged, never uploaded.** Each
/// PCM buffer is consumed in-place and dropped. The only thing leaving the
/// audio queue is a Float32 logits pair `[non_snore, snore]`.
@MainActor
public protocol SnoreDetectorProtocol: AnyObject {
    var isAvailable: Bool { get }
    var isRunning: Bool { get }
    var eventCount: Int { get }
    func start() throws
    func stop()
    /// Closure invoked on the main actor when an event is detected.
    /// Argument is the running event count.
    func onEvent(_ handler: @escaping @Sendable (Int) -> Void)
}

public enum SnoreDetectorError: Error, Sendable, Equatable {
    case unavailable
    case microphoneDenied
    case modelMissing
    case engineFailed(String)
}

/// No-op stand-in. Used on platforms without AVFoundation, in previews, and
/// when the user has snore detection disabled.
@MainActor
public final class NoopSnoreDetector: SnoreDetectorProtocol {
    public var isAvailable: Bool { false }
    public var isRunning: Bool { false }
    public var eventCount: Int { 0 }
    public init() {}
    public func start() throws {}
    public func stop() {}
    public func onEvent(_ handler: @escaping @Sendable (Int) -> Void) {}
}

#if canImport(AVFoundation) && canImport(SoundAnalysis) && os(iOS)
import SoundAnalysis

/// Production iOS implementation backed by Apple's built-in
/// `SNClassifySoundRequest` (iOS 15+, classifier `version1`). This classifier
/// is shipped inside the OS — it recognizes ~300 environmental sounds
/// including `snoring` — so we ship no model weights, no `.mlpackage`,
/// no synthetic-data baseline, and we get Apple's quality bar for free.
///
/// **Audio bytes are never persisted, never logged, never uploaded.** Each
/// PCM buffer flows AVAudioEngine → SNAudioStreamAnalyzer in memory and is
/// dropped. The only thing that escapes the audio pipeline is a Float
/// confidence score for the `snoring` class.
@MainActor
public final class SnoreDetector: NSObject, SnoreDetectorProtocol, SNResultsObserving {

    public private(set) var isRunning: Bool = false
    public private(set) var eventCount: Int = 0

    /// Always available on iOS 15+. The class is gated by `os(iOS)` already.
    public var isAvailable: Bool { true }

    private let session = AVAudioSession.sharedInstance()
    private let engine = AVAudioEngine()
    private var analyzer: SNAudioStreamAnalyzer?
    private var request: SNClassifySoundRequest?
    private let analysisQueue = DispatchQueue(label: "snore.analysis")

    /// Minimum confidence (0..1) on the `snoring` class to count one event.
    /// Apple's classifier returns calibrated probabilities; 0.6 is a good
    /// trade-off between recall and false positives in quiet bedrooms.
    private let threshold: Double = 0.6

    /// Hysteresis: count a single "event" per N consecutive positive windows
    /// to avoid double-counting one snore that spans two analysis windows.
    private let cooldownSec: TimeInterval = 1.5
    private var lastEventAt: Date = .distantPast

    private var eventHandler: (@Sendable (Int) -> Void)?

    public override init() {
        super.init()
    }

    public init(bundle _: Bundle = .main) {
        super.init()
    }

    public func onEvent(_ handler: @escaping @Sendable (Int) -> Void) {
        self.eventHandler = handler
    }

    public func start() throws {
        guard !isRunning else { return }

        // Configure the audio session for low-power background recording.
        do {
            try session.setCategory(.playAndRecord,
                                    mode: .measurement,
                                    options: [.mixWithOthers, .duckOthers])
            try session.setActive(true)
        } catch {
            throw SnoreDetectorError.engineFailed(error.localizedDescription)
        }

        let inputNode = engine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)
        guard nativeFormat.sampleRate > 0 else {
            throw SnoreDetectorError.engineFailed("input node has no format")
        }

        // Build the SoundAnalysis request against Apple's bundled classifier.
        let request: SNClassifySoundRequest
        do {
            request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            // Default 0.975 s window with 0.0 overlap = ~1 detection per second.
            request.windowDuration = CMTime(seconds: 0.975, preferredTimescale: 44_100)
            request.overlapFactor = 0.0
        } catch {
            throw SnoreDetectorError.engineFailed("classifier init: \(error.localizedDescription)")
        }

        let analyzer = SNAudioStreamAnalyzer(format: nativeFormat)
        do {
            try analyzer.add(request, withObserver: self)
        } catch {
            throw SnoreDetectorError.engineFailed("analyzer add: \(error.localizedDescription)")
        }

        self.analyzer = analyzer
        self.request = request

        inputNode.installTap(onBus: 0, bufferSize: 8192, format: nativeFormat) { [weak self] buffer, when in
            guard let self else { return }
            self.analysisQueue.async {
                self.analyzer?.analyze(buffer, atAudioFramePosition: when.sampleTime)
            }
        }

        do {
            engine.prepare()
            try engine.start()
            isRunning = true
            eventCount = 0
            lastEventAt = .distantPast
        } catch {
            throw SnoreDetectorError.engineFailed(error.localizedDescription)
        }
    }

    public func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        analyzer?.removeAllRequests()
        analyzer = nil
        request = nil
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        isRunning = false
    }

    // MARK: - SNResultsObserving

    public nonisolated func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let cls = result as? SNClassificationResult else { return }
        // Apple's class identifier for snoring is "snoring".
        guard let snore = cls.classification(forIdentifier: "snoring") else { return }
        let confidence = snore.confidence
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard confidence >= self.threshold else { return }
            let now = Date()
            guard now.timeIntervalSince(self.lastEventAt) >= self.cooldownSec else { return }
            self.lastEventAt = now
            self.eventCount += 1
            self.eventHandler?(self.eventCount)
        }
    }

    public nonisolated func request(_ request: SNRequest, didFailWithError error: Error) {
        // Surface to caller best-effort: stop on hard failure.
        Task { @MainActor [weak self] in self?.stop() }
    }

    public nonisolated func requestDidComplete(_ request: SNRequest) {}
}

#endif
