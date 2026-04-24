import Foundation

/// Picks between the Rust-backed and in-memory engine implementations.
///
/// The factory is intentionally `@MainActor`: the Rust client must be
/// constructed and used from a single isolation domain, and the in-memory
/// client is cheap enough to also run there.
@MainActor
public enum SleepEngineFactory {

    /// Returns a Rust-backed client if it can be initialized with the given
    /// config, otherwise an in-memory client. The `reason` parameter is
    /// populated only when we fall back, useful for surfacing a debug banner.
    public static func makeDefault(
        dbPath: String,
        modelPath: String = "",
        userId: String = "local-user"
    ) -> (engine: SleepEngineClientProtocol, fallbackReason: String?) {
        #if SLEEPKIT_USE_RUST
        do {
            let rust = try RustSleepEngineClient(
                dbPath: dbPath,
                modelPath: modelPath,
                userId: userId
            )
            return (rust, nil)
        } catch {
            return (InMemorySleepEngineClient(), "Rust engine unavailable: \(error)")
        }
        #else
        return (InMemorySleepEngineClient(), "Built without SLEEPKIT_USE_RUST; using in-memory engine.")
        #endif
    }

    /// Preview / test helper — always the in-memory implementation.
    public static func makeInMemory() -> SleepEngineClientProtocol {
        InMemorySleepEngineClient()
    }

    // MARK: - M5: stage-inference model
    //
    // Picks a `StageInferenceModel`. Looks for a compiled Core ML resource
    // named `SleepStager.mlmodelc` (or `.mlpackage`) in the provided bundle;
    // falls back silently to the heuristic model on:
    //
    // - missing resource (model not yet trained/exported)
    // - platform that can't load Core ML (non-Apple builds, test host)
    // - any Core ML load failure
    //
    // `fallbackReason` is populated whenever we fall back, for UI debugging.
    public static func makeInferenceModel(
        bundle: Bundle = .main,
        resourceName: String = ModelContract.resourceName
    ) -> (model: StageInferenceModel, modelLoadMs: Double, fallbackReason: String?) {
        #if canImport(CoreML)
        let candidates: [URL] = [
            bundle.url(forResource: resourceName, withExtension: "mlmodelc"),
            bundle.url(forResource: resourceName, withExtension: "mlpackage"),
            bundle.url(forResource: resourceName, withExtension: "mlmodel"),
        ].compactMap { $0 }
        if let url = candidates.first {
            let start = Date()
            do {
                let m = try CoreMLStageInferenceModel(modelURL: url)
                let ms = Date().timeIntervalSince(start) * 1000.0
                return (m, ms, nil)
            } catch {
                return (FallbackHeuristicStageInferenceModel(), 0,
                        "CoreML load failed: \(error); using heuristic stager.")
            }
        }
        return (FallbackHeuristicStageInferenceModel(), 0,
                "No \(resourceName).mlmodelc bundled; using heuristic stager.")
        #else
        return (FallbackHeuristicStageInferenceModel(), 0,
                "CoreML unavailable on this platform; using heuristic stager.")
        #endif
    }
}
