// PhaseTransitionCoordinator.swift
// PrimaeNative
//
// D1c (ROADMAP) — third VM-decomposition slice. Owns the post-phase
// pipeline that runs whenever the learner completes a phase or the
// whole letter session:
//
//   `advance()` — score the just-completed phase, queue the post-
//   freeWrite kpOverlay + paperTransfer, advance the controller, and
//   route to either `toast` + `speech` (mid-cycle phase entry) or
//   `recordSessionCompletion()` (final phase reached).
//
//   `recordSessionCompletion()` (private) — celebration overlay +
//   praise speech, write one PhaseSessionRecord per phase to the
//   dashboard, hand off to `commitCompletion`.
//
//   `commitCompletion(...)` — durable progress, streak update +
//   reward overlays, dashboard session record, cloud sync push,
//   difficulty-tier adaptation, completion HUD. Called both from the
//   end-of-phase pipeline and from per-cell completion sites that
//   need the same shared side-effect set.
//
// Communicates back to the VM via a weak reference (no retain cycle:
// VM strong-owns the coordinator; coordinator weakly references the
// VM). State the coordinator reads/writes during a transition lives
// on the VM (phaseController, freeWriteRecorder, the four stores,
// overlayQueue, speech, syncCoordinator, …) — those go through the
// weak ref. The coordinator is stateless beyond the back-reference.
//
// Same shape as TouchDispatcher (D1b): the VM keeps thin forwarders
// (`advanceLearningPhase`) so SwiftUI views and TouchDispatcher
// don't have to change.

import Foundation
import QuartzCore

@MainActor
final class PhaseTransitionCoordinator {
    /// The VM that constructed this coordinator. Weak so the
    /// coordinator doesn't retain its parent. Set once by
    /// `TracingViewModel.init` after `self.phaseTransitions = pc` to
    /// satisfy two-phase init — same trick used for `playback` (W-16)
    /// and `touchDispatcher` (D1b).
    weak var vm: TracingViewModel?

    // MARK: - Public entry (forwarded from VM)

    /// Score the active phase, queue post-freeWrite overlays, advance
    /// the controller, and either announce the next phase or run the
    /// completion pipeline. Called from the VM's
    /// `advanceLearningPhase()` forwarder.
    func advance() {
        guard let vm else { return }
        let score: CGFloat
        switch vm.phaseController.currentPhase {
        case .observe:
            score = 1.0
        case .direct:
            score = 1.0  // pass/fail
        case .guided:
            score = vm.progress
        case .freeWrite:
            guard let def = vm.strokeTracker.definition else {
                vm.freeWriteRecorder.clearAll()
                score = 0
                break
            }
            // Recorder owns scoring — it has the buffers, sessionStart,
            // and canvasSize-normalised points all in one place.
            // C-5: pass the active cell's frame for multi-cell (pencil)
            // layouts so points are normalised to cell-local 0–1 space,
            // matching the reference stroke coordinate system.
            // W-26: word mode (multi-cell) splits the trace by cell so
            // each letter is scored against its own reference, then the
            // four Schreibmotorik dimensions are averaged. The single-
            // cell fall-through preserves the existing finger-mode
            // contract (one tracker definition over the whole canvas).
            if vm.grid.cells.count > 1 {
                let cellRefs = vm.grid.cells.compactMap { cell -> (frame: CGRect, reference: LetterStrokes)? in
                    guard let ref = cell.tracker.definition else { return nil }
                    return (frame: cell.frame, reference: ref)
                }
                if cellRefs.isEmpty {
                    score = vm.freeWriteRecorder.assess(
                        reference: def, canvasSize: vm.canvasSize,
                        cellFrame: vm.grid.activeCell.frame
                    ).overallScore
                } else {
                    score = vm.freeWriteRecorder.assess(
                        cellReferences: cellRefs,
                        canvasSize: vm.canvasSize
                    ).overallScore
                }
            } else {
                score = vm.freeWriteRecorder.assess(
                    reference: def, canvasSize: vm.canvasSize,
                    cellFrame: nil
                ).overallScore
            }
        }

        let wasInFreeWrite = vm.phaseController.currentPhase == .freeWrite
        let wasInGuided = vm.phaseController.currentPhase == .guided

        if wasInGuided {
            // Capture the guided score before the phase advance so the
            // Schule world can show a verbal feedback band during the
            // transition into freeWrite. Cleared on letter load.
            vm.freeWriteRecorder.lastGuidedScore = score
        }

        // FreeWrite final phase: defer the post-freeWrite UI + the
        // session-completion record until the CoreML recognizer
        // returns. The recognition outcome decides whether the child
        // gets the "Geschafft!" celebration (correct + confidence
        // > 0.7) or has to retrace the freeform — neither of which
        // we know synchronously here.
        if wasInFreeWrite {
            vm.runRecognizerForFreeWrite(score: score)
            return
        }

        if vm.phaseController.advance(score: score) {
            vm.resetForPhaseTransition()
            if vm.phaseController.currentPhase == .observe {
                vm.startGuideAnimation()
            }
            vm.toast(vm.phaseController.currentPhase.displayName)
            // Verbal phase prompt — spoken every transition so a child
            // who can't read the on-screen "Anschauen / Richtung lernen"
            // pill still knows what's happening next. Routed through
            // PromptPlayer so the ElevenLabs MP3 plays when bundled,
            // with the AVSpeechSynthesizer line as the fallback.
            vm.prompts.play(
                ChildSpeechLibrary.phaseEntryPromptKey(vm.phaseController.currentPhase),
                fallbackText: ChildSpeechLibrary.phaseEntry(vm.phaseController.currentPhase)
            )
        } else {
            // Non-freeWrite final phase (.guidedOnly / .control
            // conditions land here at end-of-guided). No recognizer
            // run for those; celebrate unconditionally.
            recordSessionCompletion()
        }
    }

    // MARK: - FreeWrite recognizer-gated completion

    /// Called from `TracingViewModel.runRecognizerForFreeWrite(score:)`
    /// once the CoreML recognizer returns. Routes to retry only when
    /// the model is *confident the letter is wrong* (RecognitionFeedback
    /// "orange" tier: `!isCorrect && confidence > 0.7`). Green, yellow
    /// (correct + low confidence), low-confidence noise, and a missing
    /// recognizer all flow into the celebration — gating strictly on
    /// "model agrees with green confidence" locked the child out when
    /// the model was uncertain on perfectly-acceptable handwriting.
    func completePostFreeWriteRecognition(score: CGFloat,
                                          result: RecognitionResult?) {
        guard let vm else { return }
        _ = vm  // silence unused warning while only `result` is read here
        let triggerRetry: Bool
        if let r = result {
            triggerRetry = !r.isCorrect && r.confidence > 0.7
        } else {
            triggerRetry = false
        }
        if triggerRetry {
            requestFreeWriteRetry(result: result!)
        } else {
            celebrateFreeWrite(score: score, result: result)
        }
    }

    private func celebrateFreeWrite(score: CGFloat,
                                    result: RecognitionResult?) {
        guard let vm else { return }
        vm.overlayQueue.enqueue(.kpOverlay)
        if let r = result, r.confidence >= 0.4 {
            vm.overlayQueue.enqueueBeforeCelebration(.recognitionBadge(r))
            // Verbal mirror of the on-screen badge — a 5–6 yr-old
            // who can't read the chip text still hears the same
            // wording.
            let line = ChildSpeechLibrary.recognition(r, expected: vm.currentLetterName)
            if !line.isEmpty { vm.speech.speak(line) }
        }
        if vm.enablePaperTransfer {
            vm.overlayQueue.enqueue(.paperTransfer(letter: vm.currentLetterName))
        }
        // Final-phase advance — sets isLetterSessionComplete = true
        // but leaves currentPhase at .freeWrite. Returns false; we
        // never reach the mid-phase branch from this path.
        _ = vm.phaseController.advance(score: score)
        recordSessionCompletion()
    }

    private func requestFreeWriteRetry(result: RecognitionResult) {
        guard let vm else { return }
        // Show the recognition badge so the child sees what the
        // model thought they wrote (orange "looks like O — write A
        // again") before the retry prompt lands.
        if result.confidence >= 0.4 {
            vm.overlayQueue.enqueue(.recognitionBadge(result))
            let line = ChildSpeechLibrary.recognition(result, expected: vm.currentLetterName)
            if !line.isEmpty { vm.speech.speak(line) }
        }
        // Reset freeWrite state so the next stroke starts from a
        // clean slate — recorder, ink trail, stroke tracker all
        // wiped, recorder session re-armed for the retry.
        vm.strokeTracker.reset()
        if vm.letters.indices.contains(vm.letterIndex) {
            vm.reloadStrokeCheckpoints(for: vm.letters[vm.letterIndex])
        }
        vm.freeWriteRecorder.clearAll()
        vm.freeWriteRecorder.startSession()
        vm.activePath.removeAll(keepingCapacity: true)
        vm.toast("Probier's nochmal")
        vm.speech.speak("Probier's nochmal")
    }

    // MARK: - Final-phase pipeline

    private func recordSessionCompletion() {
        guard let vm else { return }
        vm.overlayQueue.enqueue(.celebration(stars: vm.phaseController.starsEarned))
        // Letter-completion celebration: short positive chime +
        // the warm "Super gemacht!" voice line. The N-of-4 star
        // row in CompletionCelebrationOverlay is the visual
        // differentiator; the audio is the same regardless of
        // star count, so a child who barely scraped 1 star still
        // hears genuine encouragement. Pre-recorded ElevenLabs
        // take via PromptPlayer when bundled; AVSpeech fallback
        // otherwise.
        vm.prompts.playSuccessChime()
        vm.prompts.play(.celebration,
                        fallbackText: ChildSpeechLibrary.celebration)
        let accuracy = Double(vm.phaseController.overallScore)
        let now = CACurrentMediaTime()
        let liveSlice = vm.letterLoadTime.map { now - $0 } ?? 0
        let duration = vm.letterActiveTimeAccumulated + liveSlice
        let scores: [String: Double] = Dictionary(
            uniqueKeysWithValues: vm.phaseController.phaseScores.map { ($0.key.rawName, Double($0.value)) }
        )
        // D-2: attach the latest recognition reading to the freeWrite row
        // so per-session recognition is recoverable from the CSV. Other
        // phases never produce a freeWrite recognition; pass nil there.
        let freeWriteRecognition: RecognitionSample? = vm.lastRecognitionResult.map { rr in
            RecognitionSample(
                predictedLetter: rr.predictedLetter,
                confidence: Double(rr.confidence),
                isCorrect: rr.isCorrect
            )
        }
        // D-6: capture the input mode in effect for the row so a finger
        // session's pressureControl == 1.0 (no force data) is
        // distinguishable from a low-variance pencil session in the export.
        let device = vm.detector.effectiveKind.rawValue
        for (phase, phaseScore) in scores {
            vm.dashboardStore.recordPhaseSession(
                letter: vm.currentLetterName,
                phase: phase,
                completed: true,
                score: phaseScore,
                schedulerPriority: vm.lastScheduledLetterPriority,
                condition: vm.thesisCondition,
                assessment: phase == "freeWrite" ? vm.lastWritingAssessment : nil,
                recognition: phase == "freeWrite" ? freeWriteRecognition : nil,
                inputDevice: device
            )
        }
        commitCompletion(letter: vm.currentLetterName,
                         accuracy: accuracy,
                         duration: duration,
                         phaseScores: scores)
    }

    /// Shared completion side-effects: durable progress + streak +
    /// dashboard row, background cloud sync, difficulty-tier
    /// adaptation, completion HUD. Both the per-letter stroke-
    /// completion path and the multi-phase session completion path go
    /// through here so the side-effect set can never drift between the
    /// two — every store-write addition lands in one place.
    func commitCompletion(letter: String,
                          accuracy: Double,
                          duration: TimeInterval,
                          phaseScores: [String: Double]? = nil) {
        guard let vm else { return }
        // Word sequences fan out per-cell for progress + streak so each
        // letter that appears in a word counts toward its own mastery
        // tracking, while the dashboard + adaptation row uses the word
        // title so thesis analytics can distinguish word sessions from
        // single-letter sessions by the field length. Single-letter and
        // repetition sequences take the pre-word path unchanged.
        let lettersToRecord: [String]
        let dashboardLabel: String
        let isWordSequence: Bool
        if case .word(let word) = vm.grid.sequence.kind {
            lettersToRecord = vm.grid.cells.map(\.item.letter)
            dashboardLabel = word
            isWordSequence = true
        } else {
            lettersToRecord = [letter]
            dashboardLabel = letter
            isWordSequence = false
        }

        let speed: Double? = vm.checkpointsPerSecond > 0 ? Double(vm.checkpointsPerSecond) : nil
        // Recognition result lands asynchronously in parallel with phase
        // advance — it's often still nil here. Pass whatever's latched so
        // single-letter guided sessions that finish AFTER the recognizer
        // returns also populate the dashboard's confidence series.
        let rr = vm.lastRecognitionResult
        for l in lettersToRecord {
            vm.progressStore.recordCompletion(for: l, accuracy: accuracy,
                                              phaseScores: phaseScores, speed: speed,
                                              recognitionResult: rr)
        }
        // Variant tracking is single-letter only — loadWord doesn't
        // preserve showingVariant state across word entries.
        if !isWordSequence, vm.showingVariant, vm.letters.indices.contains(vm.letterIndex),
           let variantID = vm.letters[vm.letterIndex].variants?.first {
            vm.progressStore.recordVariantUsed(for: letter, variantID: variantID)
        }
        // Refresh the VM's @Observable allProgress mirror so the
        // world-rail star badge + Fortschritte gallery pick up the
        // new completion. The store itself isn't @Observable, so
        // this call is the bridge that fires SwiftUI updates.
        vm.refreshProgressMirror()
        let newRewards = vm.streakStore.recordSession(
            date: Date(),
            lettersCompleted: lettersToRecord,
            accuracy: accuracy
        )
        // U1 (ROADMAP_V5): surface freshly-unlocked achievements as a
        // one-time overlay before the celebration the child is already
        // expecting. `enqueueBeforeCelebration` slots each badge ahead
        // of the celebration regardless of where in the queue the
        // celebration currently sits (queued / about to fire / active).
        for event in newRewards {
            vm.overlayQueue.enqueueBeforeCelebration(.rewardCelebration(event))
        }
        // T4: wall-clock duration includes any backgrounded interval and
        // is reconstructed from the load Date stamp; the active-time
        // `duration` parameter excludes it (D-1 accumulator).
        // T7: device tag so the export can split duration by input mode.
        let wallClock = vm.letterLoadedDate.map { Date().timeIntervalSince($0) }
        let device = vm.detector.effectiveKind.rawValue
        vm.dashboardStore.recordSession(letter: dashboardLabel, accuracy: accuracy,
                                        durationSeconds: duration,
                                        wallClockSeconds: wallClock,
                                        date: Date(),
                                        condition: vm.thesisCondition,
                                        inputDevice: device)
        Task { [weak vm] in try? await vm?.syncCoordinator.pushAll() }

        let adaptSample = AdaptationSample(letter: dashboardLabel,
                                           accuracy: CGFloat(accuracy),
                                           completionTime: duration)
        vm.adaptationPolicy.record(adaptSample)
        vm.currentDifficultyTier         = vm.adaptationPolicy.currentTier
        vm.strokeTracker.radiusMultiplier = vm.currentDifficultyTier.radiusMultiplier

        vm.showCompletionHUD()
    }
}
