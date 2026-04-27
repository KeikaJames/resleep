import XCTest
@testable import SleepKit

final class PersonalizationServiceTests: XCTestCase {

    func testZeroVectorLeavesLogitsUntouched() {
        let base: [Float] = [0.1, 0.2, 0.3, 0.4]
        let feats: [Float] = Array(repeating: 1, count: PersonalizationVector.dim)
        let out = PersonalizationService.add(base: base,
                                             vec: .zero,
                                             features: feats)
        XCTAssertEqual(out, base)
    }

    func testSingleStepMovesPredictionTowardLabel() {
        var vec = PersonalizationVector.zero
        let feats: [Float] = [1, 0, 0, 0, 0, 0, 0, 0, 0]
        let label = PersonalLabel(sessionId: "s", features: feats, stage: 2)
        // 50 SGD steps with the same example → predicted argmax should be 2.
        for _ in 0..<50 {
            vec = PersonalizationService.applyOneStep(
                vec: vec, label: label, lr: 0.2, decay: 0.0
            )
        }
        let logits = PersonalizationService.add(
            base: [0, 0, 0, 0], vec: vec, features: feats
        )
        let argmax = logits.indices.max(by: { logits[$0] < logits[$1] }) ?? 0
        XCTAssertEqual(argmax, 2)
    }

    func testIngestPersists() async throws {
        let store = InMemoryPersonalizationStore()
        let svc = PersonalizationService(store: store, learningRate: 0.1)
        let feats: [Float] = [1, 0, 0, 0, 0, 0, 0, 0, 0]
        let labels = (0..<10).map {
            PersonalLabel(sessionId: "s\($0)", features: feats, stage: 1)
        }
        await svc.ingest(labels: labels)
        let snap = await svc.snapshot()
        XCTAssertEqual(snap.sampleCount, 10)
        XCTAssertNotNil(snap.lastUpdatedAt)
        // bias for class 1 should have moved upward
        XCTAssertGreaterThan(snap.bias[1], snap.bias[0])
    }

    func testResetClearsState() async {
        let store = InMemoryPersonalizationStore()
        let svc = PersonalizationService(store: store)
        let feats: [Float] = Array(repeating: 0.5, count: PersonalizationVector.dim)
        await svc.ingest(labels: [
            PersonalLabel(sessionId: "s", features: feats, stage: 3)
        ])
        await svc.reset()
        let snap = await svc.snapshot()
        XCTAssertEqual(snap, .zero)
    }

    func testWeightDecayShrinksWeights() {
        var vec = PersonalizationVector(
            weights: Array(repeating: 1.0, count: 36),
            bias: Array(repeating: 1.0, count: 4),
            version: 1, sampleCount: 0, lastUpdatedAt: nil
        )
        let feats: [Float] = Array(repeating: 0, count: 9)
        // a label whose features are all zero only triggers bias movement;
        // weight decay should still pull weights toward zero.
        let label = PersonalLabel(sessionId: "s", features: feats, stage: 0)
        let before = vec.weights[0]
        for _ in 0..<10 {
            vec = PersonalizationService.applyOneStep(
                vec: vec, label: label, lr: 0.1, decay: 0.5
            )
        }
        XCTAssertLessThan(vec.weights[0], before)
    }
}
