//  StrokeTrackerTests.swift
//  BuchstabenNativeTests

import Testing
import CoreGraphics
@testable import BuchstabenNative

private struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64 = 0xdeadbeef_cafebabe) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }
}

private func cp(_ x: CGFloat, _ y: CGFloat) -> Checkpoint { Checkpoint(x: x, y: y) }
private func strokeDef(id: Int, checkpoints: [Checkpoint]) -> StrokeDefinition {
    StrokeDefinition(id: id, checkpoints: checkpoints)
}
private func letter(_ name: String = "A", radius: CGFloat = 0.1, strokes: [StrokeDefinition]) -> LetterStrokes {
    LetterStrokes(letter: name, checkpointRadius: radius, strokes: strokes)
}
private func completeAll(_ tracker: StrokeTracker, _ def: LetterStrokes) {
    for stroke in def.strokes {
        for c in stroke.checkpoints {
            tracker.update(normalizedPoint: CGPoint(x: c.x, y: c.y))
        }
    }
}

@Suite @MainActor struct StrokeTrackerTests {

    @Test func preLoad_allComputedProperties_safeDefaults() {
        let t = StrokeTracker()
        #expect(!t.soundEnabled); #expect(!t.isComplete)
        #expect(abs(t.overallProgress) < 1e-9)
        #expect(t.currentStrokeIndex == 0)
        #expect(t.definition == nil)
        #expect(t.progress.isEmpty)
    }
    @Test func update_beforeLoad_doesNotCrash() {
        let t = StrokeTracker()
        t.update(normalizedPoint: CGPoint(x: 0.5, y: 0.5))
        t.update(normalizedPoint: CGPoint(x: 0.0, y: 0.0))
        #expect(!t.isComplete)
    }
    @Test func reset_beforeLoad_doesNotCrash() {
        let t = StrokeTracker(); t.reset()
        #expect(!t.isComplete)
        #expect(abs(t.overallProgress) < 1e-9)
        #expect(t.progress.isEmpty)
        #expect(t.definition == nil)
    }
    @Test func singleStroke_happyPath() {
        let t = StrokeTracker()
        let def = letter(strokes: [strokeDef(id: 0, checkpoints: [cp(0.1,0.1), cp(0.5,0.5), cp(0.9,0.9)])])
        t.load(def); #expect(!t.isComplete)
        completeAll(t, def)
        #expect(t.isComplete); #expect(abs(t.overallProgress - 1.0) < 1e-9)
    }
    @Test func multiStroke_happyPath() {
        let t = StrokeTracker()
        let def = letter(strokes: [
            strokeDef(id: 0, checkpoints: [cp(0.1,0.1), cp(0.2,0.2)]),
            strokeDef(id: 1, checkpoints: [cp(0.5,0.5), cp(0.6,0.6)]),
            strokeDef(id: 2, checkpoints: [cp(0.8,0.8)])
        ])
        t.load(def); completeAll(t, def)
        #expect(t.isComplete); #expect(abs(t.overallProgress - 1.0) < 1e-9)
    }
    @Test func zeroStrokes_isCompleteImmediately() {
        let t = StrokeTracker(); t.load(letter(strokes: []))
        #expect(t.isComplete)
        #expect(!t.soundEnabled)
        #expect(abs(t.overallProgress) < 1e-9)
        #expect(!t.overallProgress.isNaN)
        #expect(!t.overallProgress.isInfinite)
    }
    @Test func singleCheckpoint_completesOnHit() {
        let t = StrokeTracker()
        t.load(letter(strokes: [strokeDef(id: 0, checkpoints: [cp(0.5,0.5)])]))
        #expect(!t.isComplete)
        t.update(normalizedPoint: CGPoint(x: 0.5, y: 0.5))
        #expect(t.isComplete)
    }
    @Test func zeroCheckpointStroke_neverCompletes() {
        let t = StrokeTracker()
        t.load(letter(strokes: [strokeDef(id: 0, checkpoints: [])]))
        t.update(normalizedPoint: CGPoint(x: 0.5, y: 0.5))
        #expect(!t.isComplete)
        #expect(!t.overallProgress.isNaN)
        #expect(!t.overallProgress.isInfinite)
    }
    @Test func multiStroke_allZeroCheckpoints_overallProgressIsNotNaN() {
        let t = StrokeTracker()
        t.load(letter(strokes: [strokeDef(id: 0, checkpoints: []), strokeDef(id: 1, checkpoints: [])]))
        #expect(abs(t.overallProgress) < 1e-9)
        #expect(!t.overallProgress.isNaN)
        #expect(!t.overallProgress.isInfinite)
    }
    @Test func boundaryHit_justInsideRadius_registers() {
        let radius: CGFloat = 0.1; let c = cp(0.5, 0.5)
        let t = StrokeTracker()
        t.load(letter(radius: radius, strokes: [strokeDef(id: 0, checkpoints: [c])]))
        t.update(normalizedPoint: CGPoint(x: c.x + radius * (1.0 - 1e-6), y: c.y))
        #expect(t.isComplete)
    }
    @Test func boundaryMiss_justOutsideRadius_doesNotRegister() {
        let radius: CGFloat = 0.1; let c = cp(0.5, 0.5)
        let t = StrokeTracker()
        t.load(letter(radius: radius, strokes: [strokeDef(id: 0, checkpoints: [c])]))
        t.update(normalizedPoint: CGPoint(x: c.x + radius * (1.0 + 1e-6), y: c.y))
        #expect(!t.isComplete)
    }
    @Test func reset_restoresInitialState() {
        let t = StrokeTracker()
        let def = letter(strokes: [strokeDef(id: 0, checkpoints: [cp(0.1,0.1), cp(0.9,0.9)])])
        t.load(def)
        t.update(normalizedPoint: CGPoint(x: 0.1, y: 0.1))
        #expect(t.overallProgress > 0.0); #expect(!t.isComplete)
        t.reset()
        #expect(abs(t.overallProgress) < 1e-9)
        #expect(!t.isComplete)
        #expect(t.currentStrokeIndex == 0)
        #expect(!t.soundEnabled)
    }
    @Test func isComplete_onlyAfterAllStrokes() {
        let t = StrokeTracker()
        let def = letter(strokes: [strokeDef(id: 0, checkpoints: [cp(0.1,0.1)]), strokeDef(id: 1, checkpoints: [cp(0.9,0.9)])])
        t.load(def)
        t.update(normalizedPoint: CGPoint(x: 0.1, y: 0.1))
        #expect(!t.isComplete)
        t.update(normalizedPoint: CGPoint(x: 0.9, y: 0.9))
        #expect(t.isComplete)
    }
    @Test func overallProgress_fractions() {
        let t = StrokeTracker()
        let def = letter(strokes: [
            strokeDef(id: 0, checkpoints: [cp(0.1,0.1), cp(0.2,0.2)]),
            strokeDef(id: 1, checkpoints: [cp(0.3,0.3), cp(0.4,0.4)])
        ])
        t.load(def)
        #expect(abs(t.overallProgress - 0.00) < 1e-9)
        t.update(normalizedPoint: CGPoint(x: 0.1, y: 0.1)); #expect(abs(t.overallProgress - 0.25) < 1e-9)
        t.update(normalizedPoint: CGPoint(x: 0.2, y: 0.2)); #expect(abs(t.overallProgress - 0.50) < 1e-9)
        t.update(normalizedPoint: CGPoint(x: 0.3, y: 0.3)); #expect(abs(t.overallProgress - 0.75) < 1e-9)
        t.update(normalizedPoint: CGPoint(x: 0.4, y: 0.4)); #expect(abs(t.overallProgress - 1.00) < 1e-9)
    }
    @Test func currentStrokeIndex_advances_andIsCompleteSafe() {
        let t = StrokeTracker()
        let def = letter(strokes: [
            strokeDef(id: 0, checkpoints: [cp(0.1,0.1)]),
            strokeDef(id: 1, checkpoints: [cp(0.5,0.5)]),
            strokeDef(id: 2, checkpoints: [cp(0.9,0.9)])
        ])
        t.load(def)
        #expect(t.currentStrokeIndex == 0)
        t.update(normalizedPoint: CGPoint(x: 0.1, y: 0.1)); #expect(t.currentStrokeIndex == 1)
        t.update(normalizedPoint: CGPoint(x: 0.5, y: 0.5)); #expect(t.currentStrokeIndex == 2)
        t.update(normalizedPoint: CGPoint(x: 0.9, y: 0.9))
        #expect(t.currentStrokeIndex == 3)
        #expect(t.isComplete)
        #expect(!t.soundEnabled)
        #expect(abs(t.overallProgress - 1.0) < 1e-9)
    }
    @Test func soundEnabled_falseBeforeFirstHit_trueAfter() {
        let t = StrokeTracker()
        t.load(letter(strokes: [strokeDef(id: 0, checkpoints: [cp(0.2,0.2), cp(0.8,0.8)])]))
        #expect(!t.soundEnabled)
        t.update(normalizedPoint: CGPoint(x: 0.2, y: 0.2))
        #expect(t.soundEnabled)
    }
    @Test func soundEnabled_resetsOnNewStroke() {
        let t = StrokeTracker()
        t.load(letter(strokes: [
            strokeDef(id: 0, checkpoints: [cp(0.1,0.1)]),
            strokeDef(id: 1, checkpoints: [cp(0.5,0.5), cp(0.9,0.9)])
        ]))
        t.update(normalizedPoint: CGPoint(x: 0.1, y: 0.1))
        #expect(!t.soundEnabled)
        t.update(normalizedPoint: CGPoint(x: 0.5, y: 0.5))
        #expect(t.soundEnabled)
    }
    @Test func update_afterComplete_isNoOp() {
        let t = StrokeTracker()
        t.load(letter(strokes: [strokeDef(id: 0, checkpoints: [cp(0.5,0.5)])]))
        t.update(normalizedPoint: CGPoint(x: 0.5, y: 0.5))
        #expect(t.isComplete)
        let snap = t.overallProgress
        t.update(normalizedPoint: CGPoint(x: 0.5, y: 0.5))
        t.update(normalizedPoint: CGPoint(x: 0.0, y: 0.0))
        #expect(t.isComplete)
        #expect(abs(t.overallProgress - snap) < 1e-9)
    }
    @Test func reload_withDifferentDefinition_resetsState() {
        let t = StrokeTracker()
        let defA = letter("A", strokes: [strokeDef(id: 0, checkpoints: [cp(0.1,0.1)])])
        t.load(defA); completeAll(t, defA); #expect(t.isComplete)
        let defB = letter("B", strokes: [strokeDef(id: 0, checkpoints: [cp(0.3,0.3)]), strokeDef(id: 1, checkpoints: [cp(0.7,0.7)])])
        t.load(defB)
        #expect(!t.isComplete); #expect(t.currentStrokeIndex == 0)
        #expect(abs(t.overallProgress) < 1e-9); #expect(!t.soundEnabled)
        #expect(t.progress.count == 2)
    }
    @Test func fuzz_randomPoints_neverCrash_progressStaysInRange() {
        var rng = SeededRNG(seed: 0xdeadbeef_cafebabe)
        let t = StrokeTracker()
        let def = letter(radius: 0.1, strokes: [
            strokeDef(id: 0, checkpoints: [cp(0.1,0.1), cp(0.3,0.3)]),
            strokeDef(id: 1, checkpoints: [cp(0.5,0.5), cp(0.7,0.7)]),
            strokeDef(id: 2, checkpoints: [cp(0.9,0.9)])
        ])
        t.load(def)
        for _ in 0..<2_000 {
            let x = CGFloat(Double.random(in: 0...1, using: &rng))
            let y = CGFloat(Double.random(in: 0...1, using: &rng))
            t.update(normalizedPoint: CGPoint(x: x, y: y))
            let p = t.overallProgress
            #expect(p >= 0.0); #expect(p <= 1.0); #expect(!p.isNaN); #expect(!p.isInfinite)
        }
    }
    @Test func fuzz_targetedPerturbations_eventuallyComplete() {
        var rng = SeededRNG(seed: 0xcafebabe_deadbeef)
        let radius: CGFloat = 0.1
        let t = StrokeTracker()
        let def = letter(radius: radius, strokes: [
            strokeDef(id: 0, checkpoints: [cp(0.2,0.2), cp(0.4,0.4)]),
            strokeDef(id: 1, checkpoints: [cp(0.6,0.6), cp(0.8,0.8)])
        ])
        t.load(def)
        for stroke in def.strokes {
            for c in stroke.checkpoints {
                for _ in 0..<20 {
                    let angle = CGFloat(Double.random(in: 0..<(2 * .pi), using: &rng))
                    let dist  = CGFloat(Double.random(in: 0..<(radius * 0.95), using: &rng))
                    t.update(normalizedPoint: CGPoint(x: c.x + dist * cos(angle), y: c.y + dist * sin(angle)))
                    if t.currentStrokeIndex > def.strokes.firstIndex(where: { $0.id == stroke.id }) ?? 0 { break }
                }
            }
        }
        #expect(t.isComplete); #expect(abs(t.overallProgress - 1.0) < 1e-9)
    }
    @Test func radiusMultiplier_zero_onlyExactHitRegisters() {
        var t = StrokeTracker()
        t.load(letter(radius: 0.1, strokes: [strokeDef(id: 1, checkpoints: [cp(0.5,0.5)])]))
        t.radiusMultiplier = 0.0
        t.update(normalizedPoint: CGPoint(x: 0.5, y: 0.5))
        #expect(t.isComplete)
    }
    @Test func radiusMultiplier_zero_nearMissDoesNotRegister() {
        var t = StrokeTracker()
        t.load(letter(radius: 0.1, strokes: [strokeDef(id: 1, checkpoints: [cp(0.5,0.5)])]))
        t.radiusMultiplier = 0.0
        t.update(normalizedPoint: CGPoint(x: 0.5 + 1e-9, y: 0.5))
        #expect(!t.isComplete); #expect(!t.soundEnabled)
    }
    @Test func radiusMultiplier_switchFromZeroToOne_pendingCheckpointBecomesHittable() {
        var t = StrokeTracker()
        t.load(letter(radius: 0.1, strokes: [strokeDef(id: 1, checkpoints: [cp(0.5,0.5)])]))
        let insidePoint = CGPoint(x: 0.55, y: 0.5)
        t.radiusMultiplier = 0.0; t.update(normalizedPoint: insidePoint); #expect(!t.isComplete)
        t.radiusMultiplier = 1.0; t.update(normalizedPoint: insidePoint); #expect(t.isComplete)
    }
    @Test func radiusMultiplier_zero_emptyStrokes_noCrash() {
        var t = StrokeTracker()
        t.load(letter(radius: 0.1, strokes: []))
        t.radiusMultiplier = 0.0
        t.update(normalizedPoint: CGPoint(x: 0.5, y: 0.5))
        #expect(t.isComplete); #expect(!t.soundEnabled)
    }
    @Test func radiusMultiplier_negative_exactHitDoesNotRegister() {
        var t = StrokeTracker()
        t.load(letter(radius: 0.1, strokes: [strokeDef(id: 1, checkpoints: [cp(0.5,0.5)])]))
        t.radiusMultiplier = -0.3
        t.update(normalizedPoint: CGPoint(x: 0.5, y: 0.5))
        #expect(!t.isComplete)
    }
    @Test func radiusMultiplier_two_enlargedRadiusAcceptsPoint() {
        var t = StrokeTracker()
        t.load(letter(radius: 0.1, strokes: [strokeDef(id: 1, checkpoints: [cp(0.5,0.5)])]))
        t.radiusMultiplier = 2.0
        t.update(normalizedPoint: CGPoint(x: 0.65, y: 0.5))
        #expect(t.isComplete)
    }
    @Test func radiusMultiplier_default_boundaryPointRegisters() {
        var t = StrokeTracker()
        let radius: CGFloat = 0.1
        t.load(letter(radius: radius, strokes: [strokeDef(id: 1, checkpoints: [cp(0.5,0.5)])]))
        t.radiusMultiplier = 1.0
        t.update(normalizedPoint: CGPoint(x: 0.5 + radius, y: 0.5))
        #expect(t.isComplete)
    }
}
