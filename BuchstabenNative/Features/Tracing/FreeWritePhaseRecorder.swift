// FreeWritePhaseRecorder.swift
// BuchstabenNative
//
// Owns the four buffers (canvas-space points, timestamps, forces,
// normalised KP path) plus session-timing state that the freeWrite
// phase produces. Extracted from TracingViewModel during the W8
// God-object refactor so the buffer lifecycle (start session → record
// touch → score → reset) lives in one place instead of being
// spread across `updateTouch`, `advanceLearningPhase`, and
// `resetForPhaseTransition`.
//
// The VM still owns the touch-handling site that decides *whether*
// to record (gated on `phaseController.currentPhase == .freeWrite`),
// because that decision needs the broader phase context. The
// recorder is intentionally MainActor-bound so reads from views
// can access the buffers directly without thread hops.

import CoreGraphics
import Foundation
import QuartzCore

@MainActor
@Observable
final class FreeWritePhaseRecorder {

    // MARK: - Tap-emitted state (read by views via VM forwarders)

    /// Canvas-space points appended during freeWrite touches.
    private(set) var points: [CGPoint] = []
    /// `CACurrentMediaTime()` for each point in `points`.
    private(set) var timestamps: [CFTimeInterval] = []
    /// Digitiser force per point (0 for finger / no pencil data).
    private(set) var forces: [CGFloat] = []
    /// Same path normalised to 0–1 over the canvas — used by the KP
    /// overlay so it can render at any geometry without re-mapping.
    private(set) var path: [CGPoint] = []
    /// `CACurrentMediaTime()` at session start. Drives `rhythmScore`.
    private(set) var sessionStart: CFTimeInterval = 0
    /// `CACurrentMediaTime()` when the active guided / freeWrite phase
    /// began. Drives `checkpointsPerSecond` automatisation tracking.
    private(set) var activePhaseStart: CFTimeInterval = 0
    /// Live checkpoints-per-second figure surfaced on the dashboard.
    private(set) var checkpointsPerSecond: CGFloat = 0
    /// Last raw Fréchet distance (0 = perfect). Debug overlay only.
    private(set) var lastDistance: CGFloat = 0
    /// Latest 4-dimension Schreibmotorik assessment. Set by `assess`.
    private(set) var lastAssessment: WritingAssessment? = nil
    /// Captured guided-phase score so the freeWrite chrome can show a
    /// "Nachspuren fertig" feedback band during the transition. Cleared
    /// on `clearAll()`.
    var lastGuidedScore: CGFloat? = nil

    // MARK: - Mutation API

    /// Begin a fresh recording window. Call when entering freeWrite.
    func startSession(now: CFTimeInterval = CACurrentMediaTime()) {
        path.removeAll(keepingCapacity: true)
        points.removeAll(keepingCapacity: true)
        timestamps.removeAll(keepingCapacity: true)
        forces.removeAll(keepingCapacity: true)
        sessionStart = now
        activePhaseStart = now
        checkpointsPerSecond = 0
        lastDistance = 0
        lastAssessment = nil
    }

    /// Begin the speed-tracking window without resetting freeWrite
    /// buffers. Used when entering guided so checkpointsPerSecond reflects
    /// the guided pass while leaving any pending freeWrite KP path
    /// untouched. (FreeWrite buffers reset via `clearAll` on letter
    /// load or via `startSession` when freeWrite itself begins.)
    func startGuidedSpeedTracking(now: CFTimeInterval = CACurrentMediaTime()) {
        activePhaseStart = now
        checkpointsPerSecond = 0
    }

    /// Append one freeWrite touch sample. Pass canvas-space `point` and
    /// the canvas size so the normalised KP `path` stays in 0–1.
    func record(point: CGPoint,
                timestamp: CFTimeInterval,
                force: CGFloat,
                canvasSize: CGSize) {
        points.append(point)
        timestamps.append(timestamp)
        forces.append(force)
        path.append(CGPoint(
            x: point.x / max(canvasSize.width, 1),
            y: point.y / max(canvasSize.height, 1)
        ))
    }

    /// Update the live checkpoints-per-second counter. Called from the
    /// VM with the integer count of completed checkpoints; the recorder
    /// owns the elapsed-time arithmetic.
    func updateSpeed(completedCheckpoints: Int,
                     now: CFTimeInterval = CACurrentMediaTime()) {
        guard activePhaseStart > 0 else { return }
        let elapsed = now - activePhaseStart
        guard elapsed > 0.1 else { return }
        checkpointsPerSecond = CGFloat(completedCheckpoints) / CGFloat(elapsed)
    }

    /// Score the captured trace against `reference` strokes mapped into
    /// canvas-normalised coordinates. Stores the result in
    /// `lastAssessment` for view forwarders and returns the assessment
    /// so the VM can also funnel the score into ProgressStore /
    /// PhaseSessionRecord without re-reading the recorder.
    ///
    /// `cellFrame` must be supplied for multi-cell (pencil) layouts.
    /// The reference strokes are in cell-local 0–1 space; without the
    /// frame offset the canvas-space points normalise to full-canvas
    /// coordinates that never overlap the reference, producing a score
    /// of 0 regardless of writing quality (C-5).
    @discardableResult
    func assess(reference: LetterStrokes,
                canvasSize: CGSize,
                cellFrame: CGRect? = nil,
                now: CFTimeInterval = CACurrentMediaTime()) -> WritingAssessment {
        let frame = cellFrame ?? CGRect(origin: .zero, size: canvasSize)
        let normalised = points.map { p in
            CGPoint(x: (p.x - frame.minX) / max(frame.width, 1),
                    y: (p.y - frame.minY) / max(frame.height, 1))
        }
        let assessment = FreeWriteScorer.score(
            tracedPoints: normalised,
            reference: reference,
            timestamps: timestamps,
            forces: forces,
            sessionStart: sessionStart,
            sessionEnd: now
        )
        lastAssessment = assessment
        lastDistance = FreeWriteScorer.rawDistance(
            tracedPoints: normalised, reference: reference)
        return assessment
    }

    /// Clear every buffer. Called on letter load and on phase
    /// transitions to make sure stale freeWrite state from one letter
    /// can never bleed into another.
    func clearAll() {
        points.removeAll(keepingCapacity: true)
        timestamps.removeAll(keepingCapacity: true)
        forces.removeAll(keepingCapacity: true)
        path.removeAll(keepingCapacity: true)
        sessionStart = 0
        activePhaseStart = 0
        checkpointsPerSecond = 0
        lastDistance = 0
        lastAssessment = nil
        lastGuidedScore = nil
    }
}
