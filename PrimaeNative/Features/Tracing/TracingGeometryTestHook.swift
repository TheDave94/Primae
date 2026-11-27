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
//
// 2026-11-23 (FinalTestSessionUITests): also the session's SCREEN and
// SOUND over time — the final-test stage, chrome, the ink the canvas
// actually stroked (`TracingInkDrawProbe`), glyph / pause / end screen /
// check, the main-mixer peak per stage (PopCapture's tap, `-popCapture`)
// and every recorded prompt (`TracingSessionTimeline`). Read-only
// observers: nothing here changes what the child sees or hears.

#if DEBUG
import SwiftUI
import QuartzCore

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

/// What the tracing canvas actually STROKED as ink in its latest frame
/// (2026-11-23, the final-test edges). Recorded from inside the Canvas
/// closure (`TracingCanvasView.drawInk`), so it reports the drawing itself,
/// not a property the drawing is supposed to follow: a canvas that ignored
/// a "hide the ink" decision would still show up here. A plain lock box,
/// not an observable: it is written during rendering.
nonisolated final class TracingInkDrawProbe: @unchecked Sendable {
    static let shared = TracingInkDrawProbe()
    static let isArmed = ProcessInfo.processInfo.arguments.contains("-tracingGeometryHook")

    /// The clock both this probe and `TracingSessionTimeline` stamp with,
    /// so a frame and a timeline entry can be ordered against each other.
    static let epoch = CACurrentMediaTime()
    static func now() -> Double { ((CACurrentMediaTime() - epoch) * 1000).rounded() / 1000 }

    private let lock = NSLock()
    private var layers = 0
    private var box = CGRect.null

    /// One DRAWN canvas frame (2026-11-23, the glimpse's first frame): what
    /// the closure was handed (letter, final-test stage, glyph drawn) and
    /// the ink it then stroked. Read at draw time, from inside the Canvas
    /// closure, so it is the content of that frame, not a model sample
    /// paired with the previous frame's ink (the timeline's limit).
    struct Frame: Equatable {
        var t: Double
        var letter: String
        var stage: String
        var glyph: Bool
        var ink: Int
        func sameContent(_ o: Frame) -> Bool {
            letter == o.letter && stage == o.stage && glyph == o.glyph && ink == o.ink
        }
    }
    /// Frames whose content differs from the frame before (a run of
    /// identical frames is kept as its first), plus the frame in progress.
    private var frames: [Frame] = []
    private var current: Frame?
    /// Model-side final-test stage changes, stamped at the assignment
    /// (`TracingViewModel.finalTestStage`'s DEBUG observer).
    private var stageChanges: [(t: Double, letter: String, stage: String)] = []

    /// A new canvas frame and what it is drawing. Resets the ink readout
    /// and commits the previous frame to the log.
    func beginFrame(letter: String, stage: String, glyph: Bool) {
        guard Self.isArmed else { return }
        lock.withLock {
            commitCurrent()
            layers = 0; box = .null
            current = Frame(t: Self.now(), letter: letter, stage: stage, glyph: glyph, ink: 0)
        }
    }

    private func commitCurrent() {
        guard var f = current else { return }
        f.ink = layers
        if frames.last.map({ !$0.sameContent(f) }) ?? true { frames.append(f) }
        current = nil
    }

    func noteModelStage(letter: String, stage: String) {
        guard Self.isArmed else { return }
        lock.withLock { stageChanges.append((Self.now(), letter, stage)) }
    }

    /// The frame log, the in-progress frame included.
    var frameLog: [Frame] {
        lock.withLock {
            var out = frames
            if var f = current {
                f.ink = layers
                if out.last.map({ !$0.sameContent(f) }) ?? true { out.append(f) }
            }
            return out
        }
    }

    var json: [String: Any] {
        let log = frameLog
        let changes = lock.withLock { stageChanges }
        return [
            "frames": log.map { ["t": $0.t, "letter": $0.letter, "stage": $0.stage,
                                 "glyph": $0.glyph, "ink": $0.ink] as [String: Any] },
            "stageChanges": changes.map { ["t": $0.t, "letter": $0.letter, "stage": $0.stage] as [String: Any] },
        ]
    }

    func record(_ paths: [Path]) {
        guard Self.isArmed else { return }
        lock.withLock {
            for path in paths where !path.isEmpty {
                layers += 1
                box = box.union(path.boundingRect)
            }
        }
    }

    /// Non-empty ink layers stroked in the latest frame, and their bounds
    /// (canvas points; `.null` when none).
    var latest: (layers: Int, box: CGRect) { lock.withLock { (layers, box) } }
}

/// The session as the child met it, sampled every hook tick (0.2 s): what
/// the screen showed (stage, chrome, ink, glyph, pause, end screen, check),
/// the arm audio MEASURED at the main mixer (PopCapture's tap, when the run
/// was launched with `-popCapture`), and every recorded prompt played, ended
/// or cut. Published through the hook so a UI test can assert the WHOLE
/// session after the fact, without racing the transitions it polls.
@MainActor
final class TracingSessionTimeline {
    static let shared = TracingSessionTimeline()

    struct State: Equatable {
        var letter: String
        var phase: String
        var probe: String
        var stage: String
        var chrome: Bool
        var ink: Int
        var glyph: Bool
        var pause: Bool
        var end: Bool
        var check: Bool
    }

    struct Entry { let t: Double; let state: State }

    /// One contiguous stretch of (letter, phase, probe, stage) and the
    /// mixer level measured over it. `settled*` leaves out the first
    /// `settleSeconds` of the stretch, where the previous stretch's fade-out
    /// may still be sounding.
    struct AudioSegment {
        let key: String
        let start: Double
        var end: Double
        var samples = 0
        var loud = 0
        var peak: Float = 0
        var settledLoud = 0
        var settledPeak: Float = 0
    }

    struct PromptEvent { let t: Double; let kind: String; let key: String; let stage: String }

    static let settleSeconds = 0.6
    /// The AudioSignalProbe's silence threshold (-60 dBFS).
    static let loudThreshold: Float = 0.001

    private let t0 = TracingInkDrawProbe.epoch
    private(set) var entries: [Entry] = []
    private(set) var audio: [AudioSegment] = []
    private(set) var prompts: [PromptEvent] = []
    private var keyForText: [String: String] = [:]
    /// The view model last sampled, so a prompt event carries the stage the
    /// model is in AT the call. The timeline samples on render and lags a
    /// stage change by a frame; a prompt played in the same transition
    /// (`endFinalTestPause` sets `.intro`, then plays the intro) would
    /// otherwise read as played in the previous stage.
    private weak var lastVM: TracingViewModel?

    private var now: Double { ((CACurrentMediaTime() - t0) * 100).rounded() / 100 }

    func sample(vm: TracingViewModel) {
        guard TracingGeometryTestLog.isArmedByLaunchArgument else { return }
        lastVM = vm
        let stage = vm.finalTestStage
        let state = State(
            letter: vm.currentLetterName,
            phase: vm.learningPhase.rawName,
            probe: vm.currentProbe?.rawValue ?? "",
            stage: "\(stage)",
            chrome: !FinalTestRules.hidesChrome(stage),
            ink: TracingInkDrawProbe.shared.latest.layers,
            glyph: vm.showsReferenceGlyph,
            pause: FinalTestRules.showsPause(stage),
            end: vm.sessionEndScreenPresented,
            check: vm.showsFinalTestCheck)
        let t = now
        if entries.last?.state != state {
            entries.append(Entry(t: t, state: state))
            #if DEBUG || POPCAP
            PopCapture.armed?.event("hook.state", "letter=\(state.letter) phase=\(state.phase) probe=\(state.probe) "
                + "stage=\(state.stage) chrome=\(state.chrome) ink=\(state.ink) glyph=\(state.glyph) "
                + "pause=\(state.pause) end=\(state.end) check=\(state.check)")
            #endif
        }
        guard let cap = PopCapture.armed, cap.mixerTapInstalled else { return }
        let peak = cap.takeMixerPeak()
        let key = "\(state.letter)|\(state.phase)|\(state.probe)|\(state.stage)"
        if audio.last?.key != key { audio.append(AudioSegment(key: key, start: t, end: t)) }
        var seg = audio.removeLast()
        seg.end = t
        seg.samples += 1
        seg.peak = max(seg.peak, peak)
        if peak > Self.loudThreshold { seg.loud += 1 }
        if t - seg.start >= Self.settleSeconds {
            seg.settledPeak = max(seg.settledPeak, peak)
            if peak > Self.loudThreshold { seg.settledLoud += 1 }
        }
        audio.append(seg)
    }

    /// From `PromptPlayer`: `play` / `missing` carry the key; `end` / `cut`
    /// carry the phrase text, resolved to the key it was played under.
    func notePrompt(_ kind: String, key: String?, text: String) {
        guard TracingGeometryTestLog.isArmedByLaunchArgument else { return }
        if let key { keyForText[text] = key }
        prompts.append(PromptEvent(t: now, kind: kind, key: key ?? keyForText[text] ?? text,
                                   stage: lastVM.map { "\($0.finalTestStage)" } ?? "-"))
    }

    var json: [String: Any] {
        func r2(_ v: Float) -> Double { (Double(v) * 10000).rounded() / 10000 }
        return [
            "timeline": entries.map { e -> [String: Any] in
                let s = e.state
                return ["t": e.t, "letter": s.letter, "phase": s.phase, "probe": s.probe, "stage": s.stage,
                        "chrome": s.chrome, "ink": s.ink, "glyph": s.glyph, "pause": s.pause,
                        "end": s.end, "check": s.check]
            },
            "audioMeasured": PopCapture.armed?.mixerTapInstalled ?? false,
            "audio": audio.map { a -> [String: Any] in
                ["key": a.key, "start": a.start, "end": a.end, "samples": a.samples, "loud": a.loud,
                 "peak": r2(a.peak), "settledLoud": a.settledLoud, "settledPeak": r2(a.settledPeak)]
            },
            "prompts": prompts.map { ["t": $0.t, "kind": $0.kind, "key": $0.key, "stage": $0.stage] },
        ]
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
                let _ = TracingSessionTimeline.shared.sample(vm: vm)
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
            "orientationHold": vm.orientationHold.rawValue,
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
        // The final test's edges (2026-11-23): what the screen shows NOW,
        // and the whole session so far (`TracingSessionTimeline`).
        let stage = vm.finalTestStage
        let ink = TracingInkDrawProbe.shared.latest
        dict["stage"] = "\(stage)"
        dict["chrome"] = !FinalTestRules.hidesChrome(stage)
        dict["inkLayers"] = ink.layers
        dict["glyph"] = vm.showsReferenceGlyph
        dict["pauseView"] = FinalTestRules.showsPause(stage)
        dict["endScreen"] = vm.sessionEndScreenPresented
        dict["check"] = vm.showsFinalTestCheck
        for (k, v) in TracingSessionTimeline.shared.json { dict[k] = v }
        for (k, v) in TracingInkDrawProbe.shared.json { dict[k] = v }
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
}
#endif
