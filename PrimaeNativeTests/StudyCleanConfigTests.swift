// Pins the studyMode "clean study configuration" (audit C1–C4 + A/E):
// silenced non-arm audio + haptics, gated rewards/adaptation/retry,
// pinned device settings, letter-tagged durations, and the trained-3
// practice pool. A studyMode session must be identical across arms
// except the arm's designated sound.

import Testing
import Foundation
import CoreGraphics
@testable import PrimaeNative

// Recording speech spy — proves the VM never routes to the injected
// synthesizer under studyMode (the silencing happens at the injection
// seam, so the spy must stay untouched).
@MainActor
fileprivate final class SpySpeech: SpeechSynthesizing {
    private(set) var spoken: [String] = []
    func speak(_ text: String) { spoken.append(text) }
    func stop() {}
}

@MainActor
fileprivate final class SpyPromptPlayer: PromptPlaying {
    private(set) var plays = 0
    /// WHICH prompts, not just how many. A bare count cannot distinguish
    /// the end-of-set celebration from the phase-entry narration that
    /// legitimately plays several times per session.
    private(set) var keys: [PromptPlayer.PromptKey] = []
    func play(_ key: PromptPlayer.PromptKey, fallbackText: String) {
        plays += 1
        keys.append(key)
    }
    var celebrations: Int { keys.filter { $0 == .celebration }.count }
    private(set) var chimes = 0
    func stop() {}
    func playSuccessChime() { plays += 1; chimes += 1 }
    func playTapChime() { plays += 1 }
    func playWrongTapChime() { plays += 1 }
    func playStrokeTick() { plays += 1 }
}

@MainActor
fileprivate final class SpyHaptics: HapticEngineProviding {
    private(set) var fires = 0
    func prepare() {}
    func fire(_ event: HapticEvent) { fires += 1 }
}

// Records dashboard calls so the retry gate and stamping are observable.
@MainActor
fileprivate final class RecordingDashboardStore: ParentDashboardStoring {
    var snapshot: DashboardSnapshot { DashboardSnapshot() }
    private(set) var sessionCalls: [(letter: String, duration: TimeInterval)] = []
    private(set) var phaseCalls: [(letter: String, phase: String, completed: Bool, score: Double,
                                   trainedSubset: String?, phaseDurationSeconds: Double?,
                                   spatialDeviation: Double?, rawTraceID: UUID?, studyMode: Bool?, probe: String?)] = []
    func recordSession(letter: String, accuracy: Double,
                       durationSeconds: TimeInterval,
                       wallClockSeconds: TimeInterval?,
                       date: Date, condition: ThesisCondition,
                       inputDevice: String?) {
        sessionCalls.append((letter, durationSeconds))
    }
    func recordPhaseSession(letter: String, phase: String, completed: Bool, score: Double, schedulerPriority: Double, condition: ThesisCondition, audioCondition: PilotAudioCondition, assessment: WritingAssessment?, recognition: RecognitionSample?, inputDevice: String?, rawTraceID: UUID?, trainedSubset: String?, phaseDurationSeconds: Double?, frechetDistance: Double?, checkpointCoverage: Double?, spatialDeviation: Double?, strokeCount: Int?, strokeOrder: String?, reversedStrokeCount: Int?, studyMode: Bool?, probe: String?, comparisonConfiguration: String?) {
        phaseCalls.append((letter, phase, completed, score, trainedSubset, phaseDurationSeconds,
                           spatialDeviation, rawTraceID, studyMode, probe))
    }
    func reset() {}
}

@Suite(.serialized) @MainActor struct StudyCleanConfigTests {

    // Nil defaults (not `= SpySpeech()`): default-argument expressions
    // evaluate in a nonisolated context, which can't call the spies'
    // @MainActor inits under the test target's Swift 5 mode.
    private func studyDeps(spySpeech: SpySpeech? = nil,
                           spyPrompts: SpyPromptPlayer? = nil,
                           spyHaptics: SpyHaptics? = nil) -> TracingDependencies {
        var deps = TracingDependencies.stub
        deps.studyMode = true
        deps.speech = spySpeech ?? SpySpeech()
        let prompts = spyPrompts ?? SpyPromptPlayer()
        deps.makePromptPlayer = { _ in prompts }
        deps.haptics = spyHaptics ?? SpyHaptics()
        return deps
    }

    // MARK: - C1: silencing at the injection seam

    /// Haptics stay nulled in study mode unconditionally — that is not
    /// switchable and never was.
    @Test("studyMode swaps haptics for a null implementation")
    func studyMode_injectsNullHaptics() {
        let vm = TracingViewModel(studyDeps())
        #expect(vm.haptics is NullHapticEngine,
                "studyMode must silence haptics at the injection seam")
    }

    /// Speech and prompts are governed by ONE rule with two inputs:
    /// the silent arm always silences them, and study mode silences them
    /// only while `spokenFeedbackInStudy` is off.
    ///
    /// This test USED to assert only "studyMode → null", which was true
    /// while the switch defaulted OFF. MEASURED: the default is now ON
    /// (David's decision, 2026-10-02 — at OFF the phase prompts never
    /// reached a child), so the old assertion failed while the CODE was
    /// behaving exactly as designed. Asserting both positions of the
    /// switch keeps the test true either way, which is what a rule test
    /// should do.
    @Test("studyMode speech/prompts follow spokenFeedbackInStudy, in both positions")
    func studyMode_speechFollowsTheSwitch() {
        // Switch ON: the child's phase prompts must reach them. Pinned
        // through the dependency seam, never by writing UserDefaults —
        // see `TracingDependencies.spokenFeedbackInStudy`.
        var onDeps = studyDeps()
        onDeps.spokenFeedbackInStudy = true
        let audible = TracingViewModel(onDeps)
        #expect(!(audible.speech is NullSpeechSynthesizer),
                "with spoken feedback ON the study session must not null TTS - that silence is the proctor's complaint")
        #expect(!(audible.prompts is NullPromptPlayer),
                "with spoken feedback ON the study session must not null prompts")

        // Switch OFF: the thesis behaviour, for a comparison run.
        var offDeps = studyDeps()
        offDeps.spokenFeedbackInStudy = false
        let silenced = TracingViewModel(offDeps)
        #expect(silenced.speech is NullSpeechSynthesizer,
                "with spoken feedback OFF, studyMode must silence TTS at the injection seam")
        #expect(silenced.prompts is NullPromptPlayer,
                "with spoken feedback OFF, studyMode must silence prompt MP3s/chimes")
    }

    /// The silent arm's authority is NOT a preference and no switch may
    /// put SONIFICATION into it (C3-2) — this holds with spoken feedback
    /// ON. What changed on 2026-10-04 (P3) is the voiceover: speech is not
    /// sonification, so the silent arm now hears the same spoken content
    /// as the other two arms.
    @Test("the silent arm gets the study voiceover, and no sonification, with spoken feedback ON")
    func silentArm_ignoresTheSpokenFeedbackSwitch() {
        var deps = studyDeps()
        deps.spokenFeedbackInStudy = true
        deps.audioCondition = .silent
        let vm = TracingViewModel(deps)
        #expect(vm.audio is SilentAudio,
                "the silent arm's condition IS that writing makes no sound")
        #expect(vm.prompts is StudyVoiceoverPromptPlayer,
                "the silent arm must hear the same voiceover as the sound arms")
        #expect(!(vm.speech is NullSpeechSynthesizer),
                "the voiceover's speech must reach the silent arm")
    }

    @Test("studyMode session drives zero calls into the injected feedback spies")
    func studyMode_spiesStaySilent() {
        let speech = SpySpeech(); let prompts = SpyPromptPlayer(); let haptics = SpyHaptics()
        let vm = TracingViewModel(studyDeps(spySpeech: speech, spyPrompts: prompts, spyHaptics: haptics))
        // Drive a touch sequence (would fire stroke haptics/ticks and,
        // out of bounds, retry TTS in normal mode).
        let t0: CFTimeInterval = 1000
        vm.beginTouch(at: CGPoint(x: 50, y: 200), t: t0)
        var t = t0
        var p = CGPoint(x: 50, y: 200)
        for _ in 0..<15 { t += 0.001; p.x += 10; vm.updateTouch(at: p, t: t, canvasSize: CGSize(width: 400, height: 400)) }
        vm.endTouch()
        #expect(speech.spoken.isEmpty, "no TTS in a study session — got \(speech.spoken)")
        #expect(prompts.plays == 0, "no prompt/chime/tick audio in a study session")
        #expect(haptics.fires == 0, "no haptics in a study session")
    }

    @Test("non-studyMode keeps the injected speech/prompt/haptic implementations")
    func normalMode_keepsInjected() {
        let speech = SpySpeech()
        var deps = TracingDependencies.stub
        deps.speech = speech
        deps.studyMode = false
        let vm = TracingViewModel(deps)
        #expect((vm.speech as? SpySpeech) === speech,
                "non-study sessions must not silently swap the speech seam")
    }

    // MARK: - C3: adaptation + retry gates

    @Test("studyMode pins difficulty to FixedAdaptationPolicy at the standard tier")
    func studyMode_fixesDifficulty() {
        let vm = TracingViewModel(studyDeps())
        #expect(vm.adaptationPolicy is FixedAdaptationPolicy)
        #expect(vm.adaptationPolicy.currentTier == .standard)
    }

    @Test("studyMode: confident-wrong recognition celebrates (records) instead of retrying")
    func studyMode_neverRetries() {
        let store = RecordingDashboardStore()
        let vm = TracingViewModel(studyDeps().with(dashboardStore: store))
        let confidentWrong = RecognitionResult(predictedLetter: "X",
                                               confidence: 0.95,
                                               topThree: [], isCorrect: false)
        vm.phaseTransitions.completePostFreeWriteRecognition(score: 0.5, result: confidentWrong)
        #expect(!store.sessionCalls.isEmpty,
                "studyMode must complete (record) rather than force a retry")
    }

    @Test("non-studyMode: confident-wrong recognition still retries (behavior preserved)")
    func normalMode_stillRetries() {
        let store = RecordingDashboardStore()
        var deps = TracingDependencies.stub.with(dashboardStore: store)
        deps.studyMode = false
        let vm = TracingViewModel(deps)
        _ = vm
        let confidentWrong = RecognitionResult(predictedLetter: "X",
                                               confidence: 0.95,
                                               topThree: [], isCorrect: false)
        vm.phaseTransitions.completePostFreeWriteRecognition(score: 0.5, result: confidentWrong)
        #expect(store.sessionCalls.isEmpty,
                "outside studyMode the confident-wrong retry gate must keep firing")
    }

    // MARK: - C2: reward-class UI/overlays stay off

    @Test("studyMode: completing recognition enqueues no overlays (no KP, badge, celebration)")
    func studyMode_noOverlays() {
        let vm = TracingViewModel(studyDeps())
        let goodResult = RecognitionResult(predictedLetter: vm.currentLetterName,
                                           confidence: 0.95,
                                           topThree: [], isCorrect: true)
        vm.phaseTransitions.completePostFreeWriteRecognition(score: 0.9, result: goodResult)
        #expect(vm.overlayQueue.currentOverlay == nil,
                "study sessions must end trials with no overlay feedback")
    }

    /// The one celebration a study session DOES show, and the guard on it.
    ///
    /// A one-letter practice pool must not celebrate at all: every letter
    /// would be "the last one", turning the single end-of-set signal
    /// into the per-letter reward the C2 ruling suppresses.
    @Test("a one-letter pool never reports the end of a set")
    func oneLetterPool_isNeverEndOfSet() {
        let vm = TracingViewModel(studyDeps())
        #expect(vm.visibleLetterNames.count == 1,
                "this test is only meaningful with a single-letter pool; got \(vm.visibleLetterNames)")
        #expect(!vm.isLastLetterOfSet,
                "a one-letter pool must not report the end of a set - every trial would celebrate, the per-letter reward C2 forbids")
    }

    // MARK: - The celebration guard, REACHABLE (closed 2026-10-03)

    /// A `LetterResourceProviding` that narrows the real bundle to a named
    /// set of letters. Everything below stays the shipped geometry and
    /// the shipped audio - only the POOL is reduced, which is what the
    /// celebration guard is about.
    ///
    /// This is the seam the end-of-set notes said was missing. It is not:
    /// `TracingDependencies.repo` takes a `LetterRepository`, and
    /// `LetterRepository.init(resources:)` already takes a
    /// `LetterResourceProviding`. So the fixture that made every
    /// celebration test unreachable - one that returned exactly one
    /// letter - was a fixture problem, not an architectural wall.
    fileprivate struct LetterSubsetProvider: LetterResourceProviding {
        private let base: BundleLetterResourceProvider
        private let letters: Set<String>

        init(letters: Set<String>) {
            self.base = BundleLetterResourceProvider()
            self.letters = letters
        }

        var bundle: Bundle { base.bundle }
        var searchBundles: [Bundle] { base.searchBundles }

        func allResourceURLs() -> [URL] {
            base.allResourceURLs().filter { url in
                letters.contains { letter in
                    url.path.contains("/" + letter + "/")
                }
            }
        }

        func resourceURL(for relativePath: String) -> URL? {
            base.resourceURL(for: relativePath)
        }
    }

    /// The CoreML recognizer, stubbed. It is not incidental: `advance()`
    /// DEFERS freeWrite completion to the recognizer's async return, so a
    /// synchronous test can never reach `recordSessionCompletion` and the
    /// celebration can never be observed. Stubbing it is what makes the
    /// end of a set testable at all.
    fileprivate struct StubRecognizer: LetterRecognizerProtocol {
        func recognize(points: [CGPoint], strokeStartIndices: [Int],
                       canvasSize: CGSize, expectedLetter: String?,
                       historicalFormScores: [CGFloat]) async -> RecognitionResult? { nil }
        func isModelAvailable() async -> Bool { true }
    }

    private func settle() async {
        try? await Task.sleep(for: .milliseconds(150))
    }

    /// A study session over a MULTI-letter pool, which is the only shape
    /// in which an end of a set exists at all.
    private func multiLetterDeps(spyPrompts: SpyPromptPlayer? = nil) -> TracingDependencies {
        var deps = studyDeps(spyPrompts: spyPrompts)
        // Pinned at the study default (ON) through the seam, so a parallel
        // suite's write to the global key cannot swap the voiceover out.
        deps.spokenFeedbackInStudy = true
        deps.letterRecognizer = StubRecognizer()
        deps.repo = LetterRepository(
            resources: LetterSubsetProvider(letters: ["A", "F", "I"]),
            // No cache and no UserDefaults: this fixture must read the
            // pool off the bundle it was handed, not off whatever a
            // parallel suite persisted.
            cache: NullLetterCache(),
            userDefaults: UserDefaults(suiteName: "celebration-fixture") ?? .standard
        )
        return deps
    }

    /// The positive half of the pair the one-letter test could not have:
    /// with a real pool, the guard DOES become true on the final letter.
    /// Without this the celebration branch had exactly one reader in the
    /// whole suite and it was the negative one, so the branch could be
    /// dead code with 1064 tests green.
    @Test("a multi-letter pool reports the end of a set only on its last letter")
    func multiLetterPool_isEndOfSetOnlyOnLastLetter() {
        let vm = TracingViewModel(multiLetterDeps())
        let pool = vm.visibleLetterNames
        #expect(pool.count > 1,
                "this test is meaningless with a single-letter pool; got \(pool)")

        guard let first = pool.first, let last = pool.last else { return }

        vm.loadLetter(name: first)
        #expect(!vm.isLastLetterOfSet,
                "\(first) is not the last of \(pool), so the end-of-set guard must stay closed - otherwise every trial celebrates, which is the per-letter reward C2 forbids")

        vm.loadLetter(name: last)
        #expect(vm.isLastLetterOfSet,
                "\(last) IS the last of \(pool), so the end-of-set celebration is unreachable if this is false - that is the proctor-reported 'no end congratulations' defect, and this test is what finally reaches it")
    }

    /// The PROCTOR'S ACTUAL COMPLAINT, asserted end to end. The guard
    /// test above only proves the branch is reachable; this drives the
    /// session to completion and proves the celebration the proctor said
    /// they never saw really fires, hands the device back, and fires
    /// once.
    ///
    /// Three advances are the whole three-phase session: observe ->
    /// guided, guided -> freeWrite, freeWrite -> completion, and the last
    /// one is what calls `recordSessionCompletion()`.
    ///
    /// What it asserts is what a STUDY build DELIVERS, per arm: the spoken
    /// phrase in every arm, the chime in the sound arms only, the hand-over
    /// hold — and nothing drawn. The overlay queue holding `.celebration`
    /// is NOT evidence that anything is shown: a study build renders it as
    /// `EmptyView()` (see `noCelebrationViewInAStudyBuild`).
    @Test("the end of the child's set: spoken in every arm, chimed in the sound arms, nothing drawn",
          arguments: [PilotAudioCondition.phoneme, .spatial, .silent])
    func endOfSet_celebratesOnceAndHandsTheDeviceBack(arm: PilotAudioCondition) async {
        let prompts = SpyPromptPlayer()
        var deps = multiLetterDeps(spyPrompts: prompts)
        deps.audioCondition = arm
        let vm = TracingViewModel(deps)
        guard let last = vm.visibleLetterNames.last else { return }
        vm.loadLetter(name: last)

        #expect(!vm.awaitingNextParticipant,
                "the set cannot be over before the last letter is finished")

        // observe -> guided -> freeWrite, then freeWrite DEFERRED to the
        // recognizer, which is why this test awaits at all.
        vm.advanceLearningPhase()
        vm.advanceLearningPhase()
        vm.advanceLearningPhase()
        await settle()

        #expect(vm.awaitingNextParticipant,
                "finishing the child's LAST letter must hand the device back to the proctor - this is the 'no end congratulations' report, and without it a proctor running 30-40 children has no signal that a child is finished")

        // Nothing drawn: this suite compiles under STUDY_BUILD, where
        // `SchuleWorldView` renders the queued `.celebration` as
        // `EmptyView()`. Pinned in `noCelebrationViewInAStudyBuild`; the
        // queue state is not asserted here because it is not what the
        // child sees.

        // The spoken "Super gemacht!" is spoken content, so EVERY arm hears
        // it (P3, David 2026-10-04: spoken content identical across arms).
        // The chime is sound, so only the sound arms hear it.
        let expectedChimes = arm == .silent ? 0 : 1
        #expect(prompts.celebrations == 1,
                "\(arm): the end-of-set celebration is the one study moment carrying this spoken phrase; got \(prompts.celebrations) of them alongside \(prompts.keys)")
        #expect(prompts.chimes == expectedChimes,
                "\(arm): the end-of-set chime is sound — sound arms only; got \(prompts.chimes)")

        // ...and it is a ONCE-per-set signal, not a per-letter reward.
        vm.advanceLearningPhase()
        await settle()
        #expect(prompts.celebrations == 1,
                "\(arm): a completed letter session must not be advanced again - the celebration is ONE per set, and it just fired \(prompts.celebrations) times")
        #expect(prompts.chimes == expectedChimes)
    }

    /// "Nothing drawn", pinned where it is decided: at compile time. The
    /// only view for `.celebration` is `CompletionCelebrationOverlay`,
    /// which is `#if !STUDY_BUILD` (its file and its use in
    /// `SchuleWorldView.queuedModalOverlay`, which renders `EmptyView()`
    /// otherwise), and the CI identity scan asserts the symbol is absent
    /// from the study binary. A SwiftUI branch cannot be observed from a
    /// unit test — this test fails if the suite ever runs in a build where
    /// the celebration view exists, so the end-of-set test above cannot
    /// be read as covering a build that draws something.
    @Test("a study build has no end-of-set celebration view to draw")
    func noCelebrationViewInAStudyBuild() {
        #if STUDY_BUILD
        #expect(Bool(true))
        #else
        Issue.record("this suite ran outside STUDY_BUILD: the celebration overlay is compiled in here, so 'nothing drawn' does not hold")
        #endif
    }

    /// The mid-set control: the SAME session shape on a letter that is
    /// not last must NOT celebrate. Without this the positive test above
    /// would also pass if the branch fired on every trial - which is the
    /// exact defect the one-letter-pool test exists to prevent, and the
    /// reason the two must be read together.
    @Test("a letter short of the end celebrates nothing")
    func midLetter_celebratesNothing() async {
        let prompts = SpyPromptPlayer()
        let vm = TracingViewModel(multiLetterDeps(spyPrompts: prompts))
        guard let first = vm.visibleLetterNames.first else { return }
        vm.loadLetter(name: first)

        vm.advanceLearningPhase()
        vm.advanceLearningPhase()
        vm.advanceLearningPhase()
        await settle()

        #expect(!vm.awaitingNextParticipant,
                "finishing a letter that is NOT the last must not hand the device back - the proctor would be told a child finished mid-set")
        #expect(prompts.celebrations == 0,
                "per-letter celebrations stay suppressed by the C1/C2 ruling: a per-letter reward gives every child the same number of them, so it cannot distinguish a good session from a bad one. Got \(prompts.celebrations) celebration prompts among \(prompts.keys)")
    }

    // MARK: - C4: pinned device settings

    @Test("studyMode pins SchriftArt to Druckschrift and the letter ordering")
    func studyMode_pinsScriptAndOrdering() {
        var deps = studyDeps()
        deps.schriftArt = .schreibschrift
        deps.letterOrdering = .alphabetical
        let vm = TracingViewModel(deps)
        #expect(vm.schriftArt == .druckschrift)
        #expect(vm.letterOrdering == .motorSimilarity)
    }

    @Test("studyMode hides letter variants (F's stroke-order toggle)")
    func studyMode_disablesVariants() {
        let vm = TracingViewModel(studyDeps())
        vm.letters = [LetterAsset(id: "F", name: "F", baseLetter: "F", letterCase: .upper,
                                  audioFiles: [],
                                  strokes: LetterStrokes(letter: "F", checkpointRadius: 0.1, strokes: []),
                                  variants: ["variant"])]
        vm.letterIndex = 0
        #expect(vm.currentLetterHasVariants == false,
                "the child-reachable variant toggle must be gone under studyMode")
    }

    // MARK: - Item 1: trained-3 practice pool

    @Test("studyMode practice pool = the participant's trained 3 letters")
    func studyMode_poolIsTrainedThree() {
        var deps = studyDeps().with(trainedSubset: TrainedLetterSubset(rawValue: "AIM")!)
        deps.studyMode = true
        let vm = TracingViewModel(deps)
        vm.letters = TrainedLetterSubset.studyLetters.map {
            LetterAsset(id: $0, name: $0, baseLetter: $0, letterCase: .upper,
                        audioFiles: [],
                        strokes: LetterStrokes(letter: $0, checkpointRadius: 0.1, strokes: []))
        }
        #expect(Set(vm.visibleLetterNames) == ["A", "I", "M"])
    }

    // MARK: - Item 5: letter-tagged durations + export columns

    @Test("SessionDurationRecord carries the letter and exports it")
    func durationRows_carryLetter() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("study-config-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = JSONParentDashboardStore(fileURL: dir.appendingPathComponent("dash.json"))
        store.recordSession(letter: "M", accuracy: 0.8, durationSeconds: 42.5,
                            wallClockSeconds: 50, date: Date(), condition: .threePhase,
                            inputDevice: "finger")
        #expect(store.snapshot.sessionDurations.last?.letter == "M")

        let csv = String(data: ParentDashboardExporter.csvData(from: store.snapshot), encoding: .utf8)!
        #expect(csv.contains("date,recordedAt,durationSeconds,wallClockSeconds,condition,inputDevice,letter"),
                "durations header must gain the trailing letter column")
        try? FileManager.default.removeItem(at: dir)
    }

    @Test("Per-phase CSV gains trainedSubset + phaseDurationSeconds columns")
    func phaseRows_exportNewColumns() {
        let record = PhaseSessionRecord(
            letter: "A", phase: "freeWrite", completed: true,
            score: 0.8, schedulerPriority: 0,
            audioCondition: .spatial,
            trainedSubset: "AIM", phaseDurationSeconds: 7.5)
        let snapshot = DashboardSnapshot(phaseSessionRecords: [record])
        let csv = String(data: ParentDashboardExporter.csvData(from: snapshot), encoding: .utf8)!
        #expect(csv.contains("audioCondition,trainedSubset,phaseDurationSeconds"))
        #expect(csv.contains("spatial,AIM,7.500"))
    }

    // MARK: - Study pins found by the 2026-09-04 audit
    //
    // Three ways a study session silently lost its primary outcome, each
    // now pinned at the VM: the pedagogical axis (an enrolled install
    // could draw a flow with no freeWrite phase), the grid preset (one
    // Apple Pencil touch switched freeWrite scoring onto the multi-cell
    // path that never sets `spatialDeviation`), and the freeWrite end
    // condition (checkpoint completion ended the trial mid-gesture).

    @Test("studyMode pins the pedagogical axis to the observed flow, freeWrite included")
    func studyMode_pinsThesisConditionToThreePhase() {
        // `.guidedOnly` is the flow an enrolled install can draw from
        // UUID byte 0 — and it has NO freeWrite phase. The VM must not
        // honour it under studyMode; freeWrite is the primary outcome.
        var deps = studyDeps()
        deps.thesisCondition = .guidedOnly
        let vm = TracingViewModel(deps)
        #expect(vm.thesisCondition == .threePhase)

        // The study flow is observe → guided → freeWrite (2026-09-18):
        // `direct` left the session on David's "the whole tapping the
        // points part should go", so this asserts the flow's CONTENT —
        // freeWrite present, and the phase that left absent — rather than
        // equality with `allCases`, which stopped being the same claim.
        #expect(vm.activePhases.contains(.freeWrite),
                "a study flow without freeWrite has no primary outcome and no post-test")
        #expect(vm.activePhases.contains(.observe) && vm.activePhases.contains(.guided),
                "the study flow is observe → guided → freeWrite, got \(vm.activePhases.map(\.rawName))")
        #expect(vm.activePhases.contains(.direct) == false,
                "`.direct` is back in the session — it was removed on 2026-09-18 and the tapping-points phase is not part of the study flow")
    }

    @Test("non-studyMode honours the injected pedagogical condition (A/B flow preserved)")
    func normalMode_keepsThesisCondition() {
        var deps = TracingDependencies.stub
        deps.studyMode = false
        deps.thesisCondition = .guidedOnly
        let vm = TracingViewModel(deps)
        #expect(vm.thesisCondition == .guidedOnly)
        #expect(vm.activePhases == [.guided])
    }

    @Test("studyMode keeps ONE cell after an Apple Pencil touch; the device is still recorded")
    func studyMode_pencilKeepsSingleCell() {
        let vm = TracingViewModel(studyDeps())
        vm.canvasSize = CGSize(width: 800, height: 600)
        #expect(vm.gridCells.count == 1)
        vm.pencilDidTouchDown()
        #expect(vm.inputModeDetector.effectiveKind == .pencil,
                "the detector must stay honest — `inputDevice` is exported on every row")
        #expect(vm.gridCells.count == 1,
                "the 4-cell pencil layout routes freeWrite through assess(cellReferences:), which never sets the primary outcome")
        #expect(vm.gridPreset.kind == .finger)
    }

    @Test("non-studyMode still promotes to the 4-cell pencil layout (behaviour preserved)")
    func normalMode_pencilPromotesToFourCells() {
        var deps = TracingDependencies.stub
        deps.studyMode = false
        let vm = TracingViewModel(deps)
        vm.canvasSize = CGSize(width: 800, height: 600)
        vm.pencilDidTouchDown()
        #expect(vm.gridCells.count == InputPreset.pencil.cellCount)
    }

    /// Drives one touch exactly along the tracker's loaded reference
    /// polyline — every update lands on the next checkpoint — so the
    /// tracker completes regardless of how the fixture letter was mapped
    /// onto the canvas. Set `vm.canvasSize` BEFORE calling this: the
    /// dispatcher re-maps checkpoints when the reported size differs.
    private func traceReferencePolyline(_ vm: TracingViewModel, canvas: CGSize) {
        let cps = vm.strokeTracker.definition?.strokes.flatMap(\.checkpoints) ?? []
        var t: CFTimeInterval = 1000
        let first = cps.first.map { CGPoint(x: $0.x * canvas.width, y: $0.y * canvas.height) } ?? .zero
        vm.beginTouch(at: first, t: t)
        for cp in cps {
            t += 0.01
            vm.updateTouch(at: CGPoint(x: cp.x * canvas.width, y: cp.y * canvas.height),
                           t: t, canvasSize: canvas)
        }
    }

    @Test("studyMode freeWrite is NOT ended by checkpoint completion — only the pen-lift quiet window ends it")
    func studyMode_freeWriteIgnoresCheckpointCompletion() {
        let store = RecordingDashboardStore()
        let vm = TracingViewModel(studyDeps().with(dashboardStore: store))
        let canvas = CGSize(width: 400, height: 400)
        vm.canvasSize = canvas
        vm.phaseController.resume(at: .freeWrite)
        traceReferencePolyline(vm, canvas: canvas)
        // Precondition, asserted rather than skipped: the tracker still
        // runs in freeWrite (it feeds `checkpointCoverage`), so the trace
        // above must have completed the letter's checkpoints.
        #expect(vm.progress == 1.0, "fixture drive did not complete the checkpoints — the assertion below would be vacuous")
        #expect(vm.learningPhase == .freeWrite)
        #expect(!vm.didCompleteCurrentLetter,
                "the trial must stay open while the finger is down — checkpoint completion used to end it mid-gesture, truncating the best writers' traces")
        #expect(store.phaseCalls.isEmpty, "no row may be written mid-gesture")
    }

    @Test("studyMode guided still completes on checkpoint completion (gate is freeWrite-specific)")
    func studyMode_guidedStillCompletesOnCheckpoints() {
        let vm = TracingViewModel(studyDeps())
        let canvas = CGSize(width: 400, height: 400)
        vm.canvasSize = canvas
        vm.phaseController.resume(at: .guided)
        traceReferencePolyline(vm, canvas: canvas)
        #expect(vm.learningPhase == .freeWrite,
                "positive control: the same drive must still advance guided → freeWrite")
    }

    // MARK: - Unload / background safety (2026-09-04): no trial vanishes, abandonment is a row
    //
    // Before: `load(letter:)` cleared the recorder and cancelled the
    // recognizer token, so a freeWrite production the child had finished
    // but that had not been scored yet — the proctor tapped the next
    // arrow inside the 2.0 s quiet window, or while the recognizer was in
    // flight — left no score, no row and no raw trace. And `completed`
    // was hard-coded `true`, so a letter left mid-phase left nothing.

    /// A short in-bounds freeWrite stroke; not along the reference.
    private func driveFreeWriteInk(_ vm: TracingViewModel, canvas: CGSize) {
        var t: CFTimeInterval = 1000
        vm.beginTouch(at: CGPoint(x: 50, y: 200), t: t)
        var p = CGPoint(x: 50, y: 200)
        for _ in 0..<15 { t += 0.01; p.x += 10; vm.updateTouch(at: p, t: t, canvasSize: canvas) }
    }

    @Test("studyMode: a finished-but-unscored freeWrite is scored and recorded when the letter is unloaded")
    func studyMode_unloadFinalizesFinishedFreeWrite() {
        let store = RecordingDashboardStore()
        let traces = StubRawTraceStore()
        let vm = TracingViewModel(studyDeps().with(dashboardStore: store).with(rawTraceStore: traces))
        let canvas = CGSize(width: 400, height: 400)
        vm.canvasSize = canvas
        vm.phaseController.resume(at: .freeWrite)
        driveFreeWriteInk(vm, canvas: canvas)
        vm.endTouch()   // pen up → the 2.0 s quiet window is now pending
        #expect(store.phaseCalls.isEmpty, "precondition: nothing is recorded before the unload")
        vm.loadLetter(name: vm.currentLetterName)   // proctor moves on inside the window
        let fw = store.phaseCalls.first { $0.phase == LearningPhase.freeWrite.rawName }
        #expect(fw?.completed == true, "a finished production is a completed trial: \(String(describing: fw))")
        #expect(fw?.spatialDeviation != nil, "the primary outcome must be scored on the unload path")
        #expect(fw?.rawTraceID != nil, "the freeWrite row must link to its raw trace")
        #expect(traces.traces.count == 1, "the raw trace must be persisted before the buffer clears")
        #expect(store.phaseCalls.filter { $0.phase == LearningPhase.freeWrite.rawName }.count == 1,
                "exactly one freeWrite row — no double completion")
    }

    @Test("studyMode: unloading mid-stroke records the freeWrite trial as NOT completed, with its measures")
    func studyMode_unloadMidStrokeRecordsAbandonedFreeWrite() {
        let store = RecordingDashboardStore()
        let vm = TracingViewModel(studyDeps().with(dashboardStore: store))
        let canvas = CGSize(width: 400, height: 400)
        vm.canvasSize = canvas
        vm.phaseController.resume(at: .freeWrite)
        driveFreeWriteInk(vm, canvas: canvas)   // finger still down
        vm.loadLetter(name: vm.currentLetterName)
        let fw = store.phaseCalls.first { $0.phase == LearningPhase.freeWrite.rawName }
        #expect(fw?.completed == false, "an interrupted production is not a completed trial: \(String(describing: fw))")
        #expect(fw?.spatialDeviation != nil, "what was written is still measured and kept")
        #expect(fw?.rawTraceID != nil)
    }

    @Test("studyMode: unloading a partly traced guided phase records it as NOT completed with its coverage")
    func studyMode_unloadRecordsAbandonedGuided() {
        let store = RecordingDashboardStore()
        let vm = TracingViewModel(studyDeps().with(dashboardStore: store))
        let canvas = CGSize(width: 400, height: 400)
        vm.canvasSize = canvas
        vm.phaseController.resume(at: .guided)
        // Hit the first few checkpoints only.
        let cps = Array((vm.strokeTracker.definition?.strokes.flatMap(\.checkpoints) ?? []).prefix(5))
        var t: CFTimeInterval = 1000
        let px: (Checkpoint) -> CGPoint = { CGPoint(x: $0.x * canvas.width, y: $0.y * canvas.height) }
        vm.beginTouch(at: cps.first.map(px) ?? .zero, t: t)
        for cp in cps { t += 0.01; vm.updateTouch(at: px(cp), t: t, canvasSize: canvas) }
        vm.endTouch()
        let progress = vm.progress
        #expect(progress > 0 && progress < 1, "precondition: partly traced, got \(progress)")
        vm.loadLetter(name: vm.currentLetterName)
        let g = store.phaseCalls.first { $0.phase == LearningPhase.guided.rawName }
        #expect(g?.completed == false, "\(String(describing: g))")
        #expect(g.map { abs($0.score - Double(progress)) < 1e-9 } == true,
                "the abandoned guided row carries the coverage reached so far")
        #expect(store.phaseCalls.count == 1, "one row for the abandoned phase, nothing else")
    }

    @Test("studyMode: unloading an untouched letter records nothing")
    func studyMode_unloadUntouchedRecordsNothing() {
        let store = RecordingDashboardStore()
        let vm = TracingViewModel(studyDeps().with(dashboardStore: store))
        vm.loadLetter(name: vm.currentLetterName)
        vm.loadLetter(name: vm.currentLetterName)
        #expect(store.phaseCalls.isEmpty)
    }

    @Test("non-studyMode: unloading a worked letter records nothing (behaviour preserved)")
    func normalMode_unloadRecordsNothing() {
        let store = RecordingDashboardStore()
        var deps = TracingDependencies.stub.with(dashboardStore: store)
        deps.studyMode = false
        let vm = TracingViewModel(deps)
        let canvas = CGSize(width: 400, height: 400)
        vm.canvasSize = canvas
        driveFreeWriteInk(vm, canvas: canvas)   // stub starts in .guided; some progress
        vm.endTouch()
        vm.loadLetter(name: vm.currentLetterName)
        #expect(store.phaseCalls.isEmpty)
    }

    // MARK: - Probe tag on rows and the from-memory canvas (2026-09-04)

    @Test("a pretest probe's freeWrite row is tagged 'pretest'; a training freeWrite row is untagged")
    func probeTag_onRows() {
        let store = RecordingDashboardStore()
        let vm = TracingViewModel(studyDeps().with(dashboardStore: store))
        let canvas = CGSize(width: 400, height: 400)
        vm.canvasSize = canvas
        // Pretest on the trained fixture letter A, finished, then unloaded.
        vm.startColdProbe(letter: "A", kind: .pretest)
        #expect(vm.learningPhase == .freeWrite && vm.currentProbe == .pretest)
        driveFreeWriteInk(vm, canvas: canvas)
        vm.endTouch()
        vm.loadLetter(name: "A")                       // unload → finalised, tagged
        let probeRow = store.phaseCalls.first { $0.phase == LearningPhase.freeWrite.rawName }
        #expect(probeRow?.probe == StudyProbe.pretest.rawValue, "\(String(describing: probeRow))")
        #expect(probeRow?.completed == true)
        // Now a training pass's freeWrite on the same letter: no tag.
        vm.phaseController.resume(at: .freeWrite)
        driveFreeWriteInk(vm, canvas: canvas)
        vm.endTouch()
        vm.loadLetter(name: "A")
        let rows = store.phaseCalls.filter { $0.phase == LearningPhase.freeWrite.rawName }
        #expect(rows.count == 2)
        #expect(rows.last?.probe == nil, "a training freeWrite row must carry no probe tag: \(String(describing: rows.last))")
    }

    @Test("study freeWrite hides the filled reference glyph — production is from memory")
    func studyFreeWrite_hidesReferenceGlyph() {
        let vm = TracingViewModel(studyDeps())
        vm.phaseController.resume(at: .guided)
        #expect(vm.showsReferenceGlyph, "the model stays visible while tracing")
        vm.phaseController.resume(at: .freeWrite)
        #expect(!vm.showsReferenceGlyph, "the letter must not be on screen while the child writes it from memory")
        vm.startColdProbe(letter: vm.currentLetterName, kind: .pretest)
        #expect(!vm.showsReferenceGlyph, "cold probes are freeWrite too")
    }

    @Test("non-study freeWrite keeps the filled glyph (casual app unchanged)")
    func normalMode_keepsReferenceGlyph() {
        var deps = TracingDependencies.stub
        deps.studyMode = false
        deps.thesisCondition = .threePhase
        let vm = TracingViewModel(deps)
        vm.phaseController.resume(at: .freeWrite)
        #expect(vm.showsReferenceGlyph)
    }

    @Test("studyMode: backgrounding with a finished-but-unscored freeWrite records it before the stores drain")
    func studyMode_backgroundFinalizesFinishedFreeWrite() async {
        let store = RecordingDashboardStore()
        let vm = TracingViewModel(studyDeps().with(dashboardStore: store))
        let canvas = CGSize(width: 400, height: 400)
        vm.canvasSize = canvas
        vm.phaseController.resume(at: .freeWrite)
        driveFreeWriteInk(vm, canvas: canvas)
        vm.endTouch()
        await vm.appDidEnterBackground()
        let fw = store.phaseCalls.first { $0.phase == LearningPhase.freeWrite.rawName }
        #expect(fw?.completed == true, "\(String(describing: fw))")
        #expect(vm.isPhaseSessionComplete, "the letter session is closed so the quiet-window task cannot complete it a second time")
    }
}
