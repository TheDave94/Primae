// TouchDispatcher.swift
// PrimaeNative
//
// Owns the in-flight touch session state and the
// `beginTouch` / `updateTouch` / `endTouch` flow. VM strong-owns the
// dispatcher; dispatcher weakly references the VM. State during a
// touch (audio, playback, haptics, recorder, tracker, grid, phase,
// letters, activePath, progress) lives on the VM.

import CoreGraphics
import Foundation
import QuartzCore

@MainActor
final class TouchDispatcher {

    // MARK: - Owned touch-session state

    /// True while a single-touch tracing gesture is in flight.
    private(set) var isSingleTouchInteractionActive = false
    /// Last seen touch point in canvas pixels — EVERY sample. Drives the
    /// velocity estimate, which needs sample-to-sample displacement.
    private(set) var lastPoint: CGPoint?
    private(set) var lastTimestamp: CFTimeInterval?
    /// Last point KEPT into the ink (`vm.activePath`) and the freeWrite
    /// recorder. The jitter filter measures against THIS, not against
    /// `lastPoint` (protocol r7, audit E2-01). Measured against the
    /// previous sample, the 1.5 pt hysteresis became a speed threshold —
    /// 1.5 pt × sample rate, ≈180 pt/s for a finger at 120 Hz and ≈360
    /// pt/s for the Pencil at 240 Hz — because every coalesced sample is
    /// delivered (#21): a slow stroke, and the decelerating end of every
    /// stroke, was dropped from the ink and from the scored, exported
    /// trace. Against the last kept point the filter does what its own
    /// doc says: a held finger's jitter (which never strays 1.5 pt from
    /// where it rests) adds nothing, and any motion of 1.5 pt or more is
    /// kept, however slowly it was made. Nil when the next in-bounds
    /// sample must be kept unconditionally (a fresh stroke after an
    /// out-of-bounds excursion).
    private(set) var lastKeptPoint: CGPoint?
    /// The most recent in-bounds sample that the filter did NOT keep,
    /// with what `record` needs, or nil when the last sample was kept.
    /// Flushed into the freeWrite recorder at the lift so the trace ends
    /// where the pen did — mirroring the pen-down rule in `beginTouch`.
    private var unkeptTail: (point: CGPoint, timestamp: CFTimeInterval, force: CGFloat, canvasSize: CGSize)?
    /// Points kept since the current stroke began (the pen-down, or the
    /// re-entry after an excursion, counts as one). The lift flush needs
    /// at least one kept MOVE, so a stationary contact (a palm) with
    /// sub-threshold jitter stays the one-sample contact it always was
    /// and never becomes a two-point "production".
    private var keptPointsInStroke = 0
    /// Exponentially-smoothed touch velocity. Drives audio time-stretch
    /// and the "should playback be active" gate.
    private(set) var smoothedVelocity: CGFloat = 0

    // MARK: - Tunable knobs

    /// EWMA smoothing factor; calibrated for iPad-finger writing.
    var velocitySmoothingAlpha: CGFloat = 0.22
    /// Minimum smoothed velocity (pt/s) before playback goes `.active` —
    /// one half of the ANDed boundary that decides WHEN the arm's sound
    /// starts (`vm.strokeTracker.isNearStroke` is the other).
    ///
    /// DEFAULT 0.0 since 2026-10-04: a moving finger on the letter is
    /// audible however slowly it moves. It was 22.0 and was the gate that
    /// bound — see `StudyComparisonSettings.soundGateVelocityFloor` for
    /// the measurement and for why a stopped pen still goes quiet without
    /// it (the stall timeout, not this number).
    ///
    /// The value here is the production default — taken from the one named
    /// constant so it cannot drift from the switch's own default;
    /// `TracingViewModel` overwrites it once at construction from
    /// `StudyComparisonSettings.soundGateVelocityFloor`, the supervisor's
    /// "Trigger boundaries" (2026-09-17), so a comparison run can
    /// re-introduce a movement requirement and an untouched device keeps
    /// this value.
    var playbackActivationVelocityThreshold: CGFloat =
        CGFloat(StudyComparisonSettings.soundGateVelocityFloorDefault)
    /// R18DIM-S3: whether the sound is gated to the letter. `true` (default,
    /// protocol r17) = the proximity gate applies in guided tracing; `false`
    /// = sound wherever the pen moves on the canvas. Written once by
    /// `TracingViewModel.init` from `StudyComparisonSettings.soundGatingEnabled`.
    var soundGatingEnabled: Bool = StudyComparisonSettings.soundGatingEnabledDefault
    /// Sub-pixel hysteresis so digitiser noise on a held finger doesn't
    /// accumulate spurious motion.
    var minimumTouchMoveDistance: CGFloat = 1.5

    // MARK: - Back-reference

    /// Weak back-reference set by `TracingViewModel.init` after the
    /// dispatcher is assigned (two-phase init).
    weak var vm: TracingViewModel?

    /// FreeWrite has no canonical-stroke completion path, so on lift
    /// we schedule a quiet-window phase advance (~2 s); a re-touch
    /// cancels it.
    private var freeWriteAutoAdvanceTask: Task<Void, Never>?
    /// Device that began the current session; events from the other
    /// device are ignored until it ends (review 2026-09-05).
    private var sessionIsPencil = false
    private let freeWriteQuietSeconds: TimeInterval = 2.0

    /// Tracks the previous in-bounds state so the out-of-bounds warning
    /// fires only on the rising edge.
    private var wasInBounds: Bool = true

    /// R-071 (audit 2026-10-13, H1-09): the spoken retry cue ("Probier's
    /// nochmal") at most once per this many seconds of TOUCH time. It was
    /// spoken on every out-of-bounds rising edge, and the synthesiser
    /// queues, so a child scribbling past the edge three times in two
    /// seconds heard it three times back to back over the next attempt.
    /// The toast still shows on every edge. 3.0 s is a batch-C choice
    /// (about one cue's length plus a breath), flagged for David.
    static let retryCueMinimumInterval: CFTimeInterval = 3.0
    /// Touch timestamp of the last spoken retry cue; nil after a reset.
    private var lastRetryCueAt: CFTimeInterval?

    // MARK: - Stroke envelope state (protocol r17, RULINGS 2026-11-05)

    /// Touch time of the last lift of this letter's writing, for the lift-to-next-touch gap (`StrokeTempo`).
    private var lastLiftAt: CFTimeInterval?
    /// Whether that lift finished the letter: no hold, and its gap is not a transition between strokes.
    private var lastLiftEndedLetter = false
    /// Set when the letter's last stroke reached its end while the pen was down (free-writing): the sound has faded and stays off until the next touch.
    private(set) var letterEndLatched = false

    /// Records the gap since the previous lift into the child's tempo and applies the tempo's stall cutoff.
    private func noteStrokeGap(at t: CFTimeInterval) {
        guard let vm else { return }
        defer { lastLiftAt = nil }
        // Cold probes are fixed protocol and silent: they neither feed nor read the tempo.
        if vm.currentProbe == nil, let lift = lastLiftAt, !lastLiftEndedLetter,
           vm.phaseController.currentPhase == .guided || vm.phaseController.currentPhase == .freeWrite {
            let gap = t - lift
            if vm.strokeTempo.record(gap: gap) { vm.phaseDelivery.noteGap(gap); vm.phaseDelivery.setTempo(vm.strokeTempo) }
        }
        vm.playback.idleDebounceSeconds = vm.strokeTempo.stallSeconds
    }

    // MARK: - Public API (forwarded from VM)

    func beginTouch(at p: CGPoint, t: CFTimeInterval) {
        guard let vm else { return }
        // A study session that cannot deliver its stimulus does not
        // trace at all — see TracingViewModel.studyPreconditionFailure.
        guard vm.sessionBlockReason == nil             else { return }
        // A suspended session (inactive scene, parent area open: R-005,
        // R-026) takes no new stroke: its clock is stopped and nothing it
        // writes or plays would be part of the session (STATE-7).
        guard vm.activeInterruptions.isEmpty          else { return }
        guard vm.phaseController.isTouchEnabled       else { return }
        guard vm.phaseController.currentPhase != .direct else { return }  // handled by DirectPhaseDotsOverlay
        guard !isSingleTouchInteractionActive         else { return }
        // A freeWrite production that has been scored (quiet window
        // fired, recognizer in flight) accepts no more ink: its measures
        // were latched from the buffer as it was, and a later stroke used
        // to land in the raw trace but not in the row (review 2026-09-05).
        guard !(vm.didCompleteCurrentLetter && vm.phaseController.currentPhase == .freeWrite) else { return }

        // Re-touch cancels a pending freeWrite auto-advance.
        freeWriteAutoAdvanceTask?.cancel()
        freeWriteAutoAdvanceTask = nil
        // The new stroke's own lift decides the window from here.
        cancelledStrokeAwaitsWindow = false
        // A real touch beginning always supersedes an in-flight
        // pre-task demonstration — see PreTaskDemonstration.
        vm.cancelPreTaskDemonstration()

        noteStrokeGap(at: t)
        letterEndLatched               = false
        isSingleTouchInteractionActive = true
        sessionIsPencil                = vm.lastTouchDownWasPencil
        vm.playback.resumeIntent       = true
        // B17/B18: a fresh stroke starts a fresh rate history, and its
        // first sample writes the pitch at once.
        velocityHistory.removeAll(keepingCapacity: true)
        dysfluencyMeter.reset()
        lastCouplingParameters         = nil
        lastPitchWriteAt               = nil
        pendingPitchCents              = nil
        lastPoint                      = p
        lastTimestamp                  = t
        lastKeptPoint                  = p
        unkeptTail                     = nil
        keptPointsInStroke             = 1
        vm.activePath                  = [p]
        // New touch supersedes any lingering snapshot from the
        // previous phase — clear so the two paths don't overlay.
        vm.lingeringInk = []
        wasInBounds                    = true
        // Stroke-boundary marker so the CoreML rasterizer breaks the
        // polyline at lifts (F→P confusion otherwise).
        if vm.phaseController.currentPhase == .freeWrite {
            vm.freeWriteRecorder.beginStroke()
            // The pen-down sample IS the stroke's start: without it the
            // trace began 1.5 pt into the stroke and the duration
            // excluded the pen-down→first-move interval (audit 2026-09-04).
            vm.freeWriteRecorder.record(point: p, timestamp: t,
                                        force: vm.pencilPressure ?? 0,
                                        canvasSize: vm.canvasSize)
        }
        // FreeWrite fades real-time feedback (Schmidt & Lee 2005
        // Guidance Hypothesis); gate haptics + ticks on intensity.
        if vm.feedbackIntensity > 0 { vm.haptics.fire(.strokeBegan) }
        // endTouch's stop() clears currentFile; reload before the next
        // play() would silently fail. (PlaybackController reloads again
        // before each play, for the same reason mid-stroke.)
        //
        // NOT while the lift hold is sounding (protocol r7, 2026-10-13).
        // A lift while sounding leaves the machine `.active` and the engine
        // playing for `SoundEnvelope.liftHoldSeconds`. Reloading here
        // opened with the engine's `player.stop()` — a hard stop, no fade —
        // while the machine stayed `.active`, so the next move's
        // `request(.active)` was a no-op transition, `play()` never ran,
        // and the stroke after a quick re-touch was SILENT in both sound
        // arms in every writing phase (r5–r6). The held file is still
        // loaded and is still the right one: every path that changes the
        // file — a letter load, a phase transition, backgrounding, the
        // out-of-bounds edge — forces the machine idle first, so `.active`
        // at a touch-down means "the hold of this letter's sound". Idle (no
        // hold, or the hold already expired) reloads exactly as before. The
        // silent arm never goes active, so it is untouched.
        if vm.playback.state != .active {
            vm.reloadActiveAudioFile()
        }
    }

    func updateTouch(at p: CGPoint, t: CFTimeInterval, canvasSize: CGSize) {
        guard let vm else { return }
        // The Pencil overlay stamps `pencilPressure` before every move; the
        // finger overlay never does. A move from the device that does not
        // own this session is dropped (and a stray pencil stamp cleared) so
        // a resting hand and the pen cannot interleave into one stroke.
        let eventIsPencil = vm.pencilPressure != nil
        if eventIsPencil != sessionIsPencil {
            if !sessionIsPencil { vm.pencilPressure = nil; vm.pencilAzimuth = 0 }
            return
        }
        guard isSingleTouchInteractionActive else { return }
        guard let lastPoint                  else { return }

        resyncCanvasSizeIfNeeded(canvasSize)

        let isWithinCanvasBounds =
            p.x >= 0 && p.y >= 0 && p.x <= canvasSize.width && p.y <= canvasSize.height

        // Out-of-bounds rising edge: stop audio, wipe partial stroke,
        // tell the child to retrace (visual + verbal — pre-readers
        // can't see the toast). Re-entry restarts the current stroke.
        if wasInBounds && !isWithinCanvasBounds {
            vm.audio.stop()
            vm.isPlaying = false
            vm.playback.cancelPending()
            vm.playback.forceIdle()
            if vm.phaseController.currentPhase == .freeWrite {
                // Free production: what was drawn stays in the record
                // (and on screen); the excursion simply ends this stroke,
                // so the re-entry does not fuse with it into one
                // mis-shaped stroke. No retry cue — the phase gives no
                // feedback (audit 2026-09-04).
                vm.freeWriteRecorder.beginStroke()
                vm.activePath.removeAll(keepingCapacity: true)
            } else {
                vm.strokeTracker.resetCurrentStroke()
                vm.activePath.removeAll(keepingCapacity: true)
                vm.toast("Probier's nochmal")
                // Played in every arm (P3, 2026-10-04): a study voiceover
                // session no longer nulls the silent arm's speech, so the
                // spoken content is identical across arms. Since r9 it is
                // the RECORDED retry cue, through the prompt player
                // (`StudyVoiceoverPromptPlayer` passes it to every arm).
                // With spoken feedback off, `vm.prompts` is the null
                // player where `vm.speech` was the null synthesiser.
                // Rate-limited on the touch clock (R-071).
                if lastRetryCueAt.map({ t - $0 >= Self.retryCueMinimumInterval }) ?? true {
                    lastRetryCueAt = t
                    vm.prompts.play(.retryCue, fallbackText: "Probier's nochmal")
                }
            }
            // The excursion ended the stroke (ink wiped or split above):
            // the re-entry starts a fresh one with its first sample.
            lastKeptPoint      = nil
            unkeptTail         = nil
            keptPointsInStroke = 0
        }
        wasInBounds = isWithinCanvasBounds

        // Sample-to-sample displacement: the velocity estimate below.
        let dx       = p.x - lastPoint.x
        let dy       = p.y - lastPoint.y
        let distance = hypot(dx, dy)

        // Displacement from the last KEPT point: the jitter filter. See
        // `lastKeptPoint` for why this is not `distance` (r7, E2-01).
        let distanceFromKept = lastKeptPoint.map { hypot(p.x - $0.x, p.y - $0.y) }
            ?? .greatestFiniteMagnitude
        if isWithinCanvasBounds && distanceFromKept >= minimumTouchMoveDistance {
            vm.activePath.append(p)
            // FreeWrite scoring + KP overlay buffers.
            if vm.phaseController.currentPhase == .freeWrite {
                vm.freeWriteRecorder.record(point: p,
                                            timestamp: t,
                                            force: vm.pencilPressure ?? 0,
                                            canvasSize: canvasSize)
            }
            lastKeptPoint       = p
            unkeptTail          = nil
            keptPointsInStroke += 1
            // R19 (N10): the pen travelled; a pen that did not for a stall cutoff has no direction.
            if vm.directionMuteEnabled {
                movementTracker.penMoved(at: t, stallSeconds: vm.strokeTempo.stallSeconds)
            }
        } else if isWithinCanvasBounds {
            unkeptTail = (p, t, vm.pencilPressure ?? 0, canvasSize)
        }

        if let lastTimestamp {
            let dt       = max(0.001, t - lastTimestamp)
            let velocity = distance / dt
            if vm.dysfluencyRoughness { dysfluencyMeter.add(t: t, distance: Double(distance)) }   // R18DIM slice 7
            smoothedVelocity = smoothedVelocity == 0
                ? velocity
                : smoothedVelocity + velocitySmoothingAlpha * (velocity - smoothedVelocity)
        } else {
            self.lastTimestamp = t
        }

        // Canvas-normalised coords drive the audio stereo pan.
        let canvasNormalized = CGPoint(x: p.x / max(canvasSize.width, 1),
                                       y: p.y / max(canvasSize.height, 1))
        // Cell-normalised coords feed the active cell's tracker, whose
        // checkpoints live in cell-local 0–1 space.
        // `trackerAspect` (width / height of that frame) lets the tracker
        // measure distance in height units on BOTH axes, so its hit test
        // is isotropic in points (r16, audit B-3).
        let activeFrame = vm.grid.activeCell.frame
        let normalized: CGPoint
        let trackerAspect: CGFloat
        if activeFrame.width > 0 && activeFrame.height > 0 {
            normalized = CGPoint(
                x: (p.x - activeFrame.minX) / activeFrame.width,
                y: (p.y - activeFrame.minY) / activeFrame.height
            )
            trackerAspect = activeFrame.width / activeFrame.height
        } else {
            normalized = canvasNormalized
            trackerAspect = max(canvasSize.width, 1) / max(canvasSize.height, 1)
        }
        let prevStrokeIndex    = vm.strokeTracker.currentStrokeIndex
        let prevNextCheckpoint = vm.strokeTracker.progress.indices.contains(prevStrokeIndex)
            ? vm.strokeTracker.progress[prevStrokeIndex].nextCheckpoint : 0
        let wasComplete        = vm.strokeTracker.isComplete

        vm.strokeTracker.update(normalizedPoint: normalized, aspectRatio: trackerAspect)

        let isNowComplete = vm.strokeTracker.isComplete
        if !wasComplete && isNowComplete, vm.feedbackIntensity > 0 {
            vm.haptics.fire(.letterCompleted)
        }
        // Whole-sequence aggregate; reduces to overallProgress for
        // single-cell.
        vm.progress = vm.grid.aggregateProgress

        updateGuidedAndFreeWriteSpeed()

        fireMovementHaptics(prevStrokeIndex: prevStrokeIndex,
                            prevNextCheckpoint: prevNextCheckpoint)

        // A sample that completes the letter must not START the sound
        // (code analysis 2026-11-01, F2): with the machine idle (the stall
        // timeout had fired), the adaptive request below played the file at
        // full level and the completion handler stopped it in the same turn,
        // leaving a hard onset plus the fade tail as the letter ended. Not a
        // reorder: completion advances the grid cursor (`strokeTracker` then
        // aliases the next cell) and can run the phase transition, so the
        // adaptive update must stay BEFORE it on every sample that does not
        // finish the sequence — stroke-to-stroke and cell-to-cell are as before.
        if !sampleFinishesSequence() {
            updateAdaptivePlayback(canvasNormalized: canvasNormalized, cellPoint: normalized, cellAspect: trackerAspect, at: t)
        }

        handleStrokeCompletionIfReached()
        // Free-writing has no completion path of its own (the quiet window ends it), but the tracker still knows when the
        // letter's last stroke reached its end: the sound fades at once and stays off until the next touch (RULINGS 2026-11-05).
        if vm.studyMode, vm.phaseController.currentPhase == .freeWrite, !letterEndLatched, vm.currentProbe == nil,
           vm.strokeTracker.isComplete, vm.playback.state == .active {
            letterEndLatched = true
            vm.playback.requestLetterEndIdle()
        }

        self.lastPoint     = p
        self.lastTimestamp = t
    }

    func endTouch(fromPencil: Bool? = nil) {
        finishTouch(fromPencil: fromPencil, cancelled: false)
    }

    /// A touch the SYSTEM cancelled (`touchesCancelled`: an edge gesture,
    /// Control Center, palm rejection, an interruption) — R-024, audit
    /// 2026-10-13. Closed exactly like a lift (the samples stay in the
    /// trace, the sound gets its hold, the jitter tail is recorded), with
    /// one difference: a cancel is not the child's "done", so it never
    /// arms the free-writing quiet window. Counted per letter in
    /// `lifecycleCounters.strokesCancelled`. Before this the canvas
    /// overlays forwarded a cancel as `touchesEnded`, so a cancelled
    /// stroke could end the outcome trial two seconds later.
    func cancelTouch(fromPencil: Bool? = nil) {
        finishTouch(fromPencil: fromPencil, cancelled: true)
    }

    private func finishTouch(fromPencil: Bool?, cancelled: Bool) {
        guard let vm else { return }
        // No touch session was begun (code analysis 2026-11-01, F1): a lift
        // whose touch-down `beginTouch` rejected — observe, `.direct`, a
        // blocked session, a scored freeWrite — or a second lift after the
        // session already ended. The overlays deliver the end event anyway.
        // It must not reach the audio: in observe the playback machine is
        // `.idle` (the demonstration plays through `audio.play(fadeInSeconds:)`
        // directly), so the idle branch below called `audio.stop()` and a
        // child's tap silenced the observe sound in the sound arms only.
        // Only the per-event stylus stamps are cleared, as before, so a
        // stale Pencil stamp cannot mark the next finger move as the Pencil.
        guard isSingleTouchInteractionActive else {
            vm.pencilPressure = nil
            vm.pencilAzimuth  = 0
            return
        }
        // A lift from the device that does not own the session (the Pencil
        // lifting while a resting finger is the tracked touch) must not end
        // the finger's stroke (review 2026-09-05).
        if let fromPencil, fromPencil != sessionIsPencil { return }
        if cancelled && isSingleTouchInteractionActive {
            vm.countLifecycleEvent(\.strokesCancelled)
            // Remembered for the resume of an interruption, whichever of
            // the two the system delivers first (delta review of batch C,
            // item 1; reviewer probe P8).
            if vm.phaseController.currentPhase == .freeWrite, !vm.didCompleteCurrentLetter {
                cancelledStrokeAwaitsWindow = true
            }
        }
        // The stroke ends where the pen did (r7): a last sample the jitter
        // filter held back — under 1.5 pt from the last kept point, e.g.
        // the final creep of a decelerating stroke or a rest before the
        // lift — is recorded now, so the trace's end and its span reach
        // the lift exactly as `beginTouch` makes them start at the
        // pen-down. Only after a kept MOVE: a stationary contact stays a
        // one-sample contact (`keptPointsInStroke`).
        if isSingleTouchInteractionActive,
           let tail = unkeptTail,
           keptPointsInStroke >= 2,
           vm.phaseController.currentPhase == .freeWrite,
           !vm.didCompleteCurrentLetter {
            vm.freeWriteRecorder.record(point: tail.point,
                                        timestamp: tail.timestamp,
                                        force: tail.force,
                                        canvasSize: tail.canvasSize)
        }
        lastLiftAt                     = lastTimestamp
        lastLiftEndedLetter            = vm.strokeTracker.isComplete || vm.didCompleteCurrentLetter
        unkeptTail                     = nil
        lastKeptPoint                  = nil
        keptPointsInStroke             = 0
        isSingleTouchInteractionActive = false
        lastPoint                      = nil
        lastTimestamp                  = nil
        vm.activePath.removeAll(keepingCapacity: true)
        smoothedVelocity               = 0
        vm.pencilPressure              = nil
        vm.pencilAzimuth               = 0
        vm.playback.resumeIntent       = false
        vm.playback.cancelPending()
        settleCouplingAtLift(holdingSound: vm.playback.state == .active)   // B17/B18
        if vm.playback.state == .active, lastLiftEndedLetter {
            // The letter's LAST stroke ended: fade at once, no hold (RULINGS 2026-11-05).
            vm.playback.requestLetterEndIdle()
            vm.playback.forceIdle()
        } else if vm.playback.state == .active {
            // The pen was sounding: keep it sounding through the lift hold, so a child moving to the
            // next stroke does not hear the sound cut (2026-10-05). The hold is the child's own:
            // `StrokeTempo.holdSeconds`, seeded with `SoundEnvelope.liftHoldSeconds` (0.8 s). A
            // re-touch inside the hold cancels the stop.
            vm.playback.requestIdleAfterHold(vm.strokeTempo.holdSeconds)
        } else {
            let cmd = vm.playback.transition(to: .idle)
            vm.playback.apply(cmd)
            if cmd == .none { vm.audio.stop(); vm.isPlaying = false }
            vm.playback.forceIdle()
        }

        // FreeWrite advance: lift-then-quiet is the implicit "done"
        // signal; re-touch within the window cancels. A system cancel is
        // not a lift (R-024): the child's next real lift arms it.
        if !cancelled,
           vm.phaseController.currentPhase == .freeWrite,
           !vm.didCompleteCurrentLetter,
           // A one-sample contact (a palm), or one spanning under 2% of
           // the canvas (a creeping palm, r7), is not a production.
           StrokeProcessScorer.isProduction(points: vm.freeWritePoints, canvasSize: vm.canvasSize) {
            scheduleFreeWriteAutoAdvance()
        }
    }

    /// Read-only: whether a lift has scheduled the free-write quiet-window
    /// advance and it has not fired or been cancelled yet. Lets a test
    /// see the lift's decision without waiting out the 2.0 s window.
    var isFreeWriteAdvanceScheduled: Bool { freeWriteAutoAdvanceTask != nil }

    /// A freeWrite stroke the SYSTEM cancelled (R-024: no quiet window)
    /// and no later stroke or window since. An interruption's resume arms
    /// the window for it, so the trial does not wait for another lift or
    /// the chevron — whether the cancel came before or inside the
    /// interruption (UIKit may cancel the touch before the scene goes
    /// inactive). Cleared by a new stroke, an armed window or a reset.
    private(set) var cancelledStrokeAwaitsWindow = false

    /// Hold the free-writing quiet window for an interruption (R-005):
    /// cancels a pending window and reports whether there was one, so the
    /// resume can re-arm it.
    func holdFreeWriteAutoAdvance() -> Bool {
        guard let task = freeWriteAutoAdvanceTask else { return false }
        task.cancel()
        freeWriteAutoAdvanceTask = nil
        return true
    }

    /// Re-arm a held quiet window — a fresh `freeWriteQuietSeconds` —
    /// under the same conditions a lift arms it.
    func rearmFreeWriteAutoAdvance() {
        guard let vm,
              vm.phaseController.currentPhase == .freeWrite,
              !vm.didCompleteCurrentLetter,
              !isSingleTouchInteractionActive,
              StrokeProcessScorer.isProduction(points: vm.freeWritePoints, canvasSize: vm.canvasSize)
        else { return }
        scheduleFreeWriteAutoAdvance()
    }

    /// Forget a cancelled stroke's claim on a window (a participant
    /// switch, a blocked resume).
    func clearCancelledStroke() {
        cancelledStrokeAwaitsWindow = false
    }

    // MARK: - State-clearing entry points

    /// Reset all owned state. Called by VM transitions so a stale
    /// `lastPoint` can't bleed across sessions.
    func resetTouchState() {
        lastRetryCueAt                 = nil
        isSingleTouchInteractionActive = false
        lastPoint                      = nil
        lastTimestamp                  = nil
        lastKeptPoint                  = nil
        unkeptTail                     = nil
        keptPointsInStroke             = 0
        smoothedVelocity               = 0
        freeWriteAutoAdvanceTask?.cancel()
        freeWriteAutoAdvanceTask = nil
        lastLiftAt                     = nil
        lastLiftEndedLetter            = false
        letterEndLatched               = false
        cancelledStrokeAwaitsWindow    = false
    }

    /// Clear the velocity smoother without touching the active flag,
    /// for transitions that swap the tracker mid-gesture.
    func resetVelocity() {
        smoothedVelocity = 0
    }

    // MARK: - Private helpers

    /// Resync `vm.canvasSize` with what the overlay reports. Closes the
    /// rotation race where canvasSize.didSet has reloaded checkpoints
    /// but the overlay still carries the old size.
    private func resyncCanvasSizeIfNeeded(_ canvasSize: CGSize) {
        guard let vm else { return }
        guard canvasSize != vm.canvasSize,
              !vm.letters.isEmpty,
              vm.letterIndex < vm.letters.count else { return }
        // Assign the VM's size (its didSet re-flows the cells and reloads
        // the checkpoints in that order) instead of doing both here while
        // `vm.canvasSize` stayed stale — the scorer and the persisted
        // RawTrace read `vm.canvasSize` (review 2026-09-05).
        vm.canvasSize = canvasSize
    }

    /// Push the live "checkpoints per second" figure into the recorder
    /// during guided / freeWrite. Silent in observe / direct.
    private func updateGuidedAndFreeWriteSpeed() {
        guard let vm else { return }
        let currentPhase = vm.phaseController.currentPhase
        guard currentPhase == .guided || currentPhase == .freeWrite,
              let def = vm.strokeTracker.definition else { return }
        let completedCPs = def.strokes.enumerated().reduce(0) { acc, item in
            let (idx, stroke) = item
            guard vm.strokeTracker.progress.indices.contains(idx) else { return acc }
            return vm.strokeTracker.progress[idx].complete
                ? acc + stroke.checkpoints.count
                : acc + vm.strokeTracker.progress[idx].nextCheckpoint
        }
        vm.freeWriteRecorder.updateSpeed(completedCheckpoints: completedCPs)
    }

    /// Fire stroke-completion haptic + tick if the tracker crossed a
    /// boundary on this update. Per-checkpoint haptics were removed
    /// per user feedback — only stroke completion remains.
    private func fireMovementHaptics(prevStrokeIndex: Int,
                                     prevNextCheckpoint: Int) {
        guard let vm else { return }
        guard vm.feedbackIntensity > 0 else { return }
        let newStrokeIndex    = vm.strokeTracker.currentStrokeIndex
        let newNextCheckpoint = vm.strokeTracker.progress.indices.contains(prevStrokeIndex)
            ? vm.strokeTracker.progress[prevStrokeIndex].nextCheckpoint : 0
        guard prevNextCheckpoint != newNextCheckpoint
              || newStrokeIndex != prevStrokeIndex else { return }
        if vm.strokeTracker.progress.indices.contains(prevStrokeIndex)
            && vm.strokeTracker.progress[prevStrokeIndex].complete {
            vm.haptics.fire(.strokeCompleted)
            vm.prompts.playStrokeTick()
        }
    }

    // MARK: - Lift tail rate (B17) and per-frame spatial pitch (B18)

    /// Ruling B17 (2026-11-02, AUDIO-3): the sound held through the lift
    /// (`SoundEnvelope.liftHoldSeconds` plus the fade) kept the rate of the
    /// LAST sample, and a child's lift is often a flick — measured: 0.62×
    /// while writing, 2.0× for the 1.4 s tail after a 30 ms flick, so the
    /// phoneme arm heard its phone at double speed after the child had
    /// finished. The tail now runs at the smoothed (EWMA) rate as it was
    /// `liftFlickWindowSeconds` before the lift. A batch value: it spans a
    /// flick (the measured one was 30 ms) and is short against a stroke.
    static let liftFlickWindowSeconds: CFTimeInterval = 0.1
    /// (touch time, smoothed velocity) per sample of the current stroke,
    /// the last ~0.5 s only.
    private var velocityHistory: [(t: CFTimeInterval, v: CGFloat)] = []
    /// The coupling last applied on the touch path (rate, pan, pitch).
    private var lastCouplingParameters: ArmCoupling.Parameters?
    /// R18 slice 5: the pen's movement direction (cell fractions) for the direction dimension.
    private var movementTracker = StrokeMovementTracker()
    /// R20: how far above the mute threshold the movement cosine must rise before a muted pen is audible again
    /// (`StrokeTone.releaseMarginCosine`; a seam so the chatter sweep can vary it).
    var directionReleaseMarginCosine: Float = StrokeTone.releaseMarginCosine
    /// R18DIM slice 7: the pen's stop-start meter, fed from the raw (unsmoothed) per-sample displacement.
    private var dysfluencyMeter = DysfluencyMeter()

    /// Ruling B18 (2026-11-02, AUDIO-4): the spatial pitch is written at
    /// most once per display frame instead of on every coalesced touch
    /// sample. Shorter than one 120 Hz frame (8.3 ms) and longer than the
    /// spread of one frame's coalesced samples, which arrive in the same
    /// run-loop turn. The first sample of a stroke always writes.
    static let spatialPitchMinimumInterval: CFTimeInterval = 0.006
    private var lastPitchWriteAt: CFTimeInterval?
    /// A pitch a throttled sample did not write; flushed at the lift.
    private var pendingPitchCents: Float?
    /// Test seam: the clock the pitch throttle reads.
    var pitchClock: () -> CFTimeInterval = { CACurrentMediaTime() }

    private func writeSpatialPitchPerFrame(_ cents: Float, audio: AudioControlling) {
        let now = pitchClock()
        if let last = lastPitchWriteAt, now - last < Self.spatialPitchMinimumInterval {
            pendingPitchCents = cents
            return
        }
        audio.setSpatialPitch(cents: cents)
        lastPitchWriteAt = now
        pendingPitchCents = nil
    }

    /// The smoothed velocity before the lift's flick: the latest sample at
    /// least `liftFlickWindowSeconds` older than the last one; for a stroke
    /// shorter than that, its first sample.
    private func preFlickVelocity() -> CGFloat? {
        guard let last = velocityHistory.last else { return nil }
        let cutoff = last.t - Self.liftFlickWindowSeconds
        return velocityHistory.last(where: { $0.t <= cutoff })?.v ?? velocityHistory.first?.v
    }

    /// At the lift: freeze the held tail at the pre-flick rate (B17) and
    /// write a pitch the throttle held back (B18); then forget the stroke.
    private func settleCouplingAtLift(holdingSound: Bool) {
        // R19 (N10): the direction mute belongs to the movement it was measured on; the tail after a lift
        // (and the sound the engine keeps) is never muted by a past reversal.
        if let vm, lastCouplingParameters?.strokeTone?.muted == true { vm.audio.setStrokeMute(false) }
        if holdingSound, let vm, let last = lastCouplingParameters {
            if let v = preFlickVelocity() {
                ArmCoupling.applyRateAndPan(
                    ArmCoupling.Parameters(speed: ArmCoupling.speed(forVelocity: v,
                                                                           rateCouplingEnabled: vm.rateCoupling),
                                           horizontalBias: last.horizontalBias,
                                           spatialPitchCents: nil),
                    to: vm.audio)
            }
            if let cents = pendingPitchCents { vm.audio.setSpatialPitch(cents: cents) }
        }
        velocityHistory.removeAll(keepingCapacity: true)
        lastCouplingParameters = nil
        movementTracker.reset()
        lastPitchWriteAt = nil
        pendingPitchCents = nil
    }

    /// Map smoothed velocity + canvas-x to audio time-stretch speed
    /// and stereo pan, then drive the playback state machine.
    private func updateAdaptivePlayback(canvasNormalized: CGPoint, cellPoint: CGPoint, cellAspect: CGFloat,
                                         at t: CFTimeInterval) {
        guard let vm else { return }
        // A blocked session plays no arm sound (r14; AUDIO-5): a stroke
        // still moving when the block came up (a headphone loss
        // mid-stroke) used to re-activate the sound on the new route —
        // the loudspeaker — on its very next movement.
        if vm.sessionBlockReason != nil || letterEndLatched {
            vm.playback.request(.idle, immediate: true)
            return
        }
        // Silent arm: no audio content (activeAudioFiles returns [] so no
        // file ever loaded) AND no coupling. Short-circuit BEFORE any
        // setAdaptivePlayback so the coupling drive never fires and no
        // playback can resume. The two SOUND arms fall through to the
        // identical path below — only the loaded file differs, never the
        // coupling (§2.6 matching discipline).
        if vm.audioCondition == .silent {
            vm.playback.request(.idle, immediate: true)
            return
        }
        // COLD PROBES ARE SILENT IN EVERY ARM (protocol r12, David
        // 2026-10-21, option C: "probes silent"). A pretest, post-test or
        // delayed probe (`startColdProbe(letter:kind:)`, rows stamped with
        // `PhaseSessionRecord.probe`) requests no arm sound and drives no
        // coupling, so every arm is tested under the same sound-off
        // condition and a probe score is not sound-guided performance.
        // Short-circuited here, BEFORE `ArmCoupling.apply`, exactly like
        // the silent arm above. The predicate is `currentProbe != nil`:
        // `load(letter:)` sets it from the one-shot probe override and
        // clears it on every training load, and it is what the rows are
        // stamped with — so the gate and the record cannot disagree about
        // which freeWrite was a probe.
        //
        // The session's OWN freeWrite keeps the arm's sound (practice):
        // sound-off freeWrite was the 2026-09-04 design, LIFTED 2026-10-02
        // on the proctor's instruction ("no audio for the free write
        // mode" — the child heard the guided pass with sound and the
        // unassisted draw in silence, two different activities). r12
        // restores sound-off for the outcome passes only, which is where
        // the thesis (Ch.2 §2.5, Ch.6, the DECISIONS.md header) already
        // places it — the code now matches it.
        if vm.currentProbe != nil {
            vm.playback.request(.idle, immediate: true)
            return
        }
        let azimuthBias = vm.pencilPressure != nil ? cos(vm.pencilAzimuth) * 0.2 : 0
        // Rate from velocity; pan follows absolute x across the whole
        // canvas (not the active cell), so a right-hand cell sounds from
        // the right; spatial arm only: y drives the carrier pitch
        // (220–880 Hz linear-in-cents, top = high). ONE mapping, shared
        // with the observe animation's dot (`ArmCoupling`, 2026-10-05).
        //
        // Pan is suppressed by the comparison switch (2026-09-17) — the
        // supervisor's "auch ohne Panning". Zeroing the bias leaves the
        // rate coupling AND the spatial arm's pitch drive untouched, so
        // each arm stays itself and only the pan axis goes. Applied at the
        // CALL SITE rather than inside `AudioEngine`, whose
        // `setAdaptivePlayback` is the shared three-parameter seam the arms
        // are matched through — and which is on the DO-NOT list. The
        // phoneme arm never gets a pitch drive: the arms are matched on
        // rate + pan and differ in pitch-drive + sound identity (§2.6).
        // R18 slices 4+5: stroke tone, only when a switch is on (else nil: nothing computed, nothing written).
        var strokeTone: StrokeTone?
        if vm.distanceToneEnabled || vm.directionMuteEnabled {
            let movement = movementTracker.movement(to: cellPoint, aspect: cellAspect,
                                                    gateRadius: vm.strokeGateRadius(),
                                                    at: t, stallSeconds: vm.strokeTempo.stallSeconds)
            strokeTone = vm.strokeToneParameters(cellPoint: cellPoint, movement: movement,
                                                 wasMuted: lastCouplingParameters?.strokeTone?.muted == true,
                                                 releaseMarginCosine: directionReleaseMarginCosine)
        }
        let coupling = ArmCoupling.parameters(canvasNormalized: canvasNormalized,
                                              velocity: smoothedVelocity,
                                              azimuthBias: azimuthBias,
                                              panningEnabled: vm.panningEnabled,
                                              rateCouplingEnabled: vm.rateCoupling,
                                              arm: vm.audioCondition,
                                              pitch: vm.pitchCoupling,
                                              strokeTone: strokeTone,
                                              force: vm.pencilPressure,
                                              pressureLoudnessEnabled: vm.pressureLoudnessEnabled,
                                              pressureRangeDB: Float(vm.pressureLoudnessRangeDB),
                                              dysfluency: lastTimestamp.map { dysfluencyMeter.roughness(at: $0) } ?? 0,
                                              roughnessEnabled: vm.dysfluencyRoughness)
        ArmCoupling.applyRateAndPan(coupling, to: vm.audio)
        ArmCoupling.applyStrokeTone(coupling, to: vm.audio)
        ArmCoupling.applyPressureGain(coupling, to: vm.audio)
        if let cents = coupling.spatialPitchCents {
            writeSpatialPitchPerFrame(cents, audio: vm.audio)   // B18
        }
        lastCouplingParameters = coupling
        // B17: the rate history the lift's tail is frozen from. Stamped
        // with the touch clock of the sample before this one (this
        // sample's own is stored after the update); one sample's offset
        // is immaterial against the 0.1 s window.
        if let stamp = lastTimestamp {
            velocityHistory.append((stamp, smoothedVelocity))
            if let first = velocityHistory.first, stamp - first.t > 0.5 {
                velocityHistory.removeAll { stamp - $0.t > 0.5 }
            }
        }

        // No feedbackIntensity gate here: the letter sound is the
        // phonemic anchor for the glyph, not Schmidt & Lee guidance
        // feedback. Haptics + ticks that DO fade are gated separately.
        //
        // The proximity gate is the WHOLE activation test (2026-10-04,
        // proctor: "guided should be audible too"). The velocity floor
        // defaulting to 22 pt/s made this ANDed pair bind on speed, not
        // on place, and a 5-6 year-old tracing deliberately is slow — so
        // the phase whose entire purpose is guided tracing was the one
        // that could leave a correctly-tracing child in silence. With
        // the floor at its new 0.0 default the second term is vacuous
        // and this reads as what it means: on the letter → audible.
        //
        // Movement-contingency is preserved by `armStallIdle`, not by the
        // floor: a stopped pen sends no samples and falls quiet after one
        // idle debounce. See `playbackActivationVelocityThreshold`.
        //
        // FREE-WRITING IS UNGATED (2026-10-05, protocol r6; D14). The
        // proximity gate measures distance to the reference letter's next
        // checkpoint AT ITS OWN POSITION AND SIZE, so in free-writing it
        // was a mask: a letter written anywhere else, or larger or smaller,
        // fell silent. David: the letter's mask must go — "it must be
        // tracked wherever on the screen it is drawn". In free-writing
        // (the session's free-write; cold probes are silent since r12 and
        // returned above) the sound arms' sound follows the pen anywhere
        // on the canvas (the out-of-bounds edge above still stops it).
        // Guided keeps the gate.
        let ungated             = vm.phaseController.currentPhase == .freeWrite
        let shouldPlayForStroke = Self.proximityAllowsSound(ungatedPhase: ungated,
                                                            gatingEnabled: soundGatingEnabled,
                                                            isNearStroke: vm.strokeTracker.isNearStroke)
        let shouldBeActive      = shouldPlayForStroke
                                  && smoothedVelocity >= playbackActivationVelocityThreshold
        vm.playback.request(shouldBeActive ? .active : .idle, immediate: shouldBeActive)
    }

    /// The place half of the activation test, as a value (R18DIM-S3).
    /// Free-writing and a switched-off gate both let the sound follow the
    /// pen anywhere; otherwise it must be near the letter.
    static func proximityAllowsSound(ungatedPhase: Bool, gatingEnabled: Bool,
                                     isNearStroke: Bool) -> Bool {
        ungatedPhase || !gatingEnabled || isNearStroke
    }

    /// Whether `handleStrokeCompletionIfReached` will, on this sample,
    /// finish the whole sequence (and so stop the sound and advance the
    /// phase). Read-only mirror of that function's guards; it must change
    /// with them.
    private func sampleFinishesSequence() -> Bool {
        guard let vm else { return false }
        if vm.studyMode, vm.phaseController.currentPhase == .freeWrite { return false }
        guard vm.strokeTracker.definition?.strokes.isEmpty == false,
              vm.strokeTracker.isComplete,
              !vm.didCompleteCurrentLetter else { return false }
        return vm.grid.activeCellIndex + 1 >= vm.grid.cells.count
    }

    /// Advance the grid cursor when the active cell completes; if the
    /// whole sequence finishes, kick off the phase advance. Guards
    /// against vacuous completion on empty stroke definitions.
    private func handleStrokeCompletionIfReached() {
        guard let vm else { return }
        // Study freeWrite ends ONLY through the pen-lift quiet window
        // (`scheduleFreeWriteAutoAdvance`) — the contract this file's
        // own header states ("FreeWrite has no canonical-stroke
        // completion path") and APP_DOCUMENTATION §6.4.1 / Appendix A
        // document. The tracker keeps running in freeWrite (it feeds
        // `checkpointCoverage`), so without this gate an accurate,
        // canonical-order trace ended the trial the instant its last
        // checkpoint was hit — mid-gesture — while the recorder kept
        // appending until the recognizer returned: the SCORED trace and
        // the PERSISTED raw trace diverged, and the best writers' trials
        // were truncated (missing stroke tails, shorter
        // `phaseDurationSeconds`) in a way correlated with the outcome
        // itself. Study-mode only: the multi-cell word path outside the
        // study relies on this cell advance (2026-09-04).
        if vm.studyMode, vm.phaseController.currentPhase == .freeWrite { return }
        let hasStrokes = (vm.strokeTracker.definition?.strokes.isEmpty == false)
        guard hasStrokes, vm.strokeTracker.isComplete else { return }
        // Snapshot BEFORE advancing — after the grid moves the cursor,
        // `strokeTracker` aliases the next cell.
        let completingCellIndex = vm.grid.activeCellIndex
        let sequenceDone = vm.grid.advanceIfCompleted()
        if !sequenceDone {
            // Retain the just-completed cell's ink so the child sees
            // the letter they wrote as they move on.
            if vm.grid.cells.indices.contains(completingCellIndex) {
                vm.grid.cells[completingCellIndex].activePath = vm.activePath
            }
            vm.activePath.removeAll(keepingCapacity: true)
            // Per-cell audio: child hears "O → M → A" through "OMA".
            vm.autoplayActiveCellLetter()
        } else if !vm.didCompleteCurrentLetter {
            vm.didCompleteCurrentLetter = true
            if vm.feedbackIntensity > 0 { vm.haptics.fire(.letterCompleted) }
            // Stop audio before phase teardown so the letter sound
            // doesn't bleed into the next phase. The letter-end fade is short (ENV3).
            vm.playback.requestLetterEndIdle()
            // Single funnel for phase transitions.
            vm.advanceLearningPhase()
        }
    }

    /// Schedule the freeWrite quiet-window advance.
    /// `freeWriteQuietSeconds` of no re-touch advances the phase,
    /// runs the recognizer, and writes stars via `commitCompletion`.
    private func scheduleFreeWriteAutoAdvance() {
        cancelledStrokeAwaitsWindow = false
        freeWriteAutoAdvanceTask?.cancel()
        let seconds = freeWriteQuietSeconds
        freeWriteAutoAdvanceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self,
                  !Task.isCancelled,
                  let vm = self.vm,
                  vm.phaseController.currentPhase == .freeWrite,
                  !vm.didCompleteCurrentLetter,
                  !self.isSingleTouchInteractionActive else { return }
            self.freeWriteAutoAdvanceTask = nil
            vm.advanceLearningPhase()
        }
    }

    // MARK: - Pure helpers

    /// Map writing velocity (pt/s) to playback rate: mapping M3 (R17D,
    /// RULINGS 2026-11-06; RATE.md section 3a). Rate 1 sits at 150 pt/s
    /// (2.9 cm/s on the study iPad), the range is 0.8x-1.25x: 50 pt/s and
    /// below -> 0.8, 150 -> 1.0, 400 and above -> 1.25, piecewise linear
    /// between. Both sound arms identically. r5-r16 mapped 50 -> 0.5,
    /// 800 -> 2.0 (rate 1 at 300 pt/s, faster than the one measured adult
    /// writer's median of 192 pt/s), so slower writing spent most of a
    /// stroke at 0.5-0.7. 150 pt/s is a judgement between the scripted
    /// 50-150 pt/s, the tracer's 200 and that adult's 192: the one value to
    /// re-tune once child speed data exist. NaN stays NaN (the audio
    /// setter refuses non-finite rates).
    static func mapVelocityToSpeed(_ v: CGFloat) -> Float {
        let low: CGFloat = 50, mid: CGFloat = 150, high: CGFloat = 400
        if v <= low  { return 0.8 }
        if v >= high { return 1.25 }
        if v <= mid  { return Float(0.8 + 0.2 * ((v - low) / (mid - low))) }
        return Float(1.0 + 0.25 * ((v - mid) / (high - mid)))
    }
}
