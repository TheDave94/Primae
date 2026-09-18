// OncePerConditionTests.swift
// PrimaeNativeTests
//
// Coverage for `StudyComparisonSettings.oncePerCondition` — the tenth
// comparison switch, and the one that implements the supervisor's note
// "Einmal pro Kondition".
//
// WHAT THE NOTE WAS READ AS, AND WHY. The pre-task sound demonstration is
// the only behaviour in the app whose content IS the audio condition and
// which runs once per LETTER: `armPreTaskDemonstration` is armed from
// `load(letter:)`'s observe and direct-to-guided entries, so every letter
// a child meets is preceded by it. The other per-letter repetitions are
// not condition-specific (the ghost-letter animation is identical in all
// three arms; the per-touch coupling is the arm's manipulation, not a
// demonstration of it), and the two per-condition decisions the review
// also raised already have switches of their own (`cycleAllConditions`,
// `letterRepeatCount`). So "einmal pro Kondition" has exactly one
// referent in the code. ON delivers the demonstration at the first
// letter loaded in each condition and on no later letter in it; OFF —
// the default, and every build before this switch — is unchanged.
//
// WHY BOTH DIRECTIONS ARE PINNED. OFF is the default, so OFF is what an
// untouched study device runs and the branch that must not have moved.
// ON is the new behaviour, and it is the one that can be inert: a guard
// that never fires, a ledger that is never written, or one written on
// entry instead of at the arming point all leave a green suite behind.
//
// THE ONE TEST THAT MATTERS MOST is
// `onReArmsForANewConditionButNotForTheSameOne`. "Once per condition" is
// NOT "once per session": with `cycleAllConditions` ON, each arm must
// still get its own demonstration. An implementation that fired only at
// the session's first letter would satisfy every other test in this file
// and would be wrong.
//
// HOW THE SWITCH IS DRIVEN. Through `TracingDependencies.oncePerCondition`
// — the seam `cycleAllConditions` uses — so no test that exercises
// BEHAVIOUR writes a key a parallel suite can observe. Swift Testing runs
// suites in PARALLEL and this project has already been broken once by
// exactly that (a font-weight key set by `LetterWeightFallbackTests`
// failing `StrokeGeometryGoldenTests`). The storage tests at the bottom
// are the exception and are confined to this file's own key: they
// snapshot and restore `oncePerConditionKey` alone, and deliberately do
// NOT call `resetToDefaults()`, which would clear nine keys a parallel
// suite may be holding live.
//
// THE RESET TEST WRITES PARTICIPANT GLOBALS and says so. Pinning
// "the next child is not denied the demonstration the last one used up"
// means driving `resetForNewParticipant`, which mints a participant UUID
// and clears the researcher overrides. It is the same call
// `NewParticipantResetTests` already drives, with the same
// snapshot-and-restore discipline; the residual window is real and is
// recorded here rather than papered over. Skipping it was the
// alternative, and a production line no test can fail on is worse.
//
// WHAT THESE TESTS CANNOT SEE. Whether sound leaves the speaker — the
// same caveat `SilentArmAuthorityTests` and `CycleAllConditionsTests`
// carry. "Did the demonstration arm" is measured as an engine load that
// only a demonstration can make (`loadAudioFile(autoplay: true)`), which
// is the strongest in-process evidence available.

import Testing
import Foundation
import CoreGraphics
@testable import PrimaeNative

/// Records every engine load with its `autoplay` flag, because that flag
/// is what separates a DEMONSTRATION from the ordinary letter load that
/// `load(letter:)` also performs. `load(letter:)`'s own
/// `loadAudioFile(autoplay: false)` is present in every session; a
/// demonstration is the only thing in these fixtures that passes `true`.
@MainActor
private final class DemoRecordingAudio: AudioControlling {
    var initializationError: String? { nil }
    private(set) var loads: [(file: String, autoplay: Bool)] = []
    private(set) var stopCount = 0
    var isPlaying = false

    func loadAudioFile(named: String, autoplay: Bool) {
        loads.append((named, autoplay))
        isPlaying = autoplay
    }
    func play()    { isPlaying = true }
    func stop()    { stopCount += 1; isPlaying = false }
    func restart() {}
    func setAdaptivePlayback(speed: Float, horizontalBias: Float) {}
    func setSpatialPitch(cents: Float) {}
    func suspendForLifecycle()        { isPlaying = false }
    func resumeAfterLifecycle()       {}
    func cancelPendingLifecycleWork() {}

    /// The demonstration loads observed so far, as the file names only.
    var demonstrationFiles: [String] { loads.filter(\.autoplay).map(\.file) }
    var demonstrationCount: Int { loads.filter(\.autoplay).count }
}

@Suite(.serialized) @MainActor
struct OncePerConditionTests {

    // MARK: - The two directions

    /// OFF — the default and everything the app did before this switch.
    /// Driven with THREE DIFFERENT letters, because that is the
    /// production shape: `load(letter:)` calls this once per letter, and
    /// the demonstration's content follows the letter in the phoneme arm.
    @Test("OFF: every letter load gets its own demonstration")
    func offDemonstratesEveryLetter() async {
        let audio = DemoRecordingAudio()
        let vm = studyVM(audio: audio, once: false)

        // One `settle()` per arm call, not one after the loop:
        // `armPreTaskDemonstration` cancels the PREVIOUS task on entry, and
        // a task that has not yet had a scheduler turn is cancelled before
        // it ever runs its load (the phoneme branch's own `isCancelled`
        // guard exists for exactly that). Arming three in a row without
        // yielding would leave only the third letter's demonstration for
        // this test to find — a fixture artefact, not the behaviour.
        for name in ["A", "F", "I"] {
            vm.armPreTaskDemonstration(for: asset(name), duration: 0.05)
            await settle()
        }

        #expect(audio.demonstrationFiles.count == 3,
                "OFF must arm a demonstration on every letter load — got \(audio.demonstrationFiles)")
        #expect(audio.demonstrationFiles.map { ($0 as NSString).lastPathComponent }
                == ["A_phoneme1.mp3", "F_phoneme1.mp3", "I_phoneme1.mp3"],
                "OFF must deliver each LETTER's own phoneme, not the first letter's: \(audio.demonstrationFiles)")
    }

    /// ON — the switch's whole point. The first letter of the condition
    /// carries the demonstration; no later letter in that condition does.
    @Test("ON: the condition's demonstration fires once and not again")
    func onDemonstratesOncePerCondition() async {
        let audio = DemoRecordingAudio()
        let vm = studyVM(audio: audio, once: true)

        vm.armPreTaskDemonstration(for: asset("A"), duration: 0.05)
        await settle()
        #expect(audio.demonstrationCount == 1,
                "positive control: the FIRST letter of the condition must still be demonstrated — got \(audio.demonstrationFiles)")

        for name in ["F", "I", "L"] {
            vm.armPreTaskDemonstration(for: asset(name), duration: 0.05)
            await settle()
        }

        #expect(audio.demonstrationCount == 1,
                "ON must not demonstrate later letters of the same condition — got \(audio.demonstrationFiles)")
        #expect(audio.demonstrationFiles.map { ($0 as NSString).lastPathComponent } == ["A_phoneme1.mp3"],
                "the surviving demonstration must be the FIRST letter's, not a later one: \(audio.demonstrationFiles)")
    }

    /// "Once per CONDITION", not "once per session" — the distinction the
    /// switch's name carries and the one a plausible wrong implementation
    /// (`if demonstratedAnything { return }`) would lose.
    ///
    /// The walk is phoneme → spatial → silent → phoneme → spatial, i.e.
    /// exactly the order `cycleAllConditions` steps through. Silent is
    /// checked for the property it has always had rather than for this
    /// switch: it adds no audio by construction, so there is nothing for
    /// the ledger to suppress.
    @Test("ON: a new condition is demonstrated, a repeated one is not")
    func onReArmsForANewConditionButNotForTheSameOne() async {
        let audio = DemoRecordingAudio()
        let vm = studyVM(audio: audio, once: true, arm: .phoneme)

        vm.armPreTaskDemonstration(for: asset("A"), duration: 0.05)
        await settle()
        #expect(audio.demonstrationCount == 1,
                "positive control: the launch condition must be demonstrated — got \(audio.demonstrationFiles)")

        vm.applyArm(.spatial)
        vm.armPreTaskDemonstration(for: asset("F"), duration: 0.05)
        await settle()
        #expect(audio.demonstrationCount == 2,
                "the SECOND condition must get its own demonstration — ON is per condition, not per session: \(audio.demonstrationFiles)")
        #expect(audio.demonstrationFiles.last == SpatialSonification.carrierToneFile,
                "the second demonstration must be the spatial arm's carrier, not a repeat of the phoneme: \(audio.demonstrationFiles)")

        vm.applyArm(.silent)
        vm.armPreTaskDemonstration(for: asset("I"), duration: 0.05)
        await settle()
        #expect(audio.demonstrationCount == 2,
                "the silent arm must stay silent — it adds no audio in either setting: \(audio.demonstrationFiles)")

        vm.applyArm(.phoneme)
        vm.armPreTaskDemonstration(for: asset("L"), duration: 0.05)
        await settle()
        #expect(audio.demonstrationCount == 2,
                "returning to an ALREADY-demonstrated condition re-armed it — the ledger is keyed on something coarser than the condition: \(audio.demonstrationFiles)")

        vm.applyArm(.spatial)
        vm.armPreTaskDemonstration(for: asset("M"), duration: 0.05)
        await settle()
        #expect(audio.demonstrationCount == 2,
                "the spatial condition was already demonstrated and re-armed: \(audio.demonstrationFiles)")
    }

    /// The ledger is written where the demonstration is ARMED, not on
    /// entry to `armPreTaskDemonstration`. A letter whose phoneme file is
    /// missing takes the branch's fault path and returns WITHOUT arming;
    /// if the ledger were written on entry, that fault would consume the
    /// condition's one demonstration and every later letter in the arm
    /// would be silent without a trace of why.
    ///
    /// The fault itself is unreachable from production — the phoneme
    /// precondition refuses such a session first — so what is pinned here
    /// is the placement of the write, which is the part that could be
    /// put in the wrong place.
    @Test("ON: a faulting demonstration does not consume the condition")
    func onFaultingDemonstrationDoesNotConsumeTheCondition() async {
        let audio = DemoRecordingAudio()
        let vm = studyVM(audio: audio, once: true)

        // No phoneme files: `activeAudioFiles` returns [] under study
        // mode and the branch logs a fault and returns before arming.
        vm.armPreTaskDemonstration(for: assetWithoutPhoneme("M"), duration: 0.05)
        await settle()
        #expect(audio.demonstrationCount == 0,
                "precondition: a letter with no phoneme cannot be demonstrated — got \(audio.demonstrationFiles)")

        // The arm must still be unspent.
        vm.armPreTaskDemonstration(for: asset("A"), duration: 0.05)
        await settle()
        #expect(audio.demonstrationCount == 1,
                "the faulting letter consumed the condition's demonstration — a real letter in the same arm would then run with no demonstration at all: \(audio.demonstrationFiles)")
    }

    /// studyMode OFF (the casual app) must not reach the ledger at all.
    ///
    /// THE FIRST `settle()` IS LOAD-BEARING, and its absence was measured
    /// (2026-09-18). `TracingViewModel.init` calls `load(letter:)`, which
    /// arms the demonstration, so a session that wrongly armed one has
    /// already done it before this test's first line. The explicit call
    /// below cancels `preTaskDemoTask` on entry — production behaviour —
    /// so without a window here the wrongly-armed demonstration is
    /// cancelled before its load ever reaches the engine, and the test
    /// passes on the exact defect it exists to catch. MEASURED: with the
    /// `guard studyMode` removed from `armPreTaskDemonstration` (the one
    /// mutation this test is supposed to police), the run still reported
    /// `demonstrationCount == 0` and this row stayed green; a probe on the
    /// function entry showed the init call arming at `ledger=0` and every
    /// later call returning at `ledger=1`. With the window below, that
    /// same mutation fails this test at the first expectation.
    @Test("outside study mode the switch changes nothing")
    func casualSessionsIgnoreTheSwitch() async {
        let audio = DemoRecordingAudio()
        var deps = TracingDependencies.stub
        deps.studyMode = false
        deps.oncePerCondition = true
        let vm = TracingViewModel(deps.with(audio: audio))

        await settle()
        #expect(audio.demonstrationCount == 0,
                "the demonstration is pilot-only; a casual session must arm nothing at init — got \(audio.demonstrationFiles)")

        for name in ["A", "F", "I"] {
            vm.armPreTaskDemonstration(for: asset(name), duration: 0.05)
            await settle()
        }

        #expect(audio.demonstrationCount == 0,
                "the demonstration is pilot-only; a casual session must arm nothing in either setting — got \(audio.demonstrationFiles)")
    }

    // MARK: - The session boundary

    /// The ledger is per SESSION. The proctor enrols the next child without
    /// relaunching the app (`resetForNewParticipant`, 2026-09-14), so
    /// without a clear the outgoing child's used-up conditions would
    /// silently deny the incoming child their demonstration — a
    /// data-validity problem rather than a cosmetic one, since for the
    /// spatial arm the demonstration is where the mapping is installed.
    ///
    /// The arm is forced back to `.phoneme` after the reset so the
    /// assertion does not depend on which arm the fresh UUID drew: with
    /// the ledger surviving, `.phoneme` is still in it and the final call
    /// arms nothing.
    @Test("a newly enrolled participant gets the demonstration again")
    func newParticipantStartsWithAnEmptyLedger() async {
        await withRestoredParticipantStateAsync {
            let audio = DemoRecordingAudio()
            let vm = studyVM(audio: audio, once: true, arm: .phoneme)

            vm.armPreTaskDemonstration(for: asset("A"), duration: 0.05)
            await settle()
            #expect(audio.demonstrationCount == 1,
                    "positive control: the outgoing child's condition is demonstrated — got \(audio.demonstrationFiles)")
            vm.armPreTaskDemonstration(for: asset("F"), duration: 0.05)
            await settle()
            #expect(audio.demonstrationCount == 1,
                    "positive control: the guard is live before the reset — got \(audio.demonstrationFiles)")

            _ = vm.resetForNewParticipant()
            vm.applyArm(.phoneme)
            vm.armPreTaskDemonstration(for: asset("I"), duration: 0.05)
            await settle()

            #expect(audio.demonstrationCount == 2,
                    "the incoming child inherited the outgoing child's used-up conditions — with ON that child's whole session runs with no demonstration: \(audio.demonstrationFiles)")
        }
    }

    // MARK: - Storage (the only tests here that write a global)

    /// OFF when the key has never been written — the property that makes
    /// the switch safe on an enrolled study device. Only THIS file's key
    /// is touched: `resetToDefaults()` would clear nine keys a parallel
    /// suite may be holding live.
    @Test("an untouched key reads OFF")
    func defaultIsOff() {
        withRestoredKey {
            UserDefaults.standard.removeObject(forKey: StudyComparisonSettings.oncePerConditionKey)
            #expect(StudyComparisonSettings.oncePerCondition == false,
                    "the switch's default is ON — an untouched device would stop demonstrating after the first letter of each arm")
        }
    }

    @Test("the switch round-trips through UserDefaults")
    func roundTrips() {
        withRestoredKey {
            StudyComparisonSettings.oncePerCondition = true
            #expect(StudyComparisonSettings.oncePerCondition,
                    "writing true did not read back true")
            StudyComparisonSettings.oncePerCondition = false
            #expect(StudyComparisonSettings.oncePerCondition == false,
                    "writing false did not read back false")
        }
    }

    /// The view model reads the switch from the dependency it was built
    /// with, not from the global key at use time. The key is set ON while
    /// a session built with the seam OFF runs: OFF is what that session
    /// must do. A view model that read the key live — the shape
    /// `axisDemonstrationEnabled` has — would fail this, which is the
    /// difference the seam exists for.
    @Test("the switch is captured at init through the dependency, not read live from the key")
    func seamIsCapturedAtInitNotReadLive() async {
        await withRestoredKeyAsync {
            StudyComparisonSettings.oncePerCondition = true
            let audio = DemoRecordingAudio()
            let vm = studyVM(audio: audio, once: false)

            for name in ["A", "F"] {
                vm.armPreTaskDemonstration(for: asset(name), duration: 0.05)
                await settle()
            }

            #expect(audio.demonstrationCount == 2,
                    "the view model read the global key instead of the dependency it was built with — a session pinned OFF behaved ON: \(audio.demonstrationFiles)")
        }
    }

    // MARK: - Helpers

    /// The production flow under test: a study session, the given arm,
    /// and the demonstration switch on or off.
    private func studyVM(audio: DemoRecordingAudio,
                         once: Bool,
                         arm: PilotAudioCondition = .phoneme) -> TracingViewModel {
        var deps = TracingDependencies.stub
        deps.studyMode = true
        deps.audioCondition = arm
        deps.oncePerCondition = once
        return TracingViewModel(deps.with(audio: audio))
    }

    private func asset(_ name: String) -> LetterAsset {
        LetterAsset(id: name, name: name, baseLetter: name, letterCase: .upper,
                    audioFiles: ["\(name).mp3"],
                    strokes: LetterStrokes(letter: name, checkpointRadius: 0.1, strokes: []),
                    phonemeAudioFiles: ["\(name)_phoneme1.mp3"])
    }

    private func assetWithoutPhoneme(_ name: String) -> LetterAsset {
        LetterAsset(id: name, name: name, baseLetter: name, letterCase: .upper,
                    audioFiles: ["\(name).mp3"],
                    strokes: LetterStrokes(letter: name, checkpointRadius: 0.1, strokes: []),
                    phonemeAudioFiles: [])
    }

    /// The demonstration runs on a real Task, so its load lands a beat
    /// after `armPreTaskDemonstration` returns. Same shape as
    /// `AxisDemonstrationSwitchTests`' poll, with a floor: the poll waits
    /// for at least one full scheduling window even when the count has
    /// already reached its target, so a NEGATIVE assertion later in the
    /// same test cannot pass merely because the task has not run yet.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(120))
    }

    /// Snapshot and restore the switch's own key around a test that writes
    /// it. Deliberately not `resetToDefaults()` — see the file header.
    private func withRestoredKey<T>(_ body: () -> T) -> T {
        let previous = UserDefaults.standard.object(forKey: StudyComparisonSettings.oncePerConditionKey)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: StudyComparisonSettings.oncePerConditionKey)
            } else {
                UserDefaults.standard.removeObject(forKey: StudyComparisonSettings.oncePerConditionKey)
            }
        }
        return body()
    }

    private func withRestoredKeyAsync<T>(_ body: () async -> T) async -> T {
        let previous = UserDefaults.standard.object(forKey: StudyComparisonSettings.oncePerConditionKey)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: StudyComparisonSettings.oncePerConditionKey)
            } else {
                UserDefaults.standard.removeObject(forKey: StudyComparisonSettings.oncePerConditionKey)
            }
        }
        return await body()
    }

    /// Participant identity is global, and `resetForNewParticipant` mints
    /// a new UUID and clears the researcher overrides. Restored here the
    /// same way `NewParticipantResetTests` restores it, because the test
    /// that drives that call cannot assert anything if the device is left
    /// pointing at a synthetic participant.
    private func withRestoredParticipantStateAsync<T>(_ body: () async -> T) async -> T {
        let conditionOverride = ParticipantStore.conditionOverride
        let audioOverride     = ParticipantStore.audioConditionOverride
        let enrolled          = ParticipantStore.isEnrolled
        defer {
            ParticipantStore.conditionOverride = conditionOverride
            ParticipantStore.audioConditionOverride = audioOverride
            ParticipantStore.isEnrolled = enrolled
        }
        return await body()
    }
}
