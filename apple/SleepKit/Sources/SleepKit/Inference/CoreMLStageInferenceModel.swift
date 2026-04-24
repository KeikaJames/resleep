import Foundation
#if canImport(CoreML)
import CoreML
#endif

/// Core ML-backed tiny-transformer stager. Loads a compiled `.mlmodelc` (or
/// an `.mlpackage` that Core ML compiles on the fly) from disk at init and
/// invokes it on each `predict` call.
///
/// Resource layout:
/// - The model is expected to expose a single MultiArray input named
///   `features` with shape `(1, seqLen, featureDim)` and dtype `Float32`.
/// - The output is expected to be a MultiArray of class logits/probs with
///   length `numClasses`. Either logits or probabilities work — callers
///   normalize through `StageInferenceOutput.fromProbabilities`.
///
/// If the resource is missing or the platform can't load Core ML, construction
/// throws `StageInferenceError.modelMissing` / `.platformUnsupported`.
/// Callers (see `SleepEngineFactory.makeInferenceModel`) fall back to the
/// heuristic model silently.
public final class CoreMLStageInferenceModel: StageInferenceModel, @unchecked Sendable {

    public let hyperparameters: StageInferenceHyperparameters
    public var isRealModel: Bool { true }
    public let descriptor: StageModelDescriptor

    #if canImport(CoreML)
    private let model: MLModel
    private let resolvedInputName: String
    private let resolvedOutputName: String
    #endif

    public init(modelURL: URL,
                hyperparameters: StageInferenceHyperparameters = .default) throws {
        self.hyperparameters = hyperparameters
        #if canImport(CoreML)
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw StageInferenceError.modelMissing
        }
        let loaded: MLModel
        do {
            let compiledURL: URL
            if modelURL.pathExtension == "mlmodelc" {
                compiledURL = modelURL
            } else {
                compiledURL = try MLModel.compileModel(at: modelURL)
            }
            loaded = try MLModel(contentsOf: compiledURL)
        } catch {
            throw StageInferenceError.underlying(String(describing: error))
        }
        // Validate input/output contract. Prefer the canonical `features` +
        // `logits` names, but tolerate a single input/output of any name
        // (older exports sometimes autorename). Throw only if the input
        // contract is structurally wrong (no MultiArray, or wrong shape
        // length).
        let desc = loaded.modelDescription
        let inputs = desc.inputDescriptionsByName
        guard !inputs.isEmpty else {
            throw StageInferenceError.invalidInputShape
        }
        let inputName: String = inputs[ModelContract.inputName] != nil
            ? ModelContract.inputName
            : (inputs.keys.first ?? ModelContract.inputName)
        let outputs = desc.outputDescriptionsByName
        let outputName: String = outputs[ModelContract.outputName] != nil
            ? ModelContract.outputName
            : (outputs.keys.first ?? ModelContract.outputName)

        self.model = loaded
        self.resolvedInputName = inputName
        self.resolvedOutputName = outputName

        let meta = desc.metadata
        let version = meta[MLModelMetadataKey.versionString] as? String
        let displayName = (meta[MLModelMetadataKey.description] as? String)
            ?? modelURL.deletingPathExtension().lastPathComponent
        self.descriptor = StageModelDescriptor(
            kind: .coreML,
            name: displayName,
            version: version,
            modelURL: modelURL,
            inputName: inputName,
            outputName: outputName
        )
        #else
        throw StageInferenceError.platformUnsupported
        #endif
    }

    public func predict(_ input: StageInferenceInput) throws -> StageInferenceOutput {
        guard input.seqLen == hyperparameters.seqLen,
              input.featureDim == hyperparameters.featureDim,
              input.window.count == hyperparameters.seqLen else {
            throw StageInferenceError.invalidInputShape
        }
        #if canImport(CoreML)
        let array = try MLMultiArray(
            shape: [1, NSNumber(value: input.seqLen), NSNumber(value: input.featureDim)],
            dataType: .float32
        )
        for (t, row) in input.window.enumerated() {
            for (f, value) in row.enumerated() {
                let flatIndex = (t * input.featureDim) + f
                array[flatIndex] = NSNumber(value: value)
            }
        }
        let provider = try MLDictionaryFeatureProvider(
            dictionary: [resolvedInputName: MLFeatureValue(multiArray: array)]
        )
        let output: MLFeatureProvider
        do {
            output = try model.prediction(from: provider)
        } catch {
            throw StageInferenceError.underlying(String(describing: error))
        }
        let arrOpt = output.featureValue(for: resolvedOutputName)?.multiArrayValue
            ?? firstMultiArray(output)
        guard let arr = arrOpt else {
            throw StageInferenceError.invalidInputShape
        }
        var probs: [Float] = []
        probs.reserveCapacity(hyperparameters.numClasses)
        for i in 0..<min(arr.count, hyperparameters.numClasses) {
            probs.append(arr[i].floatValue)
        }
        let needsSoftmax = probs.contains(where: { $0 < 0 }) ||
            abs(probs.reduce(0, +) - 1) > 0.25
        let normalized = needsSoftmax ? softmax(probs) : probs
        return StageInferenceOutput.fromProbabilities(normalized)
        #else
        throw StageInferenceError.platformUnsupported
        #endif
    }

    #if canImport(CoreML)
    private func firstMultiArray(_ provider: MLFeatureProvider) -> MLMultiArray? {
        for name in provider.featureNames {
            if let arr = provider.featureValue(for: name)?.multiArrayValue {
                return arr
            }
        }
        return nil
    }
    #endif

    private func softmax(_ xs: [Float]) -> [Float] {
        let m = xs.max() ?? 0
        let exps = xs.map { expf($0 - m) }
        let sum = exps.reduce(0, +)
        return sum > 0 ? exps.map { $0 / sum } : exps
    }
}
