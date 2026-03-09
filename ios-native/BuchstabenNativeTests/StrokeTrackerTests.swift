//  StrokeTrackerTests.swift
//  BuchstabenNativeTests
//
//  Pure logic tests — no hardware, no AVAudio, no UIKit.
//  All tests run synchronously on the main thread; no concurrency concerns.
//
//  Note: tests assume 64-bit CGFloat (macOS / iOS 64-bit simulator).
//  On a 32-bit target CGFloat == Float32 and boundary arithmetic may differ.

import XCTest
import CoreGraphics
@testable import BuchstabenNative

// MARK: - Seeded deterministic RNG (splitmix64)
// Using a fixed seed makes fuzz failures reproducible across CI runs.
// If a fuzz test fails, the seed printed via XCTContext reproduces the exact sequence.

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

// MARK: - Test helpers

private func cp(_ x: CGFloat, _ y: CGFloat) -> Checkpoint {
    Checkpoint(x: x, y: y)
}

private func strokeDef(id: Int, checkpoints: [Checkpoint]) -> StrokeDefinition {
    StrokeDefinition(id: id, checkpoints: checkpoints)
}

private func letter(
    _ name: String = "A",
    radius: CGFloat = 0.1,
    strokes: [StrokeDefinition]
) -> LetterStrokes {
    LetterStrokes(letter: name, checkpointRadius: radius, strokes: strokes)
}

/// Drive every checkpoint of every stroke exactly to its centre point.
private func completeAll(_ tracker: StrokeTracker, _ def: LetterStrokes) {
    for stroke in def.strokes {
        for c in stroke.checkpoints {
            tracker.update(normalizedPoint: CGPoint(x: c.x, y: c.y))
        }
    }
}

// MARK: - StrokeTrackerTests

@MainActor
final class StrokeTrackerTests: XCTestCase {

    // MARK: 1 — Pre-load nil-guard computed properties

    func testPreLoad_allComputedProperties_safeDefaults() {
        let t = StrokeTracker()
        XCTAssertFalse(t.soundEnabled,  "soundEnabled must be false before load")
        XCTAssertFalse(t.isComplete,    "isComplete must be false before load")
        XCTAssertEqual(t.overallProgress, 0.0, accuracy: 1e-9, "overallProgress must be 0 before load")
        XCTAssertEqual(t.currentStrokeIndex, 0, "currentStrokeIndex must be 0 before load")
        XCTAssertNil(t.definition)
        XCTAssertTrue(t.progress.isEmpty)
    }

    // MARK: 2 — update() before load must not crash

    func testUpdate_beforeLoad_doesNotCrash() {
        let t = StrokeTracker()
        t.update(normalizedPoint: CGPoint(x: 0.5, y: 0.5))
        t.update(normalizedPoint: CGPoint(x: 0.0, y: 0.0))
        XCTAssertFalse(t.isComplete)
    }

    // MARK: 3 — reset() before load must not crash

    func testReset_beforeLoad_doesNotCrash() {
        let t = StrokeTracker()
        t.reset()
        XCTAssertFalse(t.isComplete)
        XCTAssertEqual(t.overallProgress, 0.0, accuracy: 1e-9)
        XCTAssertTrue(t.progress.isEmpty)
        XCTAssertNil(t.definition)
    }

    // MARK: 4 — Single-stroke happy path

    func testSingleStroke_happyPath() {
        let t = StrokeTracker()
        let def = letter(strokes: [
            strokeDef(id: 0, checkpoints: [cp(0.1, 0.1), cp(0.5, 0.5), cp(0.9, 0.9)])
        ])
        t.load(def)
        XCTAssertFalse(t.isComplete)
        XCTAssertEqual(t.overallProgress, 0.0, accuracy: 1e-9)

        completeAll(t, def)

        XCTAssertTrue(t.isComplete)
        XCTAssertEqual(t.overallProgress, 1.0, accuracy: 1e-9)
    }

    // MARK: 5 — Multi-stroke happy path

    func testMultiStroke_happyPath() {
        let t = StrokeTracker()
        let def = letter(strokes: [
            strokeDef(id: 0, checkpoints: [cp(0.1, 0.1), cp(0.2, 0.2)]),
            strokeDef(id: 1, checkpoints: [cp(0.5, 0.5), cp(0.6, 0.6)]),
            strokeDef(id: 2, checkpoints: [cp(0.8, 0.8)])
        ])
        t.load(def)
        completeAll(t, def)
        XCTAssertTrue(t.isComplete)
        XCTAssertEqual(t.overallProgress, 1.0, accuracy: 1e-9)
    }

    // MARK: 6 — Edge: zero-stroke LetterStrokes

    func testZeroStrokes_isCompleteImmediately() {
        let t = StrokeTracker()
        let def = letter(strokes: [])
        t.load(def)

        // allSatisfy on empty collection is vacuously true → isComplete == true
        XCTAssertTrue(t.isComplete,
                      "Zero-stroke letter must be immediately complete (vacuous allSatisfy)")
        XCTAssertFalse(t.soundEnabled,
                       "soundEnabled must be false: currentStrokeIndex(0) < strokes.count(0) is false")
        XCTAssertEqual(t.overallProgress, 0.0, accuracy: 1e-9,
                       "overallProgress must be 0 when total checkpoints == 0")
        XCTAssertFalse(t.overallProgress.isNaN,      "overallProgress must not be NaN")
        XCTAssertFalse(t.overallProgress.isInfinite, "overallProgress must not be Inf")
    }

    // MARK: 7 — Edge: single-checkpoint stroke

    func testSingleCheckpoint_completesOnHit() {
        let t = StrokeTracker()
        let def = letter(strokes: [strokeDef(id: 0, checkpoints: [cp(0.5, 0.5)])])
        t.load(def)
        XCTAssertFalse(t.isComplete)
        t.update(normalizedPoint: CGPoint(x: 0.5, y: 0.5))
        XCTAssertTrue(t.isComplete)
    }

    // MARK: 8 — Edge: zero-checkpoint stroke (KNOWN BEHAVIOUR)

    func testZeroCheckpointStroke_neverCompletes() {
        // KNOWN BEHAVIOUR: a stroke with 0 checkpoints can never be marked complete
        // via update() — the guard `nextCheckpoint < stroke.checkpoints.count` fires
        // immediately (0 < 0 is false). isComplete therefore stays false permanently.
        // If the design intent changes (auto-complete zero-checkpoint strokes on load),
        // this test must be updated accordingly.
        let t = StrokeTracker()
        let def = letter(strokes: [strokeDef(id: 0, checkpoints: [])])
        t.load(def)
        t.update(normalizedPoint: CGPoint(x: 0.5, y: 0.5))
        XCTAssertFalse(t.isComplete,
                       "Zero-checkpoint stroke is never marked complete by update() — see KNOWN BEHAVIOUR above")
        XCTAssertFalse(t.overallProgress.isNaN,      "overallProgress must not be NaN")
        XCTAssertFalse(t.overallProgress.isInfinite, "overallProgress must not be Inf")
    }

    // MARK: 9 — Edge: all strokes have zero checkpoints (NaN guard)

    func testMultiStroke_allZeroCheckpoints_overallProgressIsNotNaN() {
        let t = StrokeTracker()
        let def = letter(strokes: [
            strokeDef(id: 0, checkpoints: []),
            strokeDef(id: 1, checkpoints: [])
        ])
        t.load(def)
        XCTAssertEqual(t.overallProgress, 0.0, accuracy: 1e-9)
        XCTAssertFalse(t.overallProgress.isNaN)
        XCTAssertFalse(t.overallProgress.isInfinite)
    }

    // MARK: 10 — Boundary hit: point just inside radius

    func testBoundaryHit_justInsideRadius_registers() {
        // Avoid exact-boundary test: hypot(r, 0) may not equal r exactly for non-representable
        // CGFloat values (e.g. 0.05). Use radius * (1 - 1e-6) to guarantee inside.
        let radius: CGFloat = 0.1
        let c = cp(0.5, 0.5)
        let t = StrokeTracker()
        let def = letter(radius: radius, strokes: [strokeDef(id: 0, checkpoints: [c])])
        t.load(def)

        // Point at distance radius * (1 - 1e-6) horizontally — reliably inside
        let hitPoint = CGPoint(x: c.x + radius * (1.0 - 1e-6), y: c.y)
        t.update(normalizedPoint: hitPoint)
        XCTAssertTrue(t.isComplete, "Point just inside radius must register")
    }

    // MARK: 11 — Boundary miss: point just outside radius

    func testBoundaryMiss_justOutsideRadius_doesNotRegister() {
        let radius: CGFloat = 0.1
        let c = cp(0.5, 0.5)
        let t = StrokeTracker()
        let def = letter(radius: radius, strokes: [strokeDef(id: 0, checkpoints: [c])])
        t.load(def)

        // Point at distance radius * (1 + 1e-6) — reliably outside
        let missPoint = CGPoint(x: c.x + radius * (1.0 + 1e-6), y: c.y)
        t.update(normalizedPoint: missPoint)
        XCTAssertFalse(t.isComplete, "Point just outside radius must not register")
    }

    // MARK: 12 — reset() restores state after partial progress

    func testReset_restoresInitialState() {
        let t = StrokeTracker()
        let def = letter(strokes: [
            strokeDef(id: 0, checkpoints: [cp(0.1, 0.1), cp(0.9, 0.9)])
        ])
        t.load(def)

        t.update(normalizedPoint: CGPoint(x: 0.1, y: 0.1))
        XCTAssertGreaterThan(t.overallProgress, 0.0)
        XCTAssertFalse(t.isComplete)

        t.reset()

        XCTAssertEqual(t.overallProgress, 0.0, accuracy: 1e-9)
        XCTAssertFalse(t.isComplete)
        XCTAssertEqual(t.currentStrokeIndex, 0)
        XCTAssertFalse(t.soundEnabled)
    }

    // MARK: 13 — isComplete only after ALL strokes done

    func testIsComplete_onlyAfterAllStrokes() {
        let t = StrokeTracker()
        let def = letter(strokes: [
            strokeDef(id: 0, checkpoints: [cp(0.1, 0.1)]),
            strokeDef(id: 1, checkpoints: [cp(0.9, 0.9)])
        ])
        t.load(def)

        t.update(normalizedPoint: CGPoint(x: 0.1, y: 0.1))
        XCTAssertFalse(t.isComplete, "Must not be complete after only first stroke")

        t.update(normalizedPoint: CGPoint(x: 0.9, y: 0.9))
        XCTAssertTrue(t.isComplete)
    }

    // MARK: 14 — overallProgress fractions

    func testOverallProgress_fractions() {
        let t = StrokeTracker()
        // 2 strokes × 2 checkpoints = 4 total → each hit adds 0.25
        let def = letter(strokes: [
            strokeDef(id: 0, checkpoints: [cp(0.1, 0.1), cp(0.2, 0.2)]),
            strokeDef(id: 1, checkpoints: [cp(0.3, 0.3), cp(0.4, 0.4)])
        ])
        t.load(def)

        XCTAssertEqual(t.overallProgress, 0.00, accuracy: 1e-9)
        t.update(normalizedPoint: CGPoint(x: 0.1, y: 0.1))
        XCTAssertEqual(t.overallProgress, 0.25, accuracy: 1e-9)
        t.update(normalizedPoint: CGPoint(x: 0.2, y: 0.2))
        XCTAssertEqual(t.overallProgress, 0.50, accuracy: 1e-9)
        t.update(normalizedPoint: CGPoint(x: 0.3, y: 0.3))
        XCTAssertEqual(t.overallProgress, 0.75, accuracy: 1e-9)
        t.update(normalizedPoint: CGPoint(x: 0.4, y: 0.4))
        XCTAssertEqual(t.overallProgress, 1.00, accuracy: 1e-9)
    }

    // MARK: 15 — currentStrokeIndex advances correctly

    func testCurrentStrokeIndex_advances_andIsCompleteSafe() {
        let t = StrokeTracker()
        let def = letter(strokes: [
            strokeDef(id: 0, checkpoints: [cp(0.1, 0.1)]),
            strokeDef(id: 1, checkpoints: [cp(0.5, 0.5)]),
            strokeDef(id: 2, checkpoints: [cp(0.9, 0.9)])
        ])
        t.load(def)

        XCTAssertEqual(t.currentStrokeIndex, 0)
        t.update(normalizedPoint: CGPoint(x: 0.1, y: 0.1))
        XCTAssertEqual(t.currentStrokeIndex, 1)
        t.update(normalizedPoint: CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(t.currentStrokeIndex, 2)
        t.update(normalizedPoint: CGPoint(x: 0.9, y: 0.9))

        // After completion: currentStrokeIndex == progress.count (out-of-bounds for progress[])
        // Verify all computed properties that use this index are safe in the completed state.
        XCTAssertEqual(t.currentStrokeIndex, 3, "Must return progress.count after all strokes complete")
        XCTAssertTrue(t.isComplete)
        XCTAssertFalse(t.soundEnabled,  "soundEnabled must be false in completed state (no current stroke)")
        XCTAssertEqual(t.overallProgress, 1.0, accuracy: 1e-9, "overallProgress must be 1.0 when complete")
        // Reaching here without crashing verifies soundEnabled doesn't index progress[] with OOB index
    }

    // MARK: 16 — soundEnabled behaviour

    func testSoundEnabled_falseBeforeFirstHit_trueAfter() {
        let t = StrokeTracker()
        let def = letter(strokes: [
            strokeDef(id: 0, checkpoints: [cp(0.2, 0.2), cp(0.8, 0.8)])
        ])
        t.load(def)
        XCTAssertFalse(t.soundEnabled, "soundEnabled false before any checkpoint hit")
        t.update(normalizedPoint: CGPoint(x: 0.2, y: 0.2))
        XCTAssertTrue(t.soundEnabled, "soundEnabled true after first checkpoint hit")
    }

    func testSoundEnabled_resetsOnNewStroke() {
        let t = StrokeTracker()
        let def = letter(strokes: [
            strokeDef(id: 0, checkpoints: [cp(0.1, 0.1)]),
            strokeDef(id: 1, checkpoints: [cp(0.5, 0.5), cp(0.9, 0.9)])
        ])
        t.load(def)

        t.update(normalizedPoint: CGPoint(x: 0.1, y: 0.1)) // complete stroke 0
        // Now on stroke 1, nextCheckpoint == 0 → soundEnabled == false
        XCTAssertFalse(t.soundEnabled, "soundEnabled must reset to false at start of new stroke")
        t.update(normalizedPoint: CGPoint(x: 0.5, y: 0.5))
        XCTAssertTrue(t.soundEnabled)
    }

    // MARK: 17 — update() after isComplete is a no-op

    func testUpdate_afterComplete_isNoOp() {
        let t = StrokeTracker()
        let def = letter(strokes: [strokeDef(id: 0, checkpoints: [cp(0.5, 0.5)])])
        t.load(def)

        t.update(normalizedPoint: CGPoint(x: 0.5, y: 0.5))
        XCTAssertTrue(t.isComplete)
        let progressSnapshot = t.overallProgress

        t.update(normalizedPoint: CGPoint(x: 0.5, y: 0.5))
        t.update(normalizedPoint: CGPoint(x: 0.0, y: 0.0))
        t.update(normalizedPoint: CGPoint(x: 1.0, y: 1.0))

        XCTAssertTrue(t.isComplete)
        XCTAssertEqual(t.overallProgress, progressSnapshot, accuracy: 1e-9)
    }

    // MARK: 18 — load() twice replaces state (reload test)

    func testReload_withDifferentDefinition_resetsState() {
        let t = StrokeTracker()
        let defA = letter("A", strokes: [strokeDef(id: 0, checkpoints: [cp(0.1, 0.1)])])
        t.load(defA)
        completeAll(t, defA)
        XCTAssertTrue(t.isComplete)

        let defB = letter("B", strokes: [
            strokeDef(id: 0, checkpoints: [cp(0.3, 0.3)]),
            strokeDef(id: 1, checkpoints: [cp(0.7, 0.7)])
        ])
        t.load(defB)

        XCTAssertFalse(t.isComplete, "Reloading must reset completion state")
        XCTAssertEqual(t.currentStrokeIndex, 0)
        XCTAssertEqual(t.overallProgress, 0.0, accuracy: 1e-9)
        XCTAssertFalse(t.soundEnabled)
        XCTAssertEqual(t.progress.count, 2, "progress must match new definition's stroke count")
    }

    // MARK: 19 — Fuzz: random points never crash, progress stays in [0,1]

    func testFuzz_randomPoints_neverCrash_progressStaysInRange() {
        var rng = SeededRNG(seed: 0xdeadbeef_cafebabe)
        XCTContext.runActivity(named: "Fuzz seed: 0xdeadbeef_cafebabe") { _ in }

        let t = StrokeTracker()
        let def = letter(radius: 0.1, strokes: [
            strokeDef(id: 0, checkpoints: [cp(0.1, 0.1), cp(0.3, 0.3)]),
            strokeDef(id: 1, checkpoints: [cp(0.5, 0.5), cp(0.7, 0.7)]),
            strokeDef(id: 2, checkpoints: [cp(0.9, 0.9)])
        ])
        t.load(def)

        for _ in 0..<2_000 {
            let x = CGFloat(Double.random(in: 0...1, using: &rng))
            let y = CGFloat(Double.random(in: 0...1, using: &rng))
            t.update(normalizedPoint: CGPoint(x: x, y: y))
            let p = t.overallProgress
            XCTAssertGreaterThanOrEqual(p, 0.0, "overallProgress must not go below 0")
            XCTAssertLessThanOrEqual(p, 1.0,    "overallProgress must not exceed 1")
            XCTAssertFalse(p.isNaN)
            XCTAssertFalse(p.isInfinite)
        }
        // Reaching here without crash is the primary fuzz assertion.
    }

    // MARK: 20 — Fuzz: targeted perturbations eventually drive tracker to completion

    func testFuzz_targetedPerturbations_eventuallyComplete() {
        // Use polar perturbations to guarantee points land inside the circular acceptance radius.
        // Square perturbations (±r, ±r) have corners at distance r*sqrt(2) ≈ 1.41r which is
        // outside the acceptance circle — ~21% of square-generated points would miss.
        var rng = SeededRNG(seed: 0xcafebabe_deadbeef)
        XCTContext.runActivity(named: "Fuzz seed: 0xcafebabe_deadbeef") { _ in }

        let radius: CGFloat = 0.1
        let t = StrokeTracker()
        let def = letter(radius: radius, strokes: [
            strokeDef(id: 0, checkpoints: [cp(0.2, 0.2), cp(0.4, 0.4)]),
            strokeDef(id: 1, checkpoints: [cp(0.6, 0.6), cp(0.8, 0.8)])
        ])
        t.load(def)

        // Feed each checkpoint multiple targeted attempts (polar offset within 95% of radius)
        let attemptsPerCheckpoint = 20
        for stroke in def.strokes {
            for c in stroke.checkpoints {
                for _ in 0..<attemptsPerCheckpoint {
                    let angle = CGFloat(Double.random(in: 0..<(2 * .pi), using: &rng))
                    let dist  = CGFloat(Double.random(in: 0..<(radius * 0.95), using: &rng))
                    let pt = CGPoint(x: c.x + dist * cos(angle), y: c.y + dist * sin(angle))
                    t.update(normalizedPoint: pt)
                    if t.currentStrokeIndex > def.strokes.firstIndex(where: { $0.id == stroke.id }) ?? 0 {
                        break // this stroke's checkpoint advanced; move to next
                    }
                }
            }
        }

        XCTAssertTrue(t.isComplete,
                      "Targeted polar perturbations within radius must eventually complete all strokes")
        XCTAssertEqual(t.overallProgress, 1.0, accuracy: 1e-9)
    }

    // MARK: 22–28 — radiusMultiplier edge cases

    // 22: radiusMultiplier = 0.0 — exact-coordinate hit registers (0.0 ≤ 0.0 per IEEE-754)
    func testRadiusMultiplier_zero_onlyExactHitRegisters() {
        var t = StrokeTracker()
        let def = letter(radius: 0.1, strokes: [strokeDef(id: 1, checkpoints: [cp(0.5, 0.5)])])
        t.load(def)
        t.radiusMultiplier = 0.0

        // hypot(0,0) = 0.0; 0.0 <= 0.1 * 0.0 = 0.0 → true (IEEE-754 ≤)
        t.update(normalizedPoint: CGPoint(x: 0.5, y: 0.5))
        XCTAssertTrue(t.isComplete,
                      "An exact-coordinate hit must still register with radiusMultiplier=0.0 (0.0 ≤ 0.0 per IEEE-754)")
    }

    // 23: radiusMultiplier = 0.0 — near-miss does not register
    func testRadiusMultiplier_zero_nearMissDoesNotRegister() {
        var t = StrokeTracker()
        let def = letter(radius: 0.1, strokes: [strokeDef(id: 1, checkpoints: [cp(0.5, 0.5)])])
        t.load(def)
        t.radiusMultiplier = 0.0

        // dist ≈ 1e-9 > 0.0 → must not register
        t.update(normalizedPoint: CGPoint(x: 0.5 + 1e-9, y: 0.5))
        XCTAssertFalse(t.isComplete,
                       "A point 1e-9 away from the checkpoint must not register with radiusMultiplier=0.0")
        XCTAssertFalse(t.soundEnabled,
                       "soundEnabled must remain false when no checkpoint has been hit")
    }

    // 24: switching multiplier from 0 → 1 mid-stroke — pending checkpoint becomes hittable
    func testRadiusMultiplier_switchFromZeroToOne_pendingCheckpointBecomesHittable() {
        var t = StrokeTracker()
        let def = letter(radius: 0.1, strokes: [strokeDef(id: 1, checkpoints: [cp(0.5, 0.5)])])
        let insidePoint = CGPoint(x: 0.55, y: 0.5) // dist = 0.05 < radius 0.1
        t.load(def)

        // Phase 1: multiplier = 0 → inside point does not register
        t.radiusMultiplier = 0.0
        t.update(normalizedPoint: insidePoint)
        XCTAssertFalse(t.isComplete, "Phase 1: inside point must not register with multiplier=0.0")

        // Phase 2: restore multiplier → same point now registers
        t.radiusMultiplier = 1.0
        t.update(normalizedPoint: insidePoint)
        XCTAssertTrue(t.isComplete, "Phase 2: inside point must register once multiplier is restored to 1.0")
    }

    // 25: radiusMultiplier = 0.0, empty strokes — no crash, trivially complete
    func testRadiusMultiplier_zero_emptyStrokes_noCrash() {
        var t = StrokeTracker()
        let def = letter(radius: 0.1, strokes: [])
        t.load(def)
        t.radiusMultiplier = 0.0
        t.update(normalizedPoint: CGPoint(x: 0.5, y: 0.5))
        XCTAssertTrue(t.isComplete,   "Empty stroke set is trivially complete")
        XCTAssertFalse(t.soundEnabled, "soundEnabled must be false with no checkpoints")
    }

    // 26: negative radiusMultiplier — dist via hypot is always ≥ 0, so dist ≤ negative is false
    func testRadiusMultiplier_negative_exactHitDoesNotRegister() {
        var t = StrokeTracker()
        let def = letter(radius: 0.1, strokes: [strokeDef(id: 1, checkpoints: [cp(0.5, 0.5)])])
        t.load(def)
        t.radiusMultiplier = -0.3

        // dist(cp, cp) = 0.0; 0.0 <= 0.1 * -0.3 = -0.03 → false
        t.update(normalizedPoint: CGPoint(x: 0.5, y: 0.5))
        XCTAssertFalse(t.isComplete,
                       "A negative radiusMultiplier must never match any point — dist via hypot is non-negative")
    }

    // 27: radiusMultiplier = 2.0 — point outside base radius but inside doubled radius registers
    func testRadiusMultiplier_two_enlargedRadiusAcceptsPoint() {
        var t = StrokeTracker()
        let def = letter(radius: 0.1, strokes: [strokeDef(id: 1, checkpoints: [cp(0.5, 0.5)])])
        // dist = 0.15 — outside base radius 0.1, inside 2× radius 0.2
        let outsideBase = CGPoint(x: 0.65, y: 0.5)
        t.load(def)
        t.radiusMultiplier = 2.0

        t.update(normalizedPoint: outsideBase)
        XCTAssertTrue(t.isComplete,
                      "radiusMultiplier=2.0 doubles the acceptance radius; a point at 1.5× the base radius must register")
    }

    // 28: default radiusMultiplier = 1.0 — point exactly at boundary registers (≤ not <)
    func testRadiusMultiplier_default_boundaryPointRegisters() {
        var t = StrokeTracker()
        let radius: CGFloat = 0.1
        let def = letter(radius: radius, strokes: [strokeDef(id: 1, checkpoints: [cp(0.5, 0.5)])])
        // Point exactly at distance == radius (on boundary)
        let boundaryPoint = CGPoint(x: 0.5 + radius, y: 0.5)
        t.load(def)
        t.radiusMultiplier = 1.0

        t.update(normalizedPoint: boundaryPoint)
        XCTAssertTrue(t.isComplete,
                      "A point exactly on the checkpoint radius boundary must register — condition is ≤ not <")
    }
}
