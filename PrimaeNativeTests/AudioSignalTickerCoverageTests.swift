// Every PHASE-LANDING path must start the audio-measurement ticker.
//
// MEASURED 2026-10-03 on the physical iPad, phoneme arm: the probe log
// held 34 `guided` samples at `peak=0.0` and ZERO `freeWrite` samples.
// The zero-peak guided windows turned out to be correct (guided only
// sounds through the trace coupling, which needs the child to move — and
// that run never drew), but the absent freeWrite samples were an
// INSTRUMENT defect: the ticker hung off two observe-side sites, so a
// session landing directly in freeWrite never started it. "No samples"
// and "genuinely silent" are indistinguishable in the log, which is the
// one distinction this probe exists to draw.
//
// The guard that makes the ticker a production no-op —
// `AudioSignalProbe.isArmedByLaunchArgument` — lives INSIDE
// `AudioEngine`, not at the call site, so a conforming double observes
// every call. That is what makes this testable at all, and it is why the
// spy below needs no launch argument and no timer.

import Testing
import Foundation
@testable import PrimaeNative

/// Counts ticker starts and records the PHASE NAME each one was handed.
///
/// Sampling `label()` at start time is the point: it proves the ticker
/// would have reported *this* phase, not merely that some ticker ran. A
/// count alone would pass on a ticker wired to a constant string.
@MainActor
fileprivate final class TickerCountingAudio: AudioControlling {
    var initializationError: String? { nil }
    private(set) var startedLabels: [String] = []
    private(set) var intervals: [TimeInterval] = []

    func loadAudioFile(named: String, autoplay: Bool) {}
    func play() {}
    func stop() {}
    func restart() {}
    func suspendForLifecycle() {}
    func resumeAfterLifecycle() {}
    func cancelPendingLifecycleWork() {}
    func setAdaptivePlayback(speed: Float, horizontalBias: Float) {}
    func setSpatialPitch(cents: Float) {}

    func startAudioSignalTicker(intervalSeconds: TimeInterval,
                                label: @escaping @MainActor () -> String) {
        intervals.append(intervalSeconds)
        startedLabels.append(label())
        labelProvider = label
    }

    /// The most recent label closure, kept so a test can RE-SAMPLE it.
    ///
    /// The closure is read on every tick, not captured once, so its value
    /// tracks the phase as the session moves. An earlier version of the
    /// invariant test below sampled it only at start time and concluded
    /// `direct` was unreachable — which is what made the fix look
    /// incomplete when it was in fact already covered.
    private(set) var labelProvider: (@MainActor () -> String)?

    /// What the running ticker would label its NEXT window with.
    func currentLabel() -> String? { labelProvider?() }
}

@Suite(.serialized) @MainActor struct AudioSignalTickerCoverageTests {

    /// A study view model on the phoneme arm — the configuration the
    /// 2026-10-03 device measurement ran.
    ///
    /// `studyMode: true` is load-bearing twice over: a study launch is
    /// PARKED, so the init-time `load(letter:)` deliberately starts no
    /// ticker at all, which is what lets each test assert on the count
    /// *change* caused by the landing it drives rather than on a total.
    private func makeVM(
        studyMode: Bool = true,
        thesisCondition: ThesisCondition = .threePhase
    ) -> (TracingViewModel, TickerCountingAudio) {
        let audio = TickerCountingAudio()
        var deps = TracingDependencies.stub
        deps.studyMode = studyMode
        deps.audioCondition = .phoneme
        deps.enablePhonemeMode = true
        deps.thesisCondition = thesisCondition
        deps.audio = audio
        return (TracingViewModel(deps), audio)
    }

    // MARK: - The path that was already working (the positive control)

    /// Without this the other three could all pass against a spy that
    /// never records anything: a broken assertion and a broken instrument
    /// produce the same green.
    @Test("a parked study launch starts no ticker until a phase actually runs")
    func parkedLaunchStartsNothing() {
        let (_, audio) = makeVM()
        #expect(audio.startedLabels.isEmpty,
                "a parked study launch must not start a ticker at init — if it did, every count-based assertion below would be measuring the init call instead of the landing under test")
    }

    @Test("advancing into observe starts the ticker, labelled 'observe'")
    func observeLandingStartsTicker() {
        let (vm, audio) = makeVM()
        vm.startParkedLetter()
        #expect(audio.startedLabels.contains("observe"),
                "the observe landing must start the ticker; got \(audio.startedLabels)")
    }

    // MARK: - The two paths the 2026-10-03 measurement found dark

    /// THE DEFECT. The pretest opens a letter cold in freeWrite
    /// (`StudyLetterSetTests.pretest_trainedLetter_opensColdAndTagged`),
    /// skipping observe and direct entirely — so it reaches the freeWrite
    /// landing branch and none of the observe-side ticker sites. Measured:
    /// zero samples, which reads identically to "silent".
    @Test("a cold pretest landing directly in freeWrite starts the ticker")
    func coldProbeFreeWriteLandingStartsTicker() {
        let (vm, audio) = makeVM()
        let before = audio.startedLabels.count

        vm.startColdProbe(letter: "A", kind: .pretest)

        #expect(vm.phaseController.currentPhase == .freeWrite,
                "the fixture must actually land in freeWrite, or this test is asserting the ticker on some other phase's landing")
        #expect(audio.startedLabels.count > before,
                "landing directly in freeWrite must start the ticker; got \(audio.startedLabels)")
        #expect(audio.startedLabels.last == "freeWrite",
                "the ticker must be labelled with the phase it is measuring, or the log attributes samples to the wrong phase; got \(audio.startedLabels)")
    }

    /// The same omission on the guided landing branch, reached the way the
    /// branch is actually reached.
    ///
    /// Two dead ends avoided here, both recorded because each looks like
    /// the obvious approach:
    ///
    ///   - `resume(at: .guided)` cannot deliver a load into guided:
    ///     `load(letter:)` calls `phaseController.reset()` first, so any
    ///     resume is overwritten before the landing branch is read.
    ///   - `deps.thesisCondition = .guidedOnly` cannot do it in STUDY mode:
    ///     `TracingViewModel:1149` reads
    ///     `deps.studyMode ? .threePhase : deps.thesisCondition`, so study
    ///     mode pins the script and the override is discarded.
    ///
    /// So this uses a non-study `guidedOnly` session, where
    /// `LearningPhaseController.reset()` itself lands on guided. The
    /// landing branch under test is mode-independent — it is reached by
    /// whatever phase the load lands in, and reads nothing from `studyMode`.
    /// In study mode the same branch is reached when a letter's empty
    /// strokes auto-skip observe and direct, which is the same landing.
    @Test("a landing directly in guided starts the ticker")
    func guidedLandingStartsTicker() {
        let (vm, audio) = makeVM(studyMode: false, thesisCondition: .guidedOnly)

        #expect(vm.phaseController.currentPhase == .guided,
                "the fixture must actually land in guided; got \(vm.phaseController.currentPhase.rawName)")
        #expect(audio.startedLabels.last == "guided",
                "landing directly in guided must start the ticker, labelled 'guided'; got \(audio.startedLabels)")
    }

    // MARK: - The properties that make the above hold as the app changes

    /// A running ticker FOLLOWS the session, so a phase needs no landing
    /// site of its own once one has been started.
    ///
    /// This is what keeps the fix small: three sites cover every phase
    /// thereafter, and `direct` in particular has none — it is measured by
    /// the ticker observe started, because the label closure is re-read on
    /// every tick rather than captured at start. Worth pinning explicitly,
    /// because "add a site per phase" and "start one ticker and let it
    /// follow" are both defensible readings of the code and only one of
    /// them is what it does.
    @Test("a running ticker follows the session into later phases")
    func runningTickerFollowsTheSession() {
        let (vm, audio) = makeVM()
        vm.startParkedLetter()
        #expect(audio.currentLabel() == "observe",
                "the ticker starts in observe; got \(String(describing: audio.currentLabel()))")

        vm.phaseController.advance(score: 1.0)

        // `guided`, not `direct`: the session runs THREE phases (D5) and
        // `direct` is retained for Codable only, never active
        // (`LearningPhase`). An earlier version of this test asserted
        // `direct` and failed — correctly, because the phase it named
        // cannot occur. `LearningPhase.allCases` is for the same reason
        // the wrong basis for a coverage invariant: it includes a phase
        // no session can reach.
        #expect(vm.phaseController.currentPhase == .guided,
                "the fixture must actually advance to guided; got \(vm.phaseController.currentPhase.rawName)")
        #expect(audio.currentLabel() == "guided",
                "the ticker must re-read the phase on every tick, or a phase entered mid-session is never labelled; got \(String(describing: audio.currentLabel()))")
    }

    /// `direct` is reachable in no session, so it can be measured by
    /// nothing. Pinned because an earlier invariant test demanded coverage
    /// for every `allCases` member and so demanded the impossible.
    @Test("'direct' is never an active phase, so it is not a coverage obligation")
    func directIsNotActive() {
        let (vm, _) = makeVM()
        var seen: Set<LearningPhase> = []
        var phase = vm.phaseController.currentPhase
        seen.insert(phase)
        while let next = phase.next, vm.phaseController.advance(score: 1.0) {
            phase = vm.phaseController.currentPhase
            seen.insert(phase)
            if seen.contains(.freeWrite) { break }
        }
        #expect(!seen.contains(.direct),
                "if 'direct' ever becomes active again it needs its own measurement, and this test must be revisited then; saw \(seen.map(\.rawName))")
    }

    /// The regression this file exists to prevent is a way for a session to
    /// BEGIN that starts no ticker — after which the WHOLE session is
    /// unmeasured, not just its first phase. Pinning today's entry shapes
    /// would not catch a new one; pinning the invariant would.
    ///
    /// Phrased over entry shapes rather than phases, deliberately. The
    /// phase set is covered by `runningTickerFollowsTheSession` plus the
    /// three tests above; what can actually go dark is a session that never
    /// starts the ticker at all, and that is an entry-point property.
    @Test("every way a session can begin starts the measurement ticker")
    func everySessionEntryStartsTheTicker() {
        // 1. The ordinary study launch: parked at init, running once the
        //    proctor starts the letter.
        let observeStarted: [String] = {
            let (vm, audio) = makeVM()
            vm.startParkedLetter()
            return audio.startedLabels
        }()

        // 2. The H6 cold pretest, which opens a letter straight into the
        //    unassisted trial. THE ONE THAT WAS DARK.
        let pretestStarted: [String] = {
            let (vm, audio) = makeVM()
            vm.startColdProbe(letter: "A", kind: .pretest)
            return audio.startedLabels
        }()

        // 3. A session whose script opens straight into guided.
        let guidedStarted: [String] = {
            let (_, audio) = makeVM(studyMode: false, thesisCondition: .guidedOnly)
            return audio.startedLabels
        }()

        #expect(observeStarted.contains("observe"),
                "a study session must begin measuring at observe; got \(observeStarted)")
        #expect(pretestStarted.contains("freeWrite"),
                "a cold pretest must begin measuring at freeWrite — no ticker means the whole probe session reports nothing, which is indistinguishable from silence; got \(pretestStarted)")
        #expect(guidedStarted.contains("guided"),
                "a guided-opening session must begin measuring at guided; got \(guidedStarted)")
    }

    /// The ticker drives a repeating timer, so its interval is a real
    /// parameter rather than a detail: too short and every phase is
    /// dominated by timer overhead, too long and a short phase yields no
    /// sample at all — which is the original freeWrite symptom in a
    /// slower form.
    @Test("the ticker samples faster than the shortest phase it must cover")
    func tickerIntervalIsShortEnoughToCoverAPhase() {
        let (vm, audio) = makeVM()
        vm.startParkedLetter()
        #expect(audio.intervals.first == 2.0,
                "the probe's 2 s window is what produced the 34-sample guided time series; changing it changes what a phase can be shown to contain. Got \(audio.intervals)")
    }
}
