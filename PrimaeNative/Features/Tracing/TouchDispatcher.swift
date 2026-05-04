// TouchDispatcher.swift
// PrimaeNative
//
// Owns the touch-session state
// (`isSingleTouchInteractionActive`, last point + timestamp,
// smoothed velocity, the three tuning knobs) and the touch-handling
// control flow (`beginTouch` / `updateTouch` / `endTouch` plus the
// private helpers).
//
// Holds a weak reference back to the VM. Retain ownership goes:
// VM strong-owns the dispatcher; dispatcher weakly references the
// VM. State the dispatcher reads/writes during a touch (audio,
// playback, haptics, freeWriteRecorder, strokeTracker, grid,
// phaseController, letters, activePath, progress, …) lives on the
// VM and is reached through the weak ref. The dispatcher owns only
// the small state that's purely about the in-flight touch session.
//
// Views still call into `vm.beginTouch` etc. so the SwiftUI binding
// surface and tests don't change — the VM forwards to the dispatcher.

import CoreGraphics
import Foundation
import QuartzCore

@MainActor
final class TouchDispatcher {

    // MARK: - Owned touch-session state

    /// True while a single-touch tracing gesture is in flight. Cleared
    /// by `endTouch`, `resetTouchState()`, and any state-clearing VM
    /// transition (letter load, phase transition).
    private(set) var isSingleTouchInteractionActive = false
    /// Last seen touch point in canvas pixels. Used to compute distance
    /// + velocity on the next `updateTouch`.
    private(set) var lastPoint: CGPoint?
    private(set) var lastTimestamp: CFTimeInterval?
    /// Exponentially-smoothed touch velocity. Drives both the audio
    /// time-stretch speed and the "should playback be active" gate.
    private(set) var smoothedVelocity: CGFloat = 0

    // MARK: - Tunable knobs (formerly mutated by DebugAudioPanel)

    /// EWMA smoothing factor for `smoothedVelocity`. Calibrated for
    /// iPad-finger writing at ~50–800 pt/s; see `mapVelocityToSpeed`
    /// for the curve they feed.
    var velocitySmoothingAlpha: CGFloat = 0.22
    /// Minimum smoothed velocity (pt/s) before playback transitions to
    /// `.active`. Filters out stationary touches that would otherwise
    /// trigger audio.
    var playbackActivationVelocityThreshold: CGFloat = 22
    /// Minimum per-frame movement before the touch is recorded into
    /// the active path / velocity smoother. Sub-pixel hysteresis so
    /// digitiser noise on a held finger doesn't accumulate spurious
    /// motion.
    var minimumTouchMoveDistance: CGFloat = 1.5

    // MARK: - Back-reference

    /// The VM that constructed this dispatcher. Weak so the dispatcher
    /// doesn't retain its parent. Set once by `TracingViewModel.init`
    /// after `self.touchDispatcher = pb` to satisfy two-phase init —
    /// the same trick used for `playback` (W-16).
    weak var vm: TracingViewModel?

    /// Scheduled freeWrite auto-advance. The child's freeform writing
    /// rarely satisfies the canonical-stroke `strokeTracker.isComplete`
    /// check (no rails to follow), so the existing
    /// `handleStrokeCompletionIfReached` path almost never fires
    /// during freeWrite. Without an explicit completion signal the
    /// child got stuck — they could write forever but the celebration
    /// + commitCompletion never ran. The fix: when they lift in
    /// freeWrite, schedule a quiet-window task that advances the
    /// phase ~2 s later. A re-touch within that window cancels the
    /// task (they're still writing).
    private var freeWriteAutoAdvanceTask: Task<Void, Never>?
    private let freeWriteQuietSeconds: TimeInterval = 2.0

    /// Tracks whether the previous in-stroke sample was inside the
    /// canvas, so we only fire the out-of-bounds warning + audio stop
    /// once on the rising edge (in→out) instead of every frame the
    /// finger is held outside.
    private var wasInBounds: Bool = true

    // MARK: - Public API (forwarded from VM)

    func beginTouch(at p: CGPoint, t: CFTimeInterval) {
        guard let vm else { return }
        guard vm.phaseController.isTouchEnabled       else { return }
        guard vm.phaseController.currentPhase != .direct else { return }  // handled by DirectPhaseDotsOverlay
        guard !isSingleTouchInteractionActive         else { return }

        // Re-touch during a freeWrite quiet window cancels the
        // pending auto-advance — the child is still writing.
        freeWriteAutoAdvanceTask?.cancel()
        freeWriteAutoAdvanceTask = nil

        isSingleTouchInteractionActive = true
        vm.playback.resumeIntent       = true
        lastPoint                      = p
        lastTimestamp                  = t
        vm.activePath                  = [p]
        wasInBounds                    = true
        // Stroke-boundary marker for freeWrite recognition: the
        // CoreML rasterizer breaks the polyline at these indices so
        // multi-stroke letters (F, E, H) aren't drawn with phantom
        // diagonals across the lifts that would otherwise read as
        // a different glyph (F→P, etc.).
        if vm.phaseController.currentPhase == .freeWrite {
            vm.freeWriteRecorder.beginStroke()
        }
        // Gate on `feedbackIntensity > 0` so freeWrite (which fades
        // all real-time feedback per Schmidt & Lee 2005's Guidance
        // Hypothesis) doesn't fire a stroke-begin haptic. Every other
        // haptic + audio channel already respects this gate.
        if vm.feedbackIntensity > 0 { vm.haptics.fire(.strokeBegan) }
        // Reload audio file — stop() in endTouch clears currentFile, so
        // play() would silently fail on subsequent touches without
        // reloading first.
        if vm.letters.indices.contains(vm.letterIndex) {
            let files = vm.activeAudioFiles(for: vm.letters[vm.letterIndex])
            if files.indices.contains(vm.audioIndex) {
                vm.audio.loadAudioFile(named: files[vm.audioIndex], autoplay: false)
            }
        }
    }

    func updateTouch(at p: CGPoint, t: CFTimeInterval, canvasSize: CGSize) {
        guard let vm else { return }
        guard isSingleTouchInteractionActive else { return }
        guard let lastPoint                  else { return }

        resyncCanvasSizeIfNeeded(canvasSize)

        let isWithinCanvasBounds =
            p.x >= 0 && p.y >= 0 && p.x <= canvasSize.width && p.y <= canvasSize.height

        // Out-of-bounds rising edge: stop the letter audio, wipe the
        // partial stroke + ink trail, and tell the child to retrace.
        // Toast covers the on-screen prompt; speech.speak handles
        // the audio (5–6 yr-olds can't reliably read the toast). The
        // partial-progress reset means the touch has to retrace the
        // current stroke from its first checkpoint when the finger
        // re-enters the canvas. Fires once per crossing (state
        // cleared by `wasInBounds`).
        if wasInBounds && !isWithinCanvasBounds {
            vm.audio.stop()
            vm.isPlaying = false
            vm.playback.cancelPending()
            vm.playback.forceIdle()
            vm.strokeTracker.resetCurrentStroke()
            vm.activePath.removeAll(keepingCapacity: true)
            vm.toast("Probier's nochmal")
            vm.speech.speak("Probier's nochmal")
        }
        wasInBounds = isWithinCanvasBounds

        let dx       = p.x - lastPoint.x
        let dy       = p.y - lastPoint.y
        let distance = hypot(dx, dy)

        if isWithinCanvasBounds && distance >= minimumTouchMoveDistance {
            vm.activePath.append(p)
            // Accumulate for free-write scoring + KP overlay. The recorder
            // owns the four-buffer state so the dispatcher body doesn't
            // re-derive canvas normalisation per touch.
            if vm.phaseController.currentPhase == .freeWrite {
                vm.freeWriteRecorder.record(point: p,
                                            timestamp: t,
                                            force: vm.pencilPressure ?? 0,
                                            canvasSize: canvasSize)
            }
        }

        if let lastTimestamp {
            let dt       = max(0.001, t - lastTimestamp)
            let velocity = distance / dt
            smoothedVelocity = smoothedVelocity == 0
                ? velocity
                : smoothedVelocity + velocitySmoothingAlpha * (velocity - smoothedVelocity)
        } else {
            self.lastTimestamp = t
        }

        // Canvas-normalised coords (0–1 over the whole canvas) — used for
        // audio stereo panning so writing in the right-hand cell of a
        // pencil layout pans right.
        let canvasNormalized = CGPoint(x: p.x / max(canvasSize.width, 1),
                                       y: p.y / max(canvasSize.height, 1))
        // Cell-normalised coords (0–1 over the active cell's frame) —
        // fed to the active cell's stroke tracker, whose checkpoints
        // live in the cell's own 0–1 space. For a length-1 finger
        // sequence the frame equals the whole canvas, so this is
        // identical to canvasNormalized.
        let activeFrame = vm.grid.activeCell.frame
        let normalized: CGPoint
        if activeFrame.width > 0 && activeFrame.height > 0 {
            normalized = CGPoint(
                x: (p.x - activeFrame.minX) / activeFrame.width,
                y: (p.y - activeFrame.minY) / activeFrame.height
            )
        } else {
            normalized = canvasNormalized
        }
        let prevStrokeIndex    = vm.strokeTracker.currentStrokeIndex
        let prevNextCheckpoint = vm.strokeTracker.progress.indices.contains(prevStrokeIndex)
            ? vm.strokeTracker.progress[prevStrokeIndex].nextCheckpoint : 0
        let wasComplete        = vm.strokeTracker.isComplete

        vm.strokeTracker.update(normalizedPoint: normalized)

        let isNowComplete = vm.strokeTracker.isComplete
        if !wasComplete && isNowComplete, vm.feedbackIntensity > 0 {
            vm.haptics.fire(.letterCompleted)
        }
        // Aggregate across all cells so the progress bar tracks the
        // whole sequence, not just the active cell. For a length-1
        // sequence this reduces to the active (and only) cell's
        // overallProgress.
        vm.progress = vm.grid.aggregateProgress

        updateGuidedAndFreeWriteSpeed()

        fireMovementHaptics(prevStrokeIndex: prevStrokeIndex,
                            prevNextCheckpoint: prevNextCheckpoint)

        updateAdaptivePlayback(canvasNormalized: canvasNormalized)

        handleStrokeCompletionIfReached()

        self.lastPoint     = p
        self.lastTimestamp = t
    }

    func endTouch() {
        guard let vm else { return }
        isSingleTouchInteractionActive = false
        lastPoint                      = nil
        lastTimestamp                  = nil
        vm.activePath.removeAll(keepingCapacity: true)
        smoothedVelocity               = 0
        vm.pencilPressure              = nil
        vm.pencilAzimuth               = 0
        vm.playback.resumeIntent       = false
        vm.playback.cancelPending()
        let cmd = vm.playback.transition(to: .idle)
        vm.playback.apply(cmd)
        if cmd == .none { vm.audio.stop(); vm.isPlaying = false }
        vm.playback.forceIdle()

        // FreeWrite has no canonical-stroke completion path (the child
        // writes freely without rails), so without an explicit signal
        // the phase never advances and `commitCompletion` never fires.
        // Treat lift-then-quiet as the implicit "I'm done" — schedule
        // advance, cancel if the child re-touches within the window.
        if vm.phaseController.currentPhase == .freeWrite,
           !vm.didCompleteCurrentLetter,
           !vm.freeWritePoints.isEmpty {
            scheduleFreeWriteAutoAdvance()
        }
    }

    // MARK: - State-clearing entry points (called by VM transitions)

    /// Reset every owned bit of state. Called from VM letter load,
    /// `resetForPhaseTransition`, and other transitions that need to
    /// drop any in-flight gesture so a stale `lastPoint` can't bleed
    /// into the next session (W-6).
    func resetTouchState() {
        isSingleTouchInteractionActive = false
        lastPoint                      = nil
        lastTimestamp                  = nil
        smoothedVelocity               = 0
        // Phase transitions / letter loads invalidate any pending
        // freeWrite quiet-window advance — the phase that scheduled
        // it is no longer active.
        freeWriteAutoAdvanceTask?.cancel()
        freeWriteAutoAdvanceTask = nil
    }

    /// Clear just the velocity smoothing without touching the active
    /// flag. Used when a transition replaces the live tracker /
    /// definition without ending the gesture itself.
    func resetVelocity() {
        smoothedVelocity = 0
    }

    // MARK: - Private helpers (formerly on the VM)

    /// Bring `vm.canvasSize` (and the cell layout / checkpoint mapping
    /// that derive from it) back in sync with whatever the touch
    /// overlay is currently reporting. Closes the window where a
    /// rotation/layout update has already fired `canvasSize.didSet`
    /// (reloading checkpoints for the new size) but the touch overlay
    /// coordinator still carries the previous size, causing
    /// normalizedPoint vs. checkpoint coordinate mismatch.
    private func resyncCanvasSizeIfNeeded(_ canvasSize: CGSize) {
        guard let vm else { return }
        guard canvasSize != vm.canvasSize,
              !vm.letters.isEmpty,
              vm.letterIndex < vm.letters.count else { return }
        // Re-flow cell frames with the overlay-reported size BEFORE
        // reloading checkpoints — reload now maps per-cell using each
        // cell's own frame.
        vm.grid.layout(in: canvasSize, schriftArt: vm.schriftArt)
        vm.reloadStrokeCheckpoints(for: vm.letters[vm.letterIndex],
                                    usingSize: canvasSize)
    }

    /// Push the live "checkpoints per second" figure into the recorder
    /// while the user is in guided or freeWrite. Stays silent in
    /// observe / direct since those phases have no continuous motion
    /// to measure.
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

    /// Trigger checkpoint or stroke-completed haptics if the tracker
    /// crossed a boundary on this touch update. Compares the snapshot
    /// taken before `strokeTracker.update(...)` to the post-update
    /// state.
    private func fireMovementHaptics(prevStrokeIndex: Int,
                                     prevNextCheckpoint: Int) {
        guard let vm else { return }
        guard vm.feedbackIntensity > 0 else { return }
        let newStrokeIndex    = vm.strokeTracker.currentStrokeIndex
        let newNextCheckpoint = vm.strokeTracker.progress.indices.contains(prevStrokeIndex)
            ? vm.strokeTracker.progress[prevStrokeIndex].nextCheckpoint : 0
        guard prevNextCheckpoint != newNextCheckpoint
              || newStrokeIndex != prevStrokeIndex else { return }
        // Per-user request: only the stroke-completion tick remains.
        // The per-checkpoint haptic + audio fired potentially dozens
        // of times per stroke and the user found it distracting.
        if vm.strokeTracker.progress.indices.contains(prevStrokeIndex)
            && vm.strokeTracker.progress[prevStrokeIndex].complete {
            vm.haptics.fire(.strokeCompleted)
            vm.prompts.playStrokeTick()
        }
    }

    /// Map the smoothed velocity + canvas-x to the audio engine's
    /// time-stretch speed and stereo pan, then ask the playback state
    /// machine whether the underlying source should be active or
    /// idle.
    private func updateAdaptivePlayback(canvasNormalized: CGPoint) {
        guard let vm else { return }
        let speed       = Self.mapVelocityToSpeed(smoothedVelocity)
        let azimuthBias = vm.pencilPressure != nil ? cos(vm.pencilAzimuth) * 0.2 : 0
        // Pan follows the absolute x across the whole canvas, not the
        // active cell — so a cell on the right still sounds from the
        // right regardless of cell-local normalisation.
        let hBias = Float(max(-1.0, min(1.0, (canvasNormalized.x * 2.0 - 1.0) + azimuthBias)))
        vm.audio.setAdaptivePlayback(speed: speed, horizontalBias: hBias)

        // No `feedbackIntensity > 0.3` gate: the letter sound is the
        // phonemic anchor for the glyph, not "guidance feedback" in
        // the Schmidt & Lee sense (the haptics + checkpoint ticks
        // that DO fade in freeWrite are gated separately). Children
        // need the audio cue throughout, including freeWrite where
        // the rest of the scaffolding is gone.
        let shouldPlayForStroke = vm.strokeTracker.isNearStroke
        let shouldBeActive      = shouldPlayForStroke
                                  && smoothedVelocity >= playbackActivationVelocityThreshold
        vm.playback.request(shouldBeActive ? .active : .idle, immediate: shouldBeActive)
    }

    /// If the active cell's tracker just completed, advance the grid
    /// cursor to the next cell — or, if the whole sequence is done,
    /// kick off the phase advance. Guards against vacuous completion
    /// (empty stroke definitions, where `isComplete` would be trivially
    /// true).
    private func handleStrokeCompletionIfReached() {
        guard let vm else { return }
        let hasStrokes = (vm.strokeTracker.definition?.strokes.isEmpty == false)
        guard hasStrokes, vm.strokeTracker.isComplete else { return }
        // Snapshot tracker-derived values BEFORE advancing — after the
        // grid moves the cursor, `strokeTracker` aliases the next cell
        // (fresh state, zero progress).
        let completingCellIndex = vm.grid.activeCellIndex
        let sequenceDone = vm.grid.advanceIfCompleted()
        if !sequenceDone {
            // Retain the just-completed cell's ink so it stays on
            // screen — preserves the child's written letter as they
            // move on to the next cell. VM activePath clears so the
            // next cell's tracing starts with a blank slate.
            if vm.grid.cells.indices.contains(completingCellIndex) {
                vm.grid.cells[completingCellIndex].activePath = vm.activePath
            }
            vm.activePath.removeAll(keepingCapacity: true)
            // Play the next cell's letter audio so the child hears
            // "O → M → A" as they trace through "OMA". Per-cell
            // audio policy per the thesis-plan v1. Silent for
            // letters without an audio asset in the inventory.
            vm.autoplayActiveCellLetter()
        } else if !vm.didCompleteCurrentLetter {
            vm.didCompleteCurrentLetter = true
            if vm.feedbackIntensity > 0 { vm.haptics.fire(.letterCompleted) }
            // Stop audio before phase teardown so the child doesn't
            // hear the letter sound bleed into the next phase.
            vm.playback.request(.idle, immediate: true)
            // Route through advanceLearningPhase() so phase transitions
            // always go through one path:
            //   guided     → freeWrite  (phaseController.advance returns true)
            //   guided     → complete   (guidedOnly/control: returns false → celebration)
            //   freeWrite  → complete   (threePhase: returns false → celebration)
            vm.advanceLearningPhase()
        }
    }

    /// Schedule the freeWrite quiet-window advance. After
    /// `freeWriteQuietSeconds` of no re-touch the phase advances —
    /// running the recognizer, the celebration, and (critically)
    /// `commitCompletion`, which is what writes stars to the
    /// progress store. Cancellation paths: re-touch in `beginTouch`,
    /// any phase transition / letter load via `resetTouchState`, or
    /// the guard checks below if state shifted while we slept.
    private func scheduleFreeWriteAutoAdvance() {
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

    /// Map writing velocity to playback rate: slow tracing = slow
    /// audio, fast = fast. Range calibrated to iPad finger writing:
    /// ~50 pt/s (careful) to ~800 pt/s (quick). Rate 1.0 at ~300 pt/s
    /// (normal writing pace). Linear interpolation between the bounds;
    /// clamps at 0.5 and 2.0 outside.
    ///
    /// Static + same shape as the prior VM-resident helper so this
    /// extraction is a pure structural move with no behaviour change.
    static func mapVelocityToSpeed(_ v: CGFloat) -> Float {
        let low: CGFloat = 50, high: CGFloat = 800
        if v <= low  { return 0.5 }
        if v >= high { return 2.0 }
        return Float(0.5 + 1.5 * ((v - low) / (high - low)))
    }
}
