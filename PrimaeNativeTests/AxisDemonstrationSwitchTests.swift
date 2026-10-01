// AxisDemonstrationSwitchTests.swift
// PrimaeNativeTests
//
// Coverage for `StudyComparisonSettings.spatialAxisDemonstration` — the
// ninth comparison switch, which selects between the two spatial-arm
// pre-task demonstrations that exist as of 2026-09-17:
//
//   OFF (default, and the behaviour since 6fb7233c) — the two-second
//       WINDOW alone: the carrier plays at neutral rate, centre pan and
//       zero pitch.
//   ON  — the scripted axis sweep `04-implementation.typ:17` specifies,
//       restored verbatim: a point crossing the full canvas once while
//       pitch follows its vertical leg and pan its horizontal one.
//
// WHY BOTH DIRECTIONS ARE PINNED. The switch's OFF default is a protocol
// divergence, not a neutral choice (see the switch's own doc comment), so
// the difference between the two settings is the whole point of the
// feature. A test of one branch alone would leave the switch free to be
// inert in the other direction — which is exactly the defect class this
// project has shipped twice.
//
// THE GLOBAL-STATE HAZARD, HANDLED DELIBERATELY. `StudyComparisonSettings`
// is `UserDefaults.standard`, and Swift Testing runs suites in PARALLEL. A
// test that writes one of these keys is therefore visible to every other
// test running at that instant, and this project has already measured the
// consequence once (2026-09-17: a font-weight key set by
// `LetterWeightFallbackTests` failed `StrokeGeometryGoldenTests`, a file
// with nothing wrong in it). Two mitigations are used here, both narrow:
//
//   1. `withRestoredComparisonKeys` puts the PREVIOUS values back rather
//      than calling `resetToDefaults()`, so this file cannot clear a key
//      that `StudyComparisonSwitchesTests` is holding live in parallel.
//   2. The promise `armPreTaskDemonstration` makes is read SYNCHRONOUSLY —
//      the switch at init, the sample array at arm time — so the ON test
//      restores the key immediately after arming, leaving it true for
//      microseconds rather than for the length of the demonstration.
//
// The residual window is a few instructions wide. It is not zero, and it is
// recorded here rather than papered over.

import Testing
import Foundation
import CoreGraphics
@testable import PrimaeNative

/// Records the three engine calls the spatial demonstration can make, so
/// "steady window" and "scripted sweep" are distinguishable by COUNT and by
/// RANGE rather than by inspection. `PreTaskDemonstrationTests`' own
/// `RecordingAudio` is `fileprivate` to that file; this is the same shape,
/// extended to keep the pan bias `setAdaptivePlayback` carries — the sweep
/// drives both axes, and a test that recorded only pitch would pass for a
/// sweep whose pan leg had been deleted.
@MainActor
private final class SweepRecordingAudio: AudioControlling {
    var initializationError: String? { nil }
    private(set) var loadedFiles: [String] = []
    private(set) var autoplayFlags: [Bool] = []
    private(set) var speeds: [Float] = []
    private(set) var biases: [Float] = []
    private(set) var pitches: [Float] = []
    private(set) var stopCount = 0
    var isPlaying = false

    func loadAudioFile(named: String, autoplay: Bool) {
        loadedFiles.append(named)
        autoplayFlags.append(autoplay)
        isPlaying = autoplay
    }
    func play()    { isPlaying = true }
    func stop()    { stopCount += 1; isPlaying = false }
    func restart() {}
    func suspendForLifecycle()        { isPlaying = false }
    func resumeAfterLifecycle()       {}
    func cancelPendingLifecycleWork() {}
    func setAdaptivePlayback(speed: Float, horizontalBias: Float) {
        speeds.append(speed)
        biases.append(horizontalBias)
    }
    func setSpatialPitch(cents: Float) { pitches.append(cents) }

    /// Drop everything recorded so far. `TracingViewModel.init` runs
    /// `load(letter:)` for its first (stub) letter, which does its own
    /// unrelated `loadAudioFile(autoplay: false)`. Reset right after
    /// construction so each assertion below reflects only the explicit
    /// `armPreTaskDemonstration` call under test.
    func reset() {
        loadedFiles = []
        autoplayFlags = []
        speeds = []
        biases = []
        pitches = []
        stopCount = 0
        isPlaying = false
    }

    /// The count assertions below are all "how many engine calls did the
    /// demonstration make", and every one of them is a number a wrong
    /// branch would change by an order of magnitude (1 versus ~40).
    var callCount: Int { pitches.count }
}

/// `.serialized` because every test here that touches the switch writes a
/// GLOBAL. Swift Testing would otherwise run them concurrently, and this
/// file would then be the source of the very cross-test interference the
/// header warns about — one test's ON window landing inside another's OFF
/// assertion.
@Suite(.serialized) @MainActor
struct AxisDemonstrationSwitchTests {

    /// Every comparison key, so the restore below is complete. Spelled from
    /// the settings' own key constants rather than by pasting the strings:
    /// a key renamed in the production file must not silently escape the
    /// snapshot.
    private var allComparisonKeys: [String] {
        [StudyComparisonSettings.observePassesKey,
         StudyComparisonSettings.spokenFeedbackKey,
         StudyComparisonSettings.allFiveLettersKey,
         StudyComparisonSettings.letterRepeatCountKey,
         StudyComparisonSettings.cycleAllConditionsKey,
         StudyComparisonSettings.presentationSpacingKey,
         StudyComparisonSettings.guidedDotsVisibleKey,
         StudyComparisonSettings.panningEnabledKey,
         StudyComparisonSettings.spatialAxisDemonstrationKey]
    }

    private func snapshotComparisonKeys() -> [(String, Any?)] {
        allComparisonKeys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
    }

    private func restore(_ snapshot: [(String, Any?)]) {
        for (key, value) in snapshot {
            if let value {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    /// Run a test that writes a comparison key, then put the old values
    /// back. See the file header for why this restores a snapshot instead
    /// of calling `resetToDefaults()`.
    ///
    /// Two spellings rather than one overload pair: an `async`/sync pair
    /// differing only in generic return type is a needless disambiguation
    /// puzzle for the compiler and for the next reader.
    private func withRestoredComparisonKeys<T>(_ body: () -> T) -> T {
        let snapshot = snapshotComparisonKeys()
        defer { restore(snapshot) }
        return body()
    }

    private func withRestoredComparisonKeysAsync<T>(_ body: () async -> T) async -> T {
        let snapshot = snapshotComparisonKeys()
        defer { restore(snapshot) }
        return await body()
    }

    // MARK: - The switch itself

    /// The default is the behaviour that shipped in 6fb7233c. Pinned here
    /// rather than assumed: an untouched study device must keep behaving
    /// exactly as the one the 2026-09-17 device review examined.
    @Test("an untouched key reads OFF — the steady window, not the sweep")
    func defaultIsOff() {
        withRestoredComparisonKeys {
            StudyComparisonSettings.resetToDefaults()
            #expect(StudyComparisonSettings.spatialAxisDemonstration == false,
                    "the switch's default is ON — an untouched device would run a demonstration the 6fb7233c build never ran")
        }
    }

    @Test("the switch round-trips through UserDefaults")
    func roundTrips() {
        withRestoredComparisonKeys {
            StudyComparisonSettings.spatialAxisDemonstration = true
            #expect(StudyComparisonSettings.spatialAxisDemonstration,
                    "writing true did not read back true")

            StudyComparisonSettings.spatialAxisDemonstration = false
            #expect(StudyComparisonSettings.spatialAxisDemonstration == false,
                    "writing false did not read back false")
        }
    }

    /// Without this, a comparison run leaves the device diverging from the
    /// protocol and the next proctor has no way to tell.
    @Test("resetToDefaults clears the switch")
    func resetClearsTheSwitch() {
        withRestoredComparisonKeys {
            StudyComparisonSettings.spatialAxisDemonstration = true
            StudyComparisonSettings.resetToDefaults()
            #expect(StudyComparisonSettings.spatialAxisDemonstration == false,
                    "resetToDefaults left the axis-demonstration switch on — the key is missing from its list")
        }
    }

    // MARK: - OFF: the window alone, unchanged

    /// The behaviour of `main` since 6fb7233c, pinned exactly: ONE adaptive
    /// call at the neutral rate and centre pan, ONE pitch call at zero, and
    /// a single stop when the window ends. This is the branch an untouched
    /// device runs, so it is the one that must not have moved.
    @Test("OFF: the carrier is held steady for the window, then stopped")
    func offPathHoldsTheCarrierSteady() async {
        await withRestoredComparisonKeysAsync {
            StudyComparisonSettings.spatialAxisDemonstration = false
            let audio = SweepRecordingAudio()
            let vm = studySpatialVM(audio: audio)
            audio.reset()

            vm.armPreTaskDemonstration(for: asset(), duration: 0.1)
            await waitUntil { audio.stopCount > 0 }
            try? await Task.sleep(for: .milliseconds(50))

            #expect(audio.loadedFiles == [SpatialSonification.carrierToneFile],
                    "the carrier file is the arm's stimulus in both settings")
            #expect(audio.callCount == 1,
                    "the OFF path made \(audio.callCount) pitch calls — it must hold ONE steady value, not sweep")
            #expect(audio.pitches == [0],
                    "the OFF path must hold pitch at zero, got \(audio.pitches)")
            #expect(audio.biases == [0],
                    "the OFF path must hold pan at the centre, got \(audio.biases)")
            #expect(audio.stopCount == 1,
                    "loadAudioFile(autoplay: true) schedules LOOPING playback — the demonstration must stop the carrier when the window ends")
        }
    }

    // MARK: - ON: the scripted sweep, restored

    /// The sweep, measured by what it does to the engine. `axisSweep` is a
    /// pure function with its own tests (`PreTaskDemonstrationSweepTests`);
    /// what is pinned HERE is the part those cannot see — that the samples
    /// reach `setSpatialPitch`/`setAdaptivePlayback` at all.
    ///
    /// The key is restored immediately after arming. That is safe and not a
    /// trick: the view model reads the switch at INIT and builds the sample
    /// array at ARM time, so by the time
    /// `armPreTaskDemonstration` has returned, nothing downstream reads the
    /// key again. Keeping it true for the length of the demonstration would
    /// hold a global for ~100 ms for no additional evidence.
    @Test("ON: pitch and pan both sweep the full canvas, then the carrier stops")
    func onPathRunsTheScriptedSweep() async {
        await withRestoredComparisonKeysAsync {
            StudyComparisonSettings.spatialAxisDemonstration = true
            let audio = SweepRecordingAudio()
            let vm = studySpatialVM(audio: audio)
            audio.reset()

            vm.armPreTaskDemonstration(for: asset(), duration: 0.1)
            StudyComparisonSettings.spatialAxisDemonstration = false   // see above
            await waitUntil { audio.stopCount > 0 }
            try? await Task.sleep(for: .milliseconds(50))

            #expect(audio.loadedFiles == [SpatialSonification.carrierToneFile],
                    "the sweep must play the arm's own carrier file")
            #expect(audio.callCount > 1,
                    "the ON path made \(audio.callCount) pitch call(s) — the switch is inert and the steady window ran instead")

            // The vertical leg: `pitchCents` maps canvas top to +1200 and
            // bottom to −1200, and `axisSweep` crosses both. Asserting the
            // RANGE, not a particular sample, is what distinguishes a
            // sweep from any other sequence of pitches.
            let pitches = audio.pitches
            if let high = pitches.max(), let low = pitches.min() {
                #expect(high > 1100,
                        "the sweep never reached the top of the canvas (max pitch \(high) cents, expected ~+1200)")
                #expect(low < -1100,
                        "the sweep never reached the bottom of the canvas (min pitch \(low) cents, expected ~−1200)")
            } else {
                Issue.record("no pitch samples recorded at all: \(pitches)")
            }

            // The horizontal leg. Recorded separately from pitch because a
            // restored sweep that had lost its pan would still pass every
            // pitch assertion above.
            let biases = audio.biases
            if let right = biases.max(), let left = biases.min() {
                #expect(right > 0.9,
                        "the sweep never reached the right edge (max pan bias \(right), expected ~+1)")
                #expect(left < -0.9,
                        "the sweep never reached the left edge (min pan bias \(left), expected ~−1)")
            } else {
                Issue.record("no pan samples recorded at all: \(biases)")
            }

            #expect(audio.stopCount == 1,
                    "the sweep's window must end with exactly one stop, got \(audio.stopCount)")
        }
    }

    // MARK: - The two branches are the same LENGTH

    /// Both settings must run the same demonstration window, because the
    /// duration match with the phoneme arm is the one property
    /// `04-implementation.typ:17` and `06-evaluation.typ:62` both rest on —
    /// and it is the property that would break silently if the sweep
    /// returned early or the OFF branch skipped its sleep.
    ///
    /// Measured by WALL CLOCK rather than by engine calls, so neither
    /// branch's call pattern can make it pass vacuously.
    @Test("both settings hold the demonstration open for the full window")
    func bothBranchesSpanTheWindow() async {
        let window: TimeInterval = 0.3

        let offDelay = await stopDelay(on: false, window: window)
        let onDelay  = await stopDelay(on: true, window: window)

        // Only a LOWER bound is asserted: the polling loop adds up to 25 ms
        // of slack on top, and an upper bound tight enough to be meaningful
        // would be a flaky test rather than a stronger one.
        #expect(offDelay >= window * 0.9,
                "the OFF window closed after \(offDelay)s, before its \(window)s duration")
        #expect(onDelay >= window * 0.9,
                "the ON window closed after \(onDelay)s, before its \(window)s duration")
    }

    // MARK: - Cancellation survives on the ON path

    /// The restored sweep carries two `Task.isCancelled` checks per sample.
    /// They are the thing most easily lost in a re-indentation, and without
    /// them a cancelled task does NOT stop: `try? await Task.sleep` returns
    /// as soon as the task is cancelled, so the loop would sprint through
    /// every remaining sample and drive the engine at full speed — over a
    /// real touch, which is precisely what the cancellation exists to
    /// prevent.
    @Test("ON: cancelling mid-sweep stops it within a sample or two")
    func onPathCancellationStopsTheSweep() async {
        await withRestoredComparisonKeysAsync {
            StudyComparisonSettings.spatialAxisDemonstration = true
            let audio = SweepRecordingAudio()
            let vm = studySpatialVM(audio: audio)
            audio.reset()

            // The production duration, so the sweep is long enough to
            // cancel part-way through rather than after it has finished.
            vm.armPreTaskDemonstration(for: asset(), duration: 2.0)
            StudyComparisonSettings.spatialAxisDemonstration = false

            await waitUntil { audio.callCount >= 3 }
            let atCancel = audio.callCount
            #expect(atCancel >= 3, "precondition: the sweep must actually be running")
            #expect(atCancel < PreTaskDemonstration.sweepStepCount,
                    "precondition: the sweep finished before it could be cancelled — this test would then prove nothing")

            vm.cancelPreTaskDemonstration()
            try? await Task.sleep(for: .milliseconds(200))

            // A cancelled `Task.sleep` returns IMMEDIATELY, so if the loop's
            // cancellation checks were gone the remaining ~37 samples would
            // land in a few milliseconds and the count would jump to the
            // full step count. One sample of slack covers the check at the
            // top of the iteration the cancel landed in.
            #expect(audio.callCount <= atCancel + 1,
                    "the sweep kept running after cancelPreTaskDemonstration: \(audio.callCount) samples recorded, \(atCancel) at cancel time")
            #expect(audio.callCount < PreTaskDemonstration.sweepStepCount,
                    "a cancelled demonstration ran to completion (\(audio.callCount) of \(PreTaskDemonstration.sweepStepCount) samples)")
        }
    }

    // MARK: - A demonstration that cannot play is a fault, not a silence

    /// The restored guard, and the one thing about it a test can observe.
    /// `axisSweep` yields no samples when `duration <= 0` — unreachable from
    /// production, whose default duration is 2.0 s, but reachable here.
    ///
    /// What is asserted is the consequence the guard exists for: with ON and
    /// no samples, the arm must produce NO audio at all rather than a
    /// silently-absent demonstration. Note the ordering this pins — the
    /// check runs BEFORE the load, so a fault cannot leave a looping
    /// carrier behind.
    ///
    /// The fault LOG cannot be asserted: `pilotAudioLogger` is an
    /// `os.Logger` with no injection seam, so there is nothing in the test
    /// process that can observe that the fault was recorded. The test pins
    /// the control flow, not the log line; if the `fault(...)` call itself
    /// were deleted and the `return` kept, this test would still pass.
    @Test("ON with no samples: nothing plays, rather than a silent skip")
    func emptySweepProducesNoAudio() async {
        await withRestoredComparisonKeysAsync {
            StudyComparisonSettings.spatialAxisDemonstration = true
            let audio = SweepRecordingAudio()
            let vm = studySpatialVM(audio: audio)
            audio.reset()

            vm.armPreTaskDemonstration(for: asset(), duration: 0)
            StudyComparisonSettings.spatialAxisDemonstration = false
            try? await Task.sleep(for: .milliseconds(150))

            #expect(audio.loadedFiles.isEmpty,
                    "a demonstration with no samples still loaded the carrier — the arm's stimulus would be absent and the session would record as though it had been delivered")
            #expect(audio.stopCount == 0,
                    "nothing was loaded, so nothing should have been stopped")
        }
    }

    // MARK: - Helpers

    /// Wall-clock length of one demonstration window, measured from arm to
    /// the demonstration's own `stop()`. Used by
    /// `bothBranchesSpanTheWindow`.
    private func stopDelay(on: Bool, window: TimeInterval) async -> TimeInterval {
        await withRestoredComparisonKeysAsync {
            StudyComparisonSettings.spatialAxisDemonstration = on
            let audio = SweepRecordingAudio()
            let vm = studySpatialVM(audio: audio)
            audio.reset()
            let armedAt = Date()
            vm.armPreTaskDemonstration(for: asset(), duration: window)
            StudyComparisonSettings.spatialAxisDemonstration = false
            await waitUntil { audio.stopCount > 0 }
            return Date().timeIntervalSince(armedAt)
        }
    }

    private func studySpatialVM(audio: SweepRecordingAudio) -> TracingViewModel {
        TracingViewModel(.stub
            .with(audioCondition: .spatial)
            .with(audio: audio)
            .with(studyMode: true))
    }

    private func asset(_ name: String = "A") -> LetterAsset {
        LetterAsset(
            id: name, name: name,
            audioFiles: ["\(name)_name.mp3"],
            strokes: LetterStrokes(letter: name, checkpointRadius: 0.1, strokes: [
                StrokeDefinition(id: 1, checkpoints: [Checkpoint(x: 0.1, y: 0.1),
                                                      Checkpoint(x: 0.9, y: 0.9)])
            ]),
            phonemeAudioFiles: ["\(name)_phoneme1.mp3"]
        )
    }

    /// Poll up to ~1 s for a condition — the demonstration runs on a real
    /// Task, so its first effect lands a beat after
    /// `armPreTaskDemonstration` returns, not synchronously.
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<40 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }
}
