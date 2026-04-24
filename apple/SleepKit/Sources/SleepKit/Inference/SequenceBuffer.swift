import Foundation

/// Fixed-capacity rolling buffer of feature vectors. Oldest entries are
/// dropped when capacity is exceeded. `snapshot()` returns a `seqLen`-long
/// array, left-padded with zero vectors when the buffer is not yet full,
/// so downstream tensor shape is stable from the first inference tick.
public struct SequenceBuffer {

    public let seqLen: Int
    public let featureDim: Int
    private var storage: [[Float]] = []

    public init(seqLen: Int, featureDim: Int) {
        self.seqLen = seqLen
        self.featureDim = featureDim
    }

    public mutating func append(_ vector: [Float]) {
        var v = vector
        if v.count < featureDim { v += Array(repeating: 0, count: featureDim - v.count) }
        else if v.count > featureDim { v = Array(v.prefix(featureDim)) }
        storage.append(v)
        if storage.count > seqLen { storage.removeFirst(storage.count - seqLen) }
    }

    public mutating func reset() { storage.removeAll(keepingCapacity: true) }

    public var count: Int { storage.count }
    public var isFull: Bool { storage.count >= seqLen }

    public func snapshot() -> [[Float]] {
        if storage.count >= seqLen { return storage }
        let padCount = seqLen - storage.count
        let pad = Array(repeating: Array<Float>(repeating: 0, count: featureDim),
                        count: padCount)
        return pad + storage
    }
}
