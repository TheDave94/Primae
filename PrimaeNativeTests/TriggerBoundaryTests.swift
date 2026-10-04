// TriggerBoundaryTests.swift
// PrimaeNativeTests
//
// Coverage for the supervisor's "Trigger boundaries" (2026-09-17) — the
// last of that review's notes to get an implementation, and the two
// comparison switches it added to `StudyComparisonSettings`.
//
// WHAT IS BEING PINNED. The arm's sound starts when TWO independent gates
// agree: the finger is near the letter (`StrokeTracker.isNearStroke`,
// `StrokeTracker.swift:100`) AND the finger is moving
// (`TouchDispatcher.swift:381-384`). Both constants were bare literals,
// neither was named, visible or switchable. The switches move each one
// independently — two switches rather than one because the gates are
// ANDed, so a run that moved both at once could not attribute what
// changed.
//
// WHY THE ASSERTIONS ARE SHAPED THIS WAY. A switch that writes a
// `UserDefaults` key and is then never read again is the exact failure
// this project has already shipped once (`cycleAllConditions` sat
// `.disabled(true)` for a day). So nothing here asserts that a key was
// written. Every test drives a PRODUCTION CONSUMER and asserts what the
// child would hear:
//
//   * test 1 asserts the gate itself, on `StrokeTracker` directly;
//   * test 2 asserts the factor survives a grid rebuild — cells are
//     rebuilt on every letter, so a value written onto a tracker in place
//     is discarded at the next letter, which is what "inert after the
//     first letter" looks like from the inside;
//   * tests 3-5 assert `audio.playCount` through the real
//     `beginTouch`/`updateTouch` path;
//   * test 6 asserts the boundaries are captured at init, so a proctor
//     cannot move the trigger under a child mid-session.
//
// NO GLOBAL `UserDefaults` STATE IS WRITTEN OR ASSERTED ANYWHERE IN THIS
// FILE. Swift Testing runs suites in PARALLEL and this suite has been broken
// once already by a test that flipped a global key another suite then read
// (`LetterWeightFallbackTests` → `StrokeGeometryGoldenTests`). Both switches
// are therefore injected through `TracingDependencies` — the seam
// `cycleAllConditions` uses — and `TracingDependencies.stub` pins them
// explicitly, so the default arguments (which DO read the keys) are never
// evaluated by any test fixture. `resetToDefaults()` coverage for these two
// keys lives in `StudyComparisonSwitchesTests.resetRestoresDefaults`, beside
// the other nine; that is the only place the keys are touched.

import Testing
import Foundation
import CoreGraphics
@testable import PrimaeNative

@MainActor
private final class CountingAudio: AudioControlling {
    var initializationError: String? { nil }
    private(set) var playCount = 0
    /// Whether the engine is running RIGHT NOW. `playCount > 0` cannot
    /// answer this — it cannot distinguish "never played" from "played,
    /// then stopped", which is the whole question the stall-timeout test
    /// asks.
    private(set) var isPlaying = false
    func loadAudioFile(named fileName: String, autoplay: Bool) {}
    func setAdaptivePlayback(speed: Float, horizontalBias: Float) {}
    func play()    { playCount += 1; isPlaying = true }
    func stop()    { isPlaying = false }
    func restart() {}
    func suspendForLifecycle()        { isPlaying = false }
    func resumeAfterLifecycle()       {}
    func cancelPendingLifecycleWork() {}
}

@Suite(.serialized) @MainActor
struct TriggerBoundaryTests {

    private let canvas = CGSize(width: 400, height: 400)

    /// A study-shaped VM whose two trigger boundaries come from the deps
    /// seam, never from the keys. The playback controller is built with an
    /// instantly-resuming sleeper so the debounce tail settles on the next
    /// runloop tick instead of on wall-clock time.
    private func makeVM(radiusFactor: Double,
                        velocityFloor: Double) -> (vm: TracingViewModel, audio: CountingAudio) {
        let audio = CountingAudio()
        var deps = TracingDependencies.stub.with(audio: audio)
        deps.soundGateRadiusFactor  = radiusFactor
        deps.soundGateVelocityFloor = velocityFloor
        deps.makePlaybackController = { audio, cb in
            PlaybackController(audio: audio, sleep: { _ in }, onIsPlayingChanged: cb)
        }
        return (TracingViewModel(deps), audio)
    }

    // MARK: - The gate itself

    /// The factor moves `isNearStroke` (the sound gate) and leaves the HIT
    /// boundary untouched. `checkpointRadius` 0.1, one checkpoint at
    /// (0.2, 0.5), finger 0.2 away: outside a 1× gate of 0.1, inside a 3×
    /// gate of 0.3 — and in neither case is the checkpoint consumed, which
    /// is the half of the claim that says the factor must not make the
    /// letter easier or harder to trace.
    @Test("the radius factor opens the sound gate without moving the hit boundary")
    func factorMovesTheGateNotTheHitBoundary() {
        func probe(factor: CGFloat, at distance: CGFloat)
            -> (nearStroke: Bool, checkpointsConsumed: Int) {
            let tracker = StrokeTracker()
            tracker.load(LetterStrokes(
                letter: "T",
                checkpointRadius: 0.1,
                strokes: [StrokeDefinition(id: 1, checkpoints: [
                    Checkpoint(x: 0.2, y: 0.5),
                    Checkpoint(x: 0.9, y: 0.5)     // a second one, so consumption is observable
                ])]
            ))
            tracker.soundGateRadiusFactor = factor
            tracker.update(normalizedPoint: CGPoint(x: 0.2 + distance, y: 0.5))
            return (tracker.isNearStroke, tracker.progress[0].nextCheckpoint)
        }

        let tight = probe(factor: 1.0, at: 0.2)
        #expect(tight.nearStroke == false,
                "0.2 from the checkpoint is outside a 1× gate of 0.1 — the factor is not reaching `isNearStroke`")
        #expect(tight.checkpointsConsumed == 0,
                "0.2 is outside the hit radius and must not consume the checkpoint")

        let wide = probe(factor: 3.0, at: 0.2)
        #expect(wide.nearStroke,
                "0.2 from the checkpoint is inside a 3× gate of 0.3 — the default does not open the gate")
        #expect(wide.checkpointsConsumed == 0,
                "the factor consumed the checkpoint at 0.2 — it widened the HIT boundary, which it must not")

        // And with the finger actually on the checkpoint, BOTH settings
        // consume it: the gate's width is the only thing the factor moves.
        let onTheInk = probe(factor: 1.0, at: 0.05)
        #expect(onTheInk.nearStroke && onTheInk.checkpointsConsumed == 1,
                "0.05 is inside the hit radius and must both open the gate and consume the checkpoint at either factor")
    }

    // MARK: - The switch reaches the running session

    /// `deps.soundGateRadiusFactor` must land on the cells' trackers AND
    /// survive a rebuild. Cells are rebuilt from scratch on every
    /// `grid.load` — every letter, every preset flip — so a value written
    /// onto a tracker in place would be silently discarded at the next
    /// letter. That is what an inert switch looks like from the inside,
    /// and it is why the value lives on the grid rather than on a tracker.
    @Test("the radius factor reaches every cell and survives a grid rebuild")
    func factorReachesEveryCellAndSurvivesARebuild() {
        let (vm, _) = makeVM(radiusFactor: 1.0, velocityFloor: 22)

        #expect(vm.strokeTracker.soundGateRadiusFactor == 1.0,
                "the session's active tracker does not carry the injected factor — the switch reached nothing")

        // The production rebuild path, invoked directly.
        vm.grid.load(sequence: .singleLetter("A"), preset: .finger)

        #expect(vm.gridCells.isEmpty == false, "precondition: the rebuild must have produced cells")
        #expect(vm.gridCells.allSatisfy { $0.tracker.soundGateRadiusFactor == 1.0 },
                "a rebuilt cell fell back to the built-in 3× — the switch is inert from the second letter onward")
        #expect(vm.strokeTracker.soundGateRadiusFactor == 1.0,
                "the ACTIVE cell after the rebuild does not carry the factor")
    }

    // MARK: - The gates are audible

    /// The factor, end to end: the same gesture, the same finger position,
    /// two settings, and a different answer to "does the child hear the
    /// letter". The finger is placed strictly between the hit radius and
    /// the 3× gate, so only the gate's width decides.
    ///
    /// Without this test the factor is pinned only on a tracker the
    /// production path might never configure — the failure mode is a
    /// switch that is wired to the right object and still changes nothing
    /// anyone can hear.
    @Test("the radius factor changes whether the letter is audible")
    func factorIsAudible() {
        func plays(factor: Double) -> Bool {
            let (vm, audio) = makeVM(radiusFactor: factor, velocityFloor: 22)
            vm.canvasSize = canvas

            guard let definition = vm.strokeTracker.definition,
                  definition.strokes.isEmpty == false,
                  definition.strokes[0].checkpoints.isEmpty == false else {
                return false
            }
            let frame = vm.grid.activeCell.frame
            let hit   = definition.checkpointRadius * vm.strokeTracker.radiusMultiplier
            let first = definition.strokes[0].checkpoints[0]
            // Inside 3×hit, outside 1×hit, and still on the canvas.
            let distance = min(2 * hit, 0.95)
            guard hit > 0, distance > hit, distance <= 3 * hit,
                  first.x + distance <= 1.0 else { return false }

            let start  = CGPoint(x: frame.minX + first.x * frame.width,
                                 y: frame.minY + first.y * frame.height)
            let target = CGPoint(x: frame.minX + (first.x + distance) * frame.width,
                                 y: start.y)
            guard target.x <= canvas.width, target.y <= canvas.height else { return false }

            vm.beginTouch(at: start, t: 1000.0)
            vm.updateTouch(at: target, t: 1000.001, canvasSize: canvas)   // fast: the velocity gate is not the variable here
            return audio.playCount > 0
        }

        #expect(plays(factor: 3.0),
                "with the default 3× gate a finger between the hit radius and the gate must hear the letter")
        #expect(plays(factor: 1.0) == false,
                "with a 1× gate the same finger position must be silent — the factor is not reaching the sound path")
    }

    /// The velocity floor, end to end, in both directions — and the
    /// DEFAULT MOVED (2026-10-04, proctor: "guided should be audible
    /// too"). At 22 pt/s this was the gate that BINDS: along the stroke
    /// the radius gate is satisfied with a 10.8× margin (largest
    /// checkpoint gap in any study letter is 0.0278 against the 0.3
    /// default gate), so a child tracing correctly heard the letter or
    /// not according to THIS number alone — and a 5-6 year-old tracing
    /// deliberately is slow. The default is 0.0 now, so the same slow
    /// finger is audible and the floor is the re-introduction knob a
    /// comparison run moves deliberately.
    @Test("the velocity floor decides whether a slow deliberate trace is audible")
    func velocityFloorIsAudible() {
        /// One trace at a stated speed, sampled five times `dt` apart. `dt`
        /// is part of the speed and not decoration: the finger advances
        /// `pointsPerSecond * dt` per sample, and `TouchDispatcher` derives
        /// velocity as `distance / dt`, so the same step at a different `dt`
        /// is a different speed. The 1.5 pt minimum-move filter does NOT
        /// gate that derivation (it only gates `activePath`), which is why a
        /// 1 pt step is a legitimate slow trace rather than a dropped one.
        func plays(floor: Double, pointsPerSecond: CGFloat, dt: CFTimeInterval) -> Bool {
            let (vm, audio) = makeVM(radiusFactor: 3.0, velocityFloor: floor)
            vm.canvasSize = canvas
            vm.beginTouch(at: CGPoint(x: 100, y: 200), t: 1000.0)
            var t: CFTimeInterval = 1000.0
            var p = CGPoint(x: 100, y: 200)
            for _ in 0..<5 {
                t += dt
                p.x += pointsPerSecond * CGFloat(dt)
                vm.updateTouch(at: p, t: t, canvasSize: canvas)
            }
            return audio.playCount > 0
        }

        // Slow: 1 pt per 1 s sample = 1 pt/s, below the OLD 22 pt/s default.
        #expect(plays(floor: 22, pointsPerSecond: 1, dt: 1) == false,
                "a 1 pt/s finger is below a 22 pt/s floor and must stay silent — the floor is not reaching the sound path")
        #expect(plays(floor: 0, pointsPerSecond: 1, dt: 1),
                "with the floor at 0 the same 1 pt/s finger must be audible — this is the DEFAULT since 2026-10-04, the state that makes a slow tracing child audible")
        // Fast: 10 pt per 1 ms sample = 10000 pt/s, the speed
        // `EndToEndTracingSessionTests.simulateFastTouch` drives.
        #expect(plays(floor: 20000, pointsPerSecond: 10000, dt: 0.001) == false,
                "a 10000 pt/s trace must be silent under a 20000 pt/s floor — raising the floor has no effect")
        #expect(plays(floor: 0, pointsPerSecond: 10000, dt: 0.001),
                "the same 10000 pt/s trace must be audible at the 0 pt/s default floor")
    }

    // MARK: - Session properties, not live values

    /// A comparison switch must not be able to change the trigger under a
    /// child mid-session: the session must run the values it was BUILT
    /// with, not whatever the global key happens to say later.
    ///
    /// Deliberately writes NO key, which is the difference between this
    /// version and the obvious one. The obvious shape sets the two keys
    /// after init and asserts the session did not move; but the keys are
    /// global, Swift Testing runs suites in PARALLEL, and a write here
    /// lands inside `StudyComparisonSwitchesTests.resetRestoresDefaults`'
    /// reset-then-assert window in that same target — which is precisely
    /// how `LetterWeightFallbackTests` broke `StrokeGeometryGoldenTests`.
    /// Instead the session is built with values that DIFFER from the
    /// defaults (1.0 / 33 against 3.0 / 22) while the globals are left
    /// untouched. A view model that read the global at any later point
    /// answers 3.0 / 22 here and fails; a view model that honours its
    /// captured dependencies answers 1.0 / 33. Same mutation caught, no
    /// global written, nothing to race.
    @Test("both trigger boundaries are the values the session was built with")
    func boundariesAreCapturedAtInit() {
        let (vm, _) = makeVM(radiusFactor: 1.0, velocityFloor: 33)

        #expect(vm.touchDispatcher.playbackActivationVelocityThreshold == 33,
                "the velocity floor is not the injected 33 — the boundary was read from the global, not captured at init")
        #expect(vm.strokeTracker.soundGateRadiusFactor == 1.0,
                "the radius factor is not the injected 1.0 — the sound gate was read from the global, not captured at init")
        #expect(vm.gridCells.allSatisfy { $0.tracker.soundGateRadiusFactor == 1.0 },
                "a cell carries the global's 3.0 rather than the injected 1.0 — the boundary is read live somewhere")
    }

    /// The radius default must be the value the app ran before the
    /// switches existed, or adding them to an enrolled study device would
    /// change what that device does. Asserted on the named constants —
    /// which `StrokeTracker`, `TouchDispatcher` and
    /// `SequenceGridController` all take their own defaults from — rather
    /// than on a `UserDefaults` read, so this cannot be disturbed by a
    /// parallel suite writing the key.
    ///
    /// The velocity default is the ONE that is deliberately not "the
    /// shipped value": 22 → 0 on 2026-10-04, on the proctor's instruction
    /// that guided must be audible to a child who is tracing. It is
    /// asserted explicitly below because a silent change to THIS number
    /// is exactly the kind of protocol change that would otherwise reach
    /// an enrolled device unnoticed.
    @Test("the default boundary values are the intended ones")
    func defaultsAreTheShippedValues() {
        #expect(StudyComparisonSettings.soundGateRadiusFactorDefault == 3.0,
                "the default sound-gate reach is not the 3.0 the tracker was hardcoded to")
        #expect(StudyComparisonSettings.soundGateVelocityFloorDefault == 0,
                "the default velocity floor is not 0 pt/s — a moving finger on the letter is audible at any speed since 2026-10-04, and restoring 22 here would re-silence the slow tracers this change exists for")

        let tracker = StrokeTracker()
        #expect(tracker.soundGateRadiusFactor == 3.0,
                "a fresh tracker does not start at the shipped 3.0")

        let grid = SequenceGridController(sequence: .singleLetter("A"), preset: .finger)
        #expect(grid.cells.allSatisfy { $0.tracker.soundGateRadiusFactor == 3.0 },
                "a fresh grid does not start every cell at the shipped 3.0")
    }

    // MARK: - The guided pass is audible to a child who is tracing

    /// THE DEFECT, in the shape the proctor reported it (2026-10-04,
    /// "guided should be audible too"). A guided session's ONLY sound is
    /// the trace coupling, so if the coupling is gated the whole phase is
    /// silent. It was gated on speed at 22 pt/s — and the radius gate is
    /// saturated along the stroke, so a child tracing CORRECTLY and
    /// DELIBERATELY, which is what a 5-6 year-old does, heard nothing at
    /// all for the phase whose entire purpose is guided tracing.
    ///
    /// This drives a study VM in the real `beginTouch`/`updateTouch` path
    /// in `.guided`, at a deliberately slow speed, and asserts the arm's
    /// sound was REQUESTED. Both sound arms, because the arms must stay
    /// matched (§2.6) — a fix that made only one audible would be a
    /// confound, not a fix.
    @Test("a slow deliberate guided trace is audible in both sound arms",
          arguments: [PilotAudioCondition.phoneme, .spatial])
    func slowGuidedTrace_isAudible(arm: PilotAudioCondition) async {
        let audio = CountingAudio()
        let vm = guidedStudyVM(arm: arm, audio: audio)
        driveSlowTraceOnTheLetter(vm)
        await vm.awaitPlaybackDebounce()
        #expect(audio.playCount > 0,
                "\(arm): a child tracing deliberately slowly must still hear the letter in the guided phase — this is the 'guided should be audible too' defect")
    }

    /// The control that gives the test above its meaning: the SILENT arm
    /// stays silent through the identical drive. Without it, "the guided
    /// phase has sound" could be satisfied by a change that simply plays
    /// always — which would destroy the arm contrast the study rests on.
    @Test("the silent arm stays silent through the same slow guided trace")
    func silentArm_staysSilentOnASlowGuidedTrace() async {
        let audio = CountingAudio()
        let vm = guidedStudyVM(arm: .silent, audio: audio)
        driveSlowTraceOnTheLetter(vm)
        await vm.awaitPlaybackDebounce()
        #expect(audio.playCount == 0,
                "the silent arm's condition IS the absence of sound — audibility in guided must not reach it")
    }

    /// THE OTHER HALF, and the one that says the change did not simply
    /// switch the sound on. Movement-contingency is preserved NOT by the
    /// velocity floor (now 0) but by the stall timeout: a pen that STOPS
    /// sends no samples, so it must fall quiet. If a held finger kept the
    /// loop running, the arm's sound would become an ambient drone over
    /// the whole guided phase and the coupling would no longer encode
    /// the manipulation at all.
    ///
    /// The instant sleeper makes the debounce fire as soon as awaited, so
    /// this asserts the timeout rather than wall-clock luck.
    @Test("a guided finger that stops going quiet still stops the sound")
    func stoppedFinger_stillFallsSilent() async {
        let audio = CountingAudio()
        let vm = guidedStudyVM(arm: .phoneme, audio: audio)
        driveSlowTraceOnTheLetter(vm)
        // Assert the arming BEFORE draining it. `awaitPlaybackDebounce`
        // awaits the very task this test is about, so awaiting it first
        // (as a first version of this test did) CONSUMES the timer and
        // makes the assertion vacuously false — the same "the instrument
        // measured nothing" shape as the freeWrite probe defect.
        #expect(audio.playCount > 0,
                "precondition: the moving finger must be audible before the stall question means anything")
        #expect(vm.playback.pendingTransition != nil,
                "an active sample must arm the stall timeout — without it a held finger drones on for the whole guided phase")
        await vm.playback.pendingTransition?.value
        #expect(audio.isPlaying == false,
                "a pen that stops sends no samples and must fall silent — the velocity floor is no longer what guarantees this")
    }

    /// A study-shaped VM sitting in `.guided`, wired to the counting
    /// engine, with an instantly-resolving sleeper so debounces settle
    /// on the next runloop tick instead of on wall-clock time.
    private func guidedStudyVM(arm: PilotAudioCondition,
                               audio: AudioControlling) -> TracingViewModel {
        var deps = TracingDependencies.stub.with(audio: audio)
        deps.audioCondition = arm
        deps.studyMode = true
        deps.makePlaybackController = { a, cb in
            PlaybackController(audio: a, sleep: { _ in }, onIsPlayingChanged: cb)
        }
        let vm = TracingViewModel(deps)
        vm.canvasSize = canvas
        vm.phaseController.resume(at: .guided)
        return vm
    }

    /// A DELIBERATELY SLOW trace that stays ON the letter — the gesture
    /// this change is about. Points step 1 pt per 1 s sample (1 pt/s,
    /// against the old 22 pt/s floor) along a horizontal line through the
    /// letter's first checkpoint row, so `isNearStroke` is satisfied and
    /// the only variable is speed.
    ///
    /// Laid out from the letter definition rather than from a literal
    /// coordinate: a hand-picked y that happens to fall near a checkpoint
    /// would make this test pass or fail for a reason that has nothing
    /// to do with the velocity gate.
    private func driveSlowTraceOnTheLetter(_ vm: TracingViewModel) {
        guard let definition = vm.strokeTracker.definition,
              definition.strokes.isEmpty == false,
              definition.strokes[0].checkpoints.isEmpty == false else { return }
        let frame = vm.grid.activeCell.frame
        let first = definition.strokes[0].checkpoints[0]
        let y = frame.minY + first.y * frame.height
        var t: CFTimeInterval = 1000.0
        var p = CGPoint(x: frame.minX + first.x * frame.width, y: y)
        vm.beginTouch(at: p, t: t)
        // A short run so the finger never leaves the 3x gate around the
        // checkpoint it started on, while still producing several
        // samples — enough for the smoothed velocity to settle.
        for _ in 0..<5 {
            t += 1.0
            p.x += 1
            vm.updateTouch(at: p, t: t, canvasSize: canvas)
        }
    }
}
