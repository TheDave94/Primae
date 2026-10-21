// TracingGeometryTestHook.swift
// PrimaeNative
//
// TEST-ONLY, DEBUG-ONLY: the whole file is `#if DEBUG`, so none of it
// exists in Release-Study (the pilot artefact). Armed only by the launch
// argument `-tracingGeometryHook`, so a Debug-Study build launched any
// other way renders nothing extra either.
//
// WHY IT EXISTS (2026-10-21, lane H). Every UI-test "drawing" used to be
// one straight two-point drag across the middle of the screen. That
// completes a freeWrite pass (>= 2 points then a quiet window) whatever
// shape is drawn, so no UI test ever drew a letter, and none could tell a
// drawn A from a swipe. To trace the letter properly the test needs the
// letter's strokes in SCREEN coordinates — and that mapping must come
// from the app, not be re-derived in the test: the tracker's checkpoints
// pass through `PrimaeLetterRenderer.normalizedGlyphRect` and the active
// cell's frame (`TracingViewModel.rawGlyphStrokes`,
// `SequenceGridController`), with the weight the app actually loaded. A
// test re-deriving that would be testing its own copy of the geometry.
//
// So this publishes, into the accessibility tree (the only channel shared
// between the app and the XCUI runner — see `debugAudioSignalSummary`),
// exactly what the touch path consumes: the ACTIVE CELL TRACKER's loaded
// checkpoints, mapped cell-fraction -> canvas -> window points by the same
// arithmetic `TouchDispatcher.updateTouch` inverts. Plus the tracker's
// per-stroke progress, the phase, and a log of completed letters with
// their phase scores (a study letter auto-advances the instant it
// completes, so its scores are gone from the controller by the time a
// test could read them).

#if DEBUG
import SwiftUI

/// Completed-letter log for the hook. A singleton because a completed
/// letter's scores must outlive the letter (and the canvas view) — the
/// study auto-advance loads the next letter in the same turn.
@MainActor
@Observable
final class TracingGeometryTestLog {
    static let shared = TracingGeometryTestLog()

    static var isArmedByLaunchArgument: Bool {
        ProcessInfo.processInfo.arguments.contains("-tracingGeometryHook")
    }

    struct Completed {
        let letter: String
        let probe: String?
        let scores: [String: Double]
        let formAccuracy: Double?
        let recognized: String?
        let confidence: Double?
    }

    private(set) var completed: [Completed] = []

    /// Called from `PhaseTransitionCoordinator.recordSessionCompletion`,
    /// i.e. once per completed letter session, before any advance.
    func recordCompletion(of vm: TracingViewModel) {
        guard Self.isArmedByLaunchArgument else { return }
        var scores: [String: Double] = [:]
        for (phase, score) in vm.phaseScores { scores[phase.rawName] = Double(score) }
        completed.append(Completed(
            letter: vm.currentLetterName,
            probe: vm.currentProbe?.rawValue,
            scores: scores,
            formAccuracy: vm.lastWritingAssessment.map { Double($0.formAccuracy) },
            recognized: vm.lastRecognitionResult?.predictedLetter,
            confidence: vm.lastRecognitionResult.map { Double($0.confidence) }))
    }
}

/// The zero-opacity readout. `canvasFrame` is the tracing canvas's frame
/// in window coordinates, i.e. the origin of the point space the touch
/// overlays report in.
struct TracingGeometryTestHookView: View {
    var vm: TracingViewModel
    let canvasFrame: CGRect

    var body: some View {
        if TracingGeometryTestLog.isArmedByLaunchArgument {
            // Periodic, not observation-driven: the tracker is a plain
            // class, so its progress does not invalidate a view.
            TimelineView(.periodic(from: .now, by: 0.2)) { _ in
                let json = Self.snapshot(vm: vm, canvasFrame: canvasFrame,
                                         log: TracingGeometryTestLog.shared)
                Text("·")
                    .accessibilityIdentifier("tracing-geometry-hook")
                    .accessibilityLabel(json)
                    // Same shape as the audio probe readout: `.hidden()`
                    // drops the a11y node; zero opacity keeps it.
                    .opacity(0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(false)
            }
        }
    }

    static func snapshot(vm: TracingViewModel, canvasFrame: CGRect,
                         log: TracingGeometryTestLog) -> String {
        let tracker = vm.strokeTracker
        let cell = vm.grid.activeCell.frame
        func r1(_ v: CGFloat) -> Double { (Double(v) * 10).rounded() / 10 }
        // Cell-fraction -> canvas (the inverse of TouchDispatcher's
        // `normalized`) -> window (+ the canvas origin).
        let strokes: [[[Double]]] = (tracker.definition?.strokes ?? []).map { stroke in
            stroke.checkpoints.map { cp in
                [r1(canvasFrame.minX + cell.minX + cp.x * cell.width),
                 r1(canvasFrame.minY + cell.minY + cp.y * cell.height)]
            }
        }
        let radius = (tracker.definition?.checkpointRadius ?? 0) * tracker.radiusMultiplier
        var dict: [String: Any] = [
            "letter": vm.currentLetterName,
            "phase": vm.learningPhase.rawName,
            "parked": vm.launchParked,
            "blocked": vm.sessionBlockReason != nil,
            "probe": vm.currentProbe?.rawValue ?? "",
            "canvas": [r1(canvasFrame.minX), r1(canvasFrame.minY),
                       r1(canvasFrame.width), r1(canvasFrame.height)],
            "cell": [r1(cell.minX), r1(cell.minY), r1(cell.width), r1(cell.height)],
            "radiusPt": r1(radius * min(cell.width, cell.height)),
            "strokes": strokes,
            "progress": tracker.progress.map { [$0.nextCheckpoint, $0.complete ? 1 : 0] },
            "trackerComplete": tracker.isComplete,
        ]
        var scores: [String: Double] = [:]
        for (phase, score) in vm.phaseScores { scores[phase.rawName] = Double(score) }
        dict["scores"] = scores
        dict["completed"] = log.completed.map { c -> [String: Any] in
            var e: [String: Any] = ["letter": c.letter, "scores": c.scores]
            if let p = c.probe { e["probe"] = p }
            if let f = c.formAccuracy { e["form"] = f }
            if let r = c.recognized { e["rec"] = r }
            if let k = c.confidence { e["conf"] = k }
            return e
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
}
#endif
