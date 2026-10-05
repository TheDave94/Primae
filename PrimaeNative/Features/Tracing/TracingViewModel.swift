import UIKit
import CoreGraphics
import QuartzCore
import Foundation

@MainActor
@Observable
public final class TracingViewModel {

    // MARK: - Public observable state

    var showGhost           = false
    /// True shows every bundled letter; false limits to the 7 demo
    /// letters (A, F, I, K, L, M, O). Default true; flag remains for a
    /// future "thesis demo" mode.
    var showAllLetters      = true
    var pencilPressure: CGFloat? = nil
    var pencilAzimuth: CGFloat   = 0
    var showDebug           = false
    /// Calibration mode — hides other debug panels so they don't sit
    /// on top of the calibrator controls. Only meaningful with
    /// `showDebug` true.
    var showCalibration     = false
    /// Drops all learning-phase overlays during calibration so the
    /// calibrator's dots aren't buried under phase UI.
    ///
    /// COMPILE-TIME FALSE ON STUDY_BUILD (2026-09-04 — gate the SOURCE,
    /// not each of its ~10 call sites): `StrokeCalibrationOverlay` itself
    /// is already `#if !STUDY_BUILD`-gated out of the study binary
    /// (Q2), but `isCalibrating` is read UNCONDITIONALLY throughout
    /// `TracingCanvasView.swift` to suppress ghost lines, checkpoints,
    /// hit-testing, and the animation guide point — every one of those
    /// reads was reachable on a study build via the completely
    /// unprotected "Striche kalibrieren" Settings toggle
    /// (`SettingsView.swift`, itself since hidden on STUDY_BUILD too).
    /// Flipping it degraded the child-facing tracing canvas — checkpoints
    /// and ghost lines silently vanish — with no way back, since the
    /// overlay that would let anyone exit calibration mode never
    /// renders on that build. Gating the property itself protects every
    /// reader at once, the same "gate the symbol, not the call site"
    /// discipline `StrokeCalibrationOverlay.swift`'s own header states.
    var isCalibrating: Bool {
        #if STUDY_BUILD
        return false
        #else
        return showDebug && showCalibration
        #endif
    }

    /// Bottom-screen band reserved for the calibrator's UI bar.
    /// `TracingCanvasView` shrinks the glyph by this much during
    /// calibration; `StrokeCalibrationOverlay` shrinks its skeleton/
    /// bbox/handle math by the same amount. The two MUST agree or
    /// glyph and skeleton drift apart (see commit 1871466c → revert
    /// 74dcb11b).
    static let calibratorBottomInset: CGFloat = 180
    var letterOrdering: LetterOrderingStrategy = .motorSimilarity {
        didSet {
            // Same pin as `schriftArt` below, same reason: init already
            // pins studyMode to `.motorSimilarity`, but that pin only
            // covers the ONE assignment at init — a live Settings write
            // from `SettingsView`'s "Buchstabenreihenfolge" rows was
            // reaching this property with no further guard. Checked
            // against the pinned value, not `oldValue`, so the
            // corrective re-assignment terminates instead of recursing.
            if studyMode, letterOrdering != .motorSimilarity {
                letterOrdering = .motorSimilarity
            }
        }
    }
    var schriftArt: SchriftArt = .druckschrift {
        didSet {
            // Study pins Druckschrift (see the init-time comment: "a
            // stray device setting must not swap the stimulus geometry
            // or the sequence"), but that pin only covers the ONE
            // assignment at init — a live Settings write from
            // `SettingsView`'s "Schriftart" rows was reaching this
            // property with no further guard. Checked against the
            // pinned value, not `oldValue`, so the corrective
            // re-assignment below terminates (re-triggers this didSet
            // once, lands on `.druckschrift`, and the condition is then
            // false) instead of recursing.
            if studyMode, schriftArt != .druckschrift {
                schriftArt = .druckschrift
                return
            }
            guard oldValue != schriftArt,
                  !letters.isEmpty, letterIndex < letters.count else { return }
            scriptStrokeCache.removeAll(keepingCapacity: true)
            PrimaeLetterRenderer.clearCache()
            // Invariant: variants are druckschrift-only. Clear the
            // variant on every script change so the impossible state
            // never becomes observable.
            if schriftArt != .druckschrift {
                showingVariant = false
                variantStrokeCache = nil
            }
            // Glyph is rendered as a vector path each frame; the next
            // Canvas redraw picks up the new font automatically.
            reloadStrokeCheckpoints(for: letters[letterIndex])
            // Tracker resets to empty checkpoints; zero the bar so the
            // previous font's progress doesn't linger until next touch.
            progress = 0
        }
    }
    /// Forwarded from `TransientMessagePresenter`.
    var toastMessage: String? { messages.toastMessage }
    var currentLetterName   = "A"
    var canvasSize: CGSize  = CGSize(width: 1024, height: 1024) {
        didSet {
            guard oldValue != canvasSize,
                  !letters.isEmpty, letterIndex < letters.count else { return }
            // Re-layout BEFORE checkpoint reload — reload reads each
            // cell's frame to map strokes into cell-local space.
            grid.layout(in: canvasSize, schriftArt: schriftArt)
            reloadStrokeCheckpoints(for: letters[letterIndex])
            // The VM is built before any view exists, so the launch
            // letter's observe animation was armed against the 1024×1024
            // placeholder: `rawGlyphStrokes` bakes the cell's glyph rect
            // into the payload, and the guide dot then ran a horizontally
            // stretched path (W/H of the real canvas, ~1.5×) over the
            // real ghost — the child's FIRST demonstration of the session
            // (audit 2026-09-06). Re-arm with the laid-out geometry; the
            // cycle count and `onCycleComplete` are untouched, so the
            // observe window is not extended.
            if animation.armedStrokes != nil,
               let fresh = rawGlyphStrokes, !fresh.strokes.isEmpty,
               fresh != animation.armedStrokes {
                // OBSERVE ONLY, and the narrowing is deliberate. `.guided`
                // used to re-arm the demonstration here, which is exactly
                // the supervisor's "beim nachfahren selbst kein Punkt": in
                // guided the CHILD traces, and a guide dot running over
                // their own attempt is a second, competing cue on the one
                // phase that produces the scored trace.
                //
                // It was DEAD, not correct — and it is worth being precise
                // about why, because the distinction decides whether this
                // is testable. Guided entry calls `stop()`, and `stop()`
                // nils `armedStrokes` (`AnimationGuideController.swift:149`)
                // while the guard above requires it non-nil. So the branch
                // could not fire, and NO TEST THROUGH THIS PATH CAN FAIL:
                // the guard rejects the state before the phase is ever
                // consulted. It is removed as a trap a later refactor
                // could arm — not as a fix for a live defect, and
                // deliberately without a test that would only look like
                // evidence (audit 2026-09-17).
                if phaseController.currentPhase == .observe {
                    animation.startAfterDelay(0.3 + presentationSpacing,
                                              strokes: fresh)
                }
            }
        }
    }

    /// Read-only view of the grid's cells for the canvas renderer.
    var gridCells: [LetterCell] { grid.cells }

    /// Current grid preset — exposed so the canvas can compute cell
    /// frames from the live Canvas `size`, sidestepping the
    /// first-render window where `vm.canvasSize` hasn't caught up.
    var gridPreset: InputPreset { grid.preset }

    /// Active cell index. Canvas scopes active-only scaffolding to it.
    var gridActiveCellIndex: Int { grid.activeCellIndex }

    /// Active-cell frame in canvas pixels for multi-cell layouts;
    /// `nil` for single-cell. Overlays that map glyph coordinates
    /// (DirectPhaseDotsOverlay) need this for word mode.
    var multiCellActiveFrame: CGRect? {
        grid.cells.count > 1 ? grid.activeCell.frame : nil
    }

    /// Rendered word layout — non-nil for `.word` sequences after a
    /// successful CoreText layout; canvas blits this so Schreibschrift
    /// ligatures aren't cropped per glyph.
    var gridWordRendering: PrimaeLetterRenderer.WordRendering? { grid.wordRendering }

    /// Cell-fraction strokes (0..1 of the cell's own frame) for the cell
    /// at `index`. JSON strokes are bbox-relative; this remaps them
    /// through the cell's glyph rect so the renderer and tracker share
    /// one coordinate system regardless of cell aspect ratio.
    func gridCellStrokes(at index: Int) -> LetterStrokes? {
        guard index < grid.cells.count else { return nil }
        let cellLetter = grid.cells[index].item.letter
        let raw: LetterStrokes?
        if cellLetter == currentLetterName {
            raw = glyphRelativeStrokes
        } else {
            raw = letters.first(where: { $0.name == cellLetter })?.strokes
        }
        guard let raw else { return nil }
        let cellSize = grid.cells[index].frame.size
        // Word mode: `cellSize` is a per-character frame from
        // CTLineGetGlyphRuns, which is already snug around the ink.
        // Skip the 10 % padding `normalizedGlyphRect` applies for
        // single-letter cells so checkpoints align with the rendered
        // word image instead of sitting ~5 % inside it.
        let cellPad: CGFloat = grid.wordRendering == nil ? 0.10 : 0.0
        guard cellSize.width > 0, cellSize.height > 0,
              let gr = PrimaeLetterRenderer.normalizedGlyphRect(
                for: cellLetter, canvasSize: cellSize,
                schriftArt: schriftArt,
                openTypeFeatures: PrimaeLetterRenderer.openTypeFeatures(
                    for: cellLetter, schriftArt: schriftArt, variant: showingVariant),
                pad: cellPad) else {
            return raw
        }
        let mapped = raw.strokes.map { def in
            StrokeDefinition(
                id: def.id,
                checkpoints: def.checkpoints.map { cp in
                    Checkpoint(
                        x: gr.minX + cp.x * gr.width,
                        y: gr.minY + cp.y * gr.height
                    )
                }
            )
        }
        return LetterStrokes(letter: raw.letter,
                             checkpointRadius: raw.checkpointRadius
                                 * sqrt(gr.width * gr.height),
                             strokes: mapped)
    }

    /// Letter at cell `index`. Canvas uses this for per-cell glyph
    /// rendering in word mode.
    func gridCellLetter(at index: Int) -> String? {
        guard index < grid.cells.count else { return nil }
        return grid.cells[index].item.letter
    }

    /// Exposed for debug UI and tests.
    var inputModeDetector: InputModeDetector { detector }

    /// Pencil touchesBegan forwarder. Feeds the detector and re-applies
    /// the grid preset so the layout splits before the stroke
    /// completes; tracking is cell-aware so touches still feed the
    /// active cell correctly.
    /// Device of the most recent touch-down, set by the two overlays
    /// before `beginTouch`; the dispatcher pins the session to it so a
    /// resting hand and a Pencil cannot feed one stroke (review 2026-09-05).
    private(set) var lastTouchDownWasPencil = false

    func pencilDidTouchDown() {
        lastTouchDownWasPencil = true
        let priorKind = detector.effectiveKind
        detector.observeTouchBegan(isPencil: true)
        // The detector still records the device (it stamps
        // `inputDevice` on every row), but under studyMode the grid
        // preset is pinned to a single cell (see `reapplyGridPreset`),
        // so a promotion must not rebuild the grid — that would drop
        // the in-flight tracker mid-session for no layout change.
        if !studyMode, priorKind != detector.effectiveKind,
           letters.indices.contains(letterIndex) {
            reapplyGridPreset()
            reloadStrokeCheckpoints(for: letters[letterIndex])
        }
    }

    /// Finger touchesBegan forwarder; feeds the detector hysteresis
    /// counter for pencil-session demotion.
    func fingerDidTouchDown() {
        lastTouchDownWasPencil = false
        detector.observeTouchBegan(isPencil: false)
    }

    /// Rebuild the grid's sequence + preset for the detector's mode.
    ///   - `.finger`: length-1 singleLetter sequence.
    ///   - `.pencil`: repetition sequence broadcasting the current
    ///     letter across the preset's default cell count.
    func reapplyGridPreset() {
        guard letters.indices.contains(letterIndex) else { return }
        let letter = letters[letterIndex]
        // Study pin (2026-09-04): ONE cell, always. The `.pencil` preset
        // is a 4-cell repetition layout with four-line Lineatur — a
        // different stimulus (letter rendered at a quarter of the size,
        // proportionally tighter checkpoint radius) — and, worse, its
        // multi-cell freeWrite scoring path (`assess(cellReferences:)`)
        // never sets `lastStrokeProcess`, so `spatialDeviation`,
        // `strokeCount`, `strokeOrder` and `reversedStrokeCount` are all
        // nil on the freeWrite row, and `formAccuracy` is computed with
        // the whole cell's ink as ONE stroke. A single Apple Pencil touch
        // promoted the detector and switched every later trial of the
        // session onto that path, silently. The pilot's task is one
        // letter, one trace (thesis Ch.3/Ch.6); pencil input stays
        // allowed and is still recorded as `inputDevice`.
        let usePencil = !studyMode && detector.effectiveKind == .pencil
        let preset: InputPreset = usePencil ? .pencil : .finger
        let sequence: TracingSequence = usePencil
            ? .repetition(letter.name, count: preset.cellCount)
            : .singleLetter(letter.name)
        grid.load(sequence: sequence, preset: preset)
        grid.layout(in: canvasSize, schriftArt: schriftArt)
        // Preset changes alter cell frames; the idempotency cache
        // doesn't include preset state, so force a rebuild.
        lastCheckpointKey = nil
    }
    var progress: CGFloat   = 0
    var isPlaying           = false
    var activePath: [CGPoint] = []
    /// Snapshot of the just-completed activePath so the child can still
    /// see what they wrote for ~5 s after the phase transition clears
    /// `activePath`. Cleared by a delayed task scheduled in
    /// `resetForPhaseTransition`, or immediately on the next touch.
    var lingeringInk: [CGPoint] = []
    private var lingeringInkClearTask: Task<Void, Never>? = nil
    /// Updated by `PhaseTransitionCoordinator.commitCompletion`.
    var currentDifficultyTier: DifficultyTier = .standard

    // MARK: - Learning phase state

    var learningPhase: LearningPhase { phaseController.currentPhase }
    var phaseScores: [LearningPhase: CGFloat] { phaseController.phaseScores }
    var isPhaseSessionComplete: Bool { phaseController.isLetterSessionComplete }

    /// Whether stroke-start dots render in the current phase
    /// (Pearson & Gallagher 1983 GRRM).
    ///
    /// Suppressed entirely when `StudyComparisonSettings.guidedDotsVisible`
    /// is off — the supervisor's "Punkte rausschmeißen" against "Punkte
    /// nur sehen?". Applied HERE rather than in `LearningPhaseController`
    /// so the phase model stays a model: this is a device setting, not a
    /// property of a phase. The Direct phase is unaffected by construction
    /// — `phaseController.showCheckpoints` is already false there, because
    /// that phase renders its own numbered overlay and would have nothing
    /// left to tap if the dots went away.
    var showCheckpoints: Bool {
        guard phaseController.showCheckpoints else { return false }
        return dotsVisible
    }

    /// Whether the endpoint ring renders — where the letter finishes.
    ///
    /// Deliberately NOT a member of `showCheckpoints` (2026-09-17). The
    /// ring was first drawn inside that guard, which made the "Punkte
    /// rausschmeißen" switch silently delete it — and that ring is the
    /// SILENT ARM's only end-of-letter acknowledgement, because study mode
    /// removes the celebration overlay, the chime and the completion HUD
    /// for every arm. A researcher switching the dots off to compare would
    /// have removed the very cue the silent condition depends on, with
    /// nothing on screen to say so. The two are separate questions: one is
    /// about showing start dots, the other about marking where the letter
    /// ends, and the switch answers only the first.
    ///
    /// Phase-driven on its own terms: present in Observe and Guided, absent
    /// in Direct (which draws its own numbered overlay) and in FreeWrite,
    /// where the thesis withdraws all scaffolding so no signal contingent
    /// on the hidden reference reaches the child while the outcome is being
    /// produced.
    var showEndpointRing: Bool { phaseController.showCheckpoints }

    /// Which turn cue the child sees, if any — the supervisor's "Auge und
    /// Finger", disambiguated by David 2026-09-17: the eye belongs to the
    /// phase where the letter is SHOWN, the finger to the phases where the
    /// CHILD acts.
    ///
    /// Extracted here rather than left as a condition inside
    /// `SchuleWorldView`, which had ZERO test coverage (audit 2026-09-17) —
    /// a `some View`'s structure cannot be asserted, but a value can. This
    /// is the same move `CanvasDrawPlan` makes for the canvas: the decision
    /// becomes an ordinary comparison, so the rule cannot be broken by a
    /// brace or a condition in the wrong place without a test noticing.
    enum PhaseCue: Equatable {
        /// 👁️ — the letter is being demonstrated; watch.
        case watch
        /// 👆 — it is the child's turn to act on the letter.
        case act
    }

    /// David's rule applied literally: the eye where the letter is SHOWN,
    /// the finger in every phase where the CHILD acts. That is `direct`
    /// ("Richtung lernen"), `guided` ("Nachspuren") and — deliberately
    /// included — `freeWrite` ("Selbst schreiben").
    ///
    /// `freeWrite` was first left out on scaffolding grounds and that was
    /// wrong: the no-scaffolding rule bars signals CONTINGENT ON THE HIDDEN
    /// REFERENCE, and a turn cue carries no information about the letter at
    /// all. "Selbst schreiben" is the most literal instance of "the child is
    /// supposed to write itself", so excluding it contradicted the rule it
    /// was meant to serve.
    ///
    /// `nil` means no cue, and after this the only case is calibration —
    /// suppressed for the same reason the canvas suppresses the guide dot,
    /// since it would scan over the researcher's own edits.
    var phaseCue: PhaseCue? {
        guard !isCalibrating else { return nil }
        switch learningPhase {
        case .observe:              return .watch
        case .direct, .guided, .freeWrite: return .act
        }
    }

    /// What the tracing canvas should DRAW, decided in plain Swift.
    ///
    /// Extracted 2026-09-17 so the decisions are assertable without a
    /// `GraphicsContext` — which cannot be constructed at all
    /// (`GraphicsContext` is a `@frozen struct` with NO public initialiser;
    /// SwiftUI vends instances into the draw closure), so nothing can
    /// invoke or spy on that closure. Asserting the DECISION here, and
    /// letting the closure only replay it, turns "is this draw inside the
    /// right guard?" from an untestable structural question into a plain
    /// `#expect`.
    ///
    /// The endpoint ring's own history is the argument for this shape. It
    /// was drawn inside the start-dots guard; the fix for that was itself
    /// inert because a closing brace was not moved; and every property
    /// assertion read the same in both states. Only a rendered pixel — or
    /// this, a value the closure is HANDED rather than a condition it
    /// evaluates — can tell the two apart. The render test in
    /// `StudyComparisonSwitchesTests` remains the end-to-end check; this
    /// makes the same contract assertable in ordinary Swift.
    struct CanvasDrawPlan: Equatable {
        var showsGhost: Bool
        var showsStartDots: Bool
        var showsEndpointRing: Bool
    }

    var canvasDrawPlan: CanvasDrawPlan {
        CanvasDrawPlan(
            // The parent-facing display toggle AND the phase. freeWrite
            // withdraws all scaffolding (Schmidt & Lee's guidance
            // hypothesis); direct draws its own numbered overlay.
            showsGhost: showGhost && showGhostForPhase,
            showsStartDots: showCheckpoints && !isCalibrating,
            showsEndpointRing: showEndpointRing && !isCalibrating
        )
    }

    /// Phase-driven ghost-line visibility, composed with user toggle.
    /// observe + guided ON; direct + freeWrite OFF (direct uses the
    /// numbered dots + arrow; freeWrite withdraws all scaffolding per
    /// Schmidt & Lee's Guidance Hypothesis).
    var showGhostForPhase: Bool {
        switch phaseController.currentPhase {
        case .observe, .guided:    return true
        case .direct, .freeWrite:  return false
        }
    }

    /// Guidance-fading intensity (Schmidt & Lee 2005). Gates haptics +
    /// checkpoint ticks; letter-sound audio is NOT gated since the
    /// phoneme is the glyph's auditory anchor, not guidance feedback.
    /// observe/direct=1.0, guided=0.6, freeWrite=0.0.
    var feedbackIntensity: CGFloat {
        switch phaseController.currentPhase {
        case .observe:   return 1.0
        case .direct:    return 1.0
        case .guided:    return 0.6
        case .freeWrite: return 0.0
        }
    }

    /// Stroke data for the calibration overlay (canvas-mapped).
    var strokeDefinition: LetterStrokes? { strokeTracker.definition }

    /// The single resolution chokepoint for a letter's scored,
    /// bbox-relative strokes. In study mode the on-device
    /// `CalibrationStore` override is bypassed so the scored path returns
    /// the identical frozen *bundle* stimulus — the thesis-truth-condition
    /// behind Ch.5's "every child traces the identical frozen stimulus"
    /// claim (`StrokeGeometryGoldenTests` pins this `letter.strokes`
    /// target). Otherwise the saved user calibration wins, unchanged.
    /// Used by the three scored-geometry sites only — deliberately NOT by
    /// `loadAllEffectiveStrokes` (the calibrator export must still see
    /// overrides).
    func resolvedStrokes(for letter: LetterAsset) -> LetterStrokes {
        if studyMode { return letter.strokes }
        return calibrationStore.strokes(for: letter.name, schriftArt: schriftArt)
            ?? letter.strokes
    }

    /// Raw glyph-relative strokes (0-1 within bbox). Non-Druckschrift
    /// always uses bundle JSON (committed calibrations in
    /// `strokes_schulschrift.json` are authoritative). Druckschrift
    /// prefers the user-calibrated Application Support file (unless
    /// `studyMode` bypasses it — see `resolvedStrokes(for:)`).
    var glyphRelativeStrokes: LetterStrokes? {
        guard !letters.isEmpty, letterIndex < letters.count else { return nil }
        if showingVariant, let vs = variantStrokeCache { return vs }
        if let ss = activeScriptStrokes { return ss }
        let letter = letters[letterIndex]
        return resolvedStrokes(for: letter)
    }

    /// Active-letter strokes mapped from bbox-relative to cell-fraction
    /// (via the active cell's glyph rect). Canvas dots, guide animation,
    /// and observe-phase playback all consume these so screen positions
    /// match the rendered ghost regardless of cell aspect ratio. Falls
    /// through to bbox-relative when the cell hasn't laid out yet.
    var rawGlyphStrokes: LetterStrokes? {
        guard !letters.isEmpty, letterIndex < letters.count else { return nil }
        let letter = letters[letterIndex]
        let bbox: LetterStrokes
        if showingVariant, let vs = variantStrokeCache {
            bbox = vs
        } else if let ss = activeScriptStrokes {
            bbox = ss
        } else {
            bbox = resolvedStrokes(for: letter)
        }
        let cellSize = grid.activeCell.frame.size
        guard cellSize.width > 0, cellSize.height > 0,
              let gr = PrimaeLetterRenderer.normalizedGlyphRect(
                for: currentLetterName, canvasSize: cellSize,
                schriftArt: schriftArt,
                openTypeFeatures: currentGlyphFeatures) else {
            return bbox
        }
        let mapped = bbox.strokes.map { def in
            StrokeDefinition(
                id: def.id,
                checkpoints: def.checkpoints.map { cp in
                    Checkpoint(
                        x: gr.minX + cp.x * gr.width,
                        y: gr.minY + cp.y * gr.height
                    )
                }
            )
        }
        return LetterStrokes(letter: bbox.letter,
                             checkpointRadius: bbox.checkpointRadius
                                 * sqrt(gr.width * gr.height),
                             strokes: mapped)
    }

    /// True when the current letter has a variant in the active
    /// script. Variant files are Druckschrift-only for now, so the
    /// button stays hidden in Schreibschrift to avoid rendering a
    /// print path over a cursive glyph.
    var currentLetterHasVariants: Bool {
        // Study sessions pin the standard stroke form: a child-reachable
        // variant toggle would swap F's scorer reference geometry
        // mid-study (different checkpoint count + radius).
        guard !studyMode, !letters.isEmpty, letterIndex < letters.count,
              schriftArt == .druckschrift else { return false }
        return !(letters[letterIndex].variants?.isEmpty ?? true)
    }

    /// OpenType feature tags to apply when rendering the current
    /// letter — pulls the alternate glyph (e.g. curled-k via `ss02`)
    /// when `showingVariant` is on. Empty otherwise.
    var currentGlyphFeatures: [String] {
        guard !letters.isEmpty, letterIndex < letters.count else { return [] }
        let name = letters[letterIndex].name
        return PrimaeLetterRenderer.openTypeFeatures(for: name,
                                                    schriftArt: schriftArt,
                                                    variant: showingVariant)
    }
    /// Stars earned in the current session (0-3).
    var starsEarned: Int { phaseController.starsEarned }
    /// Maximum achievable stars; guidedOnly/control = 1, threePhase = 4
    /// — showing 4 placeholders for a single-phase condition would be
    /// a between-arms confound.
    var maxStars: Int { phaseController.maxStars }
    /// Phases active in the current condition (drives the dot HUD so
    /// single-phase conditions don't render empty placeholders).
    var activePhases: [LearningPhase] { phaseController.activePhases }

    // MARK: - FreeWrite phase data (forwarded from FreeWritePhaseRecorder)

    /// Accumulated canvas-space touch points for free-write scoring.
    var freeWritePoints: [CGPoint] { freeWriteRecorder.points }
    /// CACurrentMediaTime timestamps for each accumulated free-write point.
    var freeWriteTimestamps: [CFTimeInterval] { freeWriteRecorder.timestamps }
    /// Digitiser force at each accumulated free-write point (0 = finger / no data).
    var freeWriteForces: [CGFloat] { freeWriteRecorder.forces }
    /// Checkpoints completed per second in guided / freeWrite. Note
    /// the unit: checkpoints, not strokes — the name matters for
    /// motor-rhythm correlations.
    var checkpointsPerSecond: CGFloat { freeWriteRecorder.checkpointsPerSecond }
    /// Raw, order-invariant spatial deviation of the measured freeWrite
    /// trace via stroke correspondence, or nil if none was measured. The
    /// study's PRIMARY accuracy outcome — see
    /// `PhaseSessionRecord.spatialDeviation` and `StrokeProcessMeasures`.
    var lastFreeWriteSpatialDeviation: CGFloat? { freeWriteRecorder.lastSpatialDeviation }
    /// The unnormalised secondary (protocol r6) — `PhaseSessionRecord.spatialDeviationRaw`.
    var lastFreeWriteSpatialDeviationRaw: CGFloat? { freeWriteRecorder.lastSpatialDeviationRaw }
    /// Stroke count/order/direction of the measured freeWrite trace, or
    /// nil if none was measured. The study's SECONDARY process outcomes
    /// (2026-09-03) — see `PhaseSessionRecord.strokeCount` and siblings.
    var lastFreeWriteStrokeProcess: StrokeProcessMeasures? { freeWriteRecorder.lastStrokeProcess }
    /// Most recent four-dimension Schreibmotorik assessment.
    var lastWritingAssessment: WritingAssessment? { freeWriteRecorder.lastAssessment }
    /// Last guided-phase score, captured for the "Nachspuren fertig"
    /// feedback band.
    var lastGuidedScore: CGFloat? { freeWriteRecorder.lastGuidedScore }
    /// Normalised freeWrite touch path for the KP overlay.
    var freeWritePath: [CGPoint] { freeWriteRecorder.path }
    /// Stroke-start indices so the KP overlay can break the polyline
    /// at lifts instead of bridging gaps with phantom diagonals.
    var freeWriteStrokeStartIndices: [Int] { freeWriteRecorder.strokeStartIndices }

    /// All captured raw freeWrite traces — read by the exporter so the
    /// JSON archive carries the lossless traces alongside the records.
    var rawTraces: [RawTrace] { rawTraceStore.traces }

    /// Snapshot the current freeWrite buffer as a raw trace and persist
    /// it (re-analysis insurance), returning its id — or nil if there's
    /// nothing to capture. Called at phase exit BEFORE the buffer clears
    /// on the next letter load. Writing the trace FIRST (then the linking
    /// record) means a crash leaves at most an orphan trace, never a
    /// record pointing at a missing trace.
    func captureFreeWriteTrace() -> UUID? {
        guard !freeWritePoints.isEmpty else { return nil }
        let trace = RawTrace(
            id: UUID(),
            letter: currentLetterName,
            recordedAt: Date(),
            points: freeWritePoints,
            timestamps: freeWriteTimestamps,
            forces: freeWriteForces,
            strokeStartIndices: freeWriteStrokeStartIndices,
            canvasSize: canvasSize,
            // The reference the trial was scored against, in the same
            // canvas-normalised space the scorer used — see RawTrace.
            referenceStrokes: strokeTracker.definition
        )
        rawTraceStore.append(trace)
        return trace.id
    }

    /// Whether the user is tracing the variant stroke form.
    var showingVariant: Bool = false
    /// Paper-transfer phase enabled (thesis setting).
    var enablePaperTransfer: Bool = false {
        didSet {
            UserDefaults.standard.set(enablePaperTransfer,
                forKey: "de.flamingistan.primae.enablePaperTransfer")
        }
    }
    /// Freeform-mode picker entry exposed; default on.
    var enableFreeformMode: Bool = true {
        didSet {
            UserDefaults.standard.set(enableFreeformMode,
                forKey: "de.flamingistan.primae.enableFreeformMode")
        }
    }
    /// Play the phoneme (/a/) instead of the letter name (/aː/);
    /// falls back to name audio when a letter ships no phoneme set so
    /// the toggle never produces silence.
    var enablePhonemeMode: Bool = false {
        didSet {
            UserDefaults.standard.set(enablePhonemeMode,
                forKey: "de.flamingistan.primae.enablePhonemeMode")
            // Reset the variant cursor so a swipe doesn't index out
            // of the new population.
            audioIndex = 0
        }
    }
    /// Study mode for pilot devices: bypass the on-device
    /// `CalibrationStore` override so the scored path returns the frozen
    /// *bundle* stimulus (the thesis-truth-condition behind Ch.5's
    /// identical-across-arms claim). Off by default, so default behavior
    /// is unchanged. Geometry-only — affects nothing but
    /// `resolvedStrokes(for:)`. Persisted like the other research flags
    /// so a configured study device stays in study mode across relaunches.
    /// Readable from the app target (PrimaeApp pins the light appearance
    /// on it); settable only inside the package.
    /// See `TracingDependencies.participantEnrolled`.
    ///
    /// NOT a `let`, and that is load-bearing — MEASURED 2026-10-02 on the
    /// physical iPad, after a cold-start enrolment left the proctor stuck
    /// on "Studie kann nicht starten" having done exactly what the screen
    /// said. This was frozen at init while the arms beside it were made
    /// re-derivable in place (2026-09-14), so enrolling a participant at
    /// RUNTIME updated `ParticipantStore` — the UUID and `thesisEnrolled`
    /// really were written — but not this copy. `studyPreconditionFailure`
    /// kept reading the launch-time value, `sessionBlockReason` stayed
    /// non-nil, and `SchuleWorldView` kept rendering the gate.
    ///
    /// The VALUE was always right and the DATA always persisted; only the
    /// observation was missing, which is why no unit test caught it: every
    /// VM-building fixture starts enrolled (`.stub` pins it true), so the
    /// cold-start transition had no coverage. Pinned now by
    /// `NewParticipantResetTests.enrollingFromColdDeviceClearsTheStartGate`.
    public private(set) var participantEnrolled: Bool

    public internal(set) var studyMode: Bool = false {
        didSet {
            UserDefaults.standard.set(studyMode,
                forKey: StudyBuild.studyModeDefaultsKey)
        }
    }
    /// Opt-in spaced-retrieval prompts before every Nth letter; off
    /// by default (research feature, parents enable).
    var enableRetrievalPrompts: Bool = false {
        didSet {
            UserDefaults.standard.set(enableRetrievalPrompts,
                forKey: "de.flamingistan.primae.enableRetrievalPrompts")
        }
    }
    /// Built once in init; counter persists across runs via UserDefaults.
    let retrievalScheduler: RetrievalScheduler = RetrievalScheduler()
    /// Reverse direct-phase tap order — last stroke first
    /// (Spooner et al. 2014). Off by default; affects direct phase
    /// only, guided + freeWrite always run canonical order.
    var enableBackwardChaining: Bool = false {
        didSet {
            UserDefaults.standard.set(enableBackwardChaining,
                forKey: "de.flamingistan.primae.enableBackwardChaining")
        }
    }

    // MARK: - Recognition + freeform state (forwarded from FreeformController)

    /// Owns the freeform fields. VM owns the methods (they touch
    /// audio / recognizer / speech / stores). Views observe via
    /// forwarders.
    private let freeform = FreeformController()

    /// Most recent CoreML recognition result. Cleared on letter load
    /// and phase reset.
    private(set) var lastRecognitionResult: RecognitionResult?

    /// Idempotency gate for in-flight recognition Tasks; state-clearing
    /// transitions cancel so late completions are dropped.
    private let recognitionTokens = RecognitionTokenTracker()

    var writingMode: WritingMode {
        get { freeform.writingMode }
        set { freeform.writingMode = newValue }
    }
    var freeformSubMode: FreeformSubMode {
        get { freeform.freeformSubMode }
        set { freeform.freeformSubMode = newValue }
    }
    var freeformTargetWord: FreeformWord? { freeform.freeformTargetWord }
    var freeformPoints: [CGPoint] { freeform.freeformPoints }
    var freeformStrokeSizes: [Int] { freeform.freeformStrokeSizes }
    var freeformActivePath: [CGPoint] { freeform.freeformActivePath }
    var freeformWordResults: [RecognitionResult] { freeform.freeformWordResults }
    var freeformWordResultSlots: [RecognitionResult?] { freeform.freeformWordResultSlots }
    var freeformRecognitionDelay: TimeInterval {
        get { freeform.freeformRecognitionDelay }
        set { freeform.freeformRecognitionDelay = newValue }
    }
    var isWaitingForRecognition: Bool { freeform.isWaitingForRecognition }
    var isRecognizing: Bool { freeform.isRecognizing }
    var freeformCanvasSize: CGSize { freeform.freeformCanvasSize }
    var hasRecognitionCompleted: Bool { freeform.hasRecognitionCompleted }
    var isRecognitionModelAvailable: Bool? { freeform.isRecognitionModelAvailable }
    /// Form-accuracy from the last freeform recognition (0–1).
    var lastFreeformFormScore: CGFloat? { freeform.lastFreeformFormScore }

    /// Serialised canvas overlay scheduler. Canonical post-freeWrite
    /// order: kpOverlay → recognitionBadge → paperTransfer →
    /// celebration.
    let overlayQueue = OverlayQueueManager()

    // MARK: - Direct phase state

    /// Stroke indices whose start dot has been tapped in direct phase.
    private(set) var directTappedDots: Set<Int> = []
    /// True while the correct (next-expected) dot should pulse harder.
    var directPulsingDot: Bool = false
    /// 700 ms timer for clearing `directPulsingDot`; stored so rapid
    /// wrong taps don't accumulate orphaned Tasks.
    private var directPulsingTask: Task<Void, Never>? = nil
    /// Stroke whose direction arrow is briefly shown after a tap.
    var directArrowStrokeIndex: Int? = nil

    /// Next-expected dot index. With `enableBackwardChaining` the list
    /// iterates in reverse (Spooner et al. 2014); default off. Forced
    /// canonical (forward) under studyMode — same family as P1/P6
    /// (`enableRetrievalPrompts`/`enablePhonemeMode`), a parent-facing
    /// research toggle that must not vary the scored direct-phase task
    /// between study children.
    var directNextExpectedDotIndex: Int {
        guard let rawStrokes = rawGlyphStrokes else { return 0 }
        let indices: [Int] = (enableBackwardChaining && !studyMode)
            ? Array(rawStrokes.strokes.indices).reversed()
            : Array(rawStrokes.strokes.indices)
        for i in indices where !directTappedDots.contains(i) { return i }
        return rawStrokes.strokes.count
    }

    // MARK: - Animation guide state

    /// Normalized 0–1 point for the animated guide dot; canvas scales
    /// to screen coords. Forwarded from AnimationGuideController.
    var animationGuidePoint: CGPoint? { animation.guidePoint }

    // MARK: - Onboarding state

    var isOnboardingComplete: Bool = false
    private(set) var onboardingStep: OnboardingStep = .welcome
    /// Onboarding variant locked at first `markComplete` so a later
    /// Settings toggle can't change the historical record.
    var onboardingVariant: OnboardingVariant = .full
    var onboardingProgress: Double { onboardingCoordinator.progress }

    // MARK: - Private dependencies

    private let repo: LetterRepository
    /// Active cell's stroke tracker. The reference is stable for a
    /// single-letter session; it shifts to the next cell on advance
    /// in multi-cell sequences.
    var strokeTracker: StrokeTracker { grid.activeCell.tracker }
    /// Schreibheft grid representation of the current sequence. Drives
    /// the canvas renderer via `gridCells` / `gridPreset`.
    let grid = SequenceGridController(
        sequence: .singleLetter(""),
        preset: .finger
    )

    /// Finger / pencil detector with hysteresis. Receives every
    /// touch-began event from the overlays; `effectiveKind` drives
    /// grid preset promotion.
    let detector = InputModeDetector()
    let audio: AudioControlling
    /// Test-only probe sink; see `init`. Never used for playback.
    private let audioSignalProbeSink: AudioControlling
    let haptics: HapticEngineProviding
    /// Persistent letter-progress store. External readers consume the
    /// read-only `allProgress` / `progress(for:)` forwarders below.
    /// `internal` so `PhaseTransitionCoordinator` can mutate it.
    let progressStore: ProgressStoring

    /// Read-only @Observable mirror of `progressStore.allProgress`.
    /// Stored, not computed: the underlying store isn't @Observable,
    /// so mutations there don't fire SwiftUI updates. Call
    /// `refreshProgressMirror()` after every store write.
    private(set) var allProgress: [String: LetterProgress] = [:]

    /// Resync the @Observable mirror from `progressStore`. Call after
    /// any store mutation.
    func refreshProgressMirror() {
        allProgress = progressStore.allProgress
    }

    /// Per-letter progress lookup.
    func progress(for letter: String) -> LetterProgress {
        progressStore.progress(for: letter)
    }

    /// Completions today (drives the daily-goal pill).
    var completionsToday: Int { progressStore.completionsToday }
    /// Parent-configurable daily goal; default 3.
    var dailyGoal: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: "de.flamingistan.primae.dailyGoal")
            return v > 0 ? v : 3
        }
        set {
            UserDefaults.standard.set(max(1, newValue), forKey: "de.flamingistan.primae.dailyGoal")
        }
    }
    let streakStore: StreakStoring
    let dashboardStore: ParentDashboardStoring
    /// Cold per-trial raw freeWrite traces (re-analysis insurance).
    private let rawTraceStore: RawTraceStoring
    /// Durable per-participant seal, written before `resetForNewParticipant`
    /// wipes the stores above for the next child. See
    /// `ParticipantArchiveStore.swift`.
    let participantArchive: ParticipantArchiving
    /// Every enrolment on this device, written AT enrolment and never as a
    /// participant (2026-10-04) — see `EnrolmentLog.swift`.
    let enrolmentLog: EnrolmentLogging
    /// Was `let` until 2026-09-14: a researcher override (pedagogical arm,
    /// audio arm, trained subset) is read ONCE at init in a non-study
    /// build, so a non-study session still needs the relaunch
    /// `sessionBlockReason` enforces (`assignmentOverrideChanged`) — see
    /// `reapplyParticipantIdentity` for why a STUDY build no longer does.
    private(set) var thesisCondition: ThesisCondition
    /// Pilot audio arm for this participant. Stamped onto every recorded
    /// session (H1); per-arm audio playback routing is H2. Was `let`
    /// until 2026-09-14 — see `reapplyParticipantIdentity`.
    private(set) var audioCondition: PilotAudioCondition
    /// Trained 3-of-5 study-letter subset for this participant (third
    /// assignment axis). Filters the practice pool under `studyMode`;
    /// stamped onto every recorded session for trained/untrained
    /// partitioning in analysis. Was `let` until 2026-09-14 — see
    /// `reapplyParticipantIdentity`.
    private(set) var trainedSubset: TrainedLetterSubset
    private let onboardingStore: OnboardingStoring
    private let notificationScheduler: LocalNotificationScheduler
    var adaptationPolicy: any AdaptationPolicy
    private var onboardingCoordinator: OnboardingCoordinator
    var phaseController: LearningPhaseController
    /// Set immediately before a `startColdProbe(letter:kind:)` load and
    /// consumed at the top of `load(letter:)` — see there. Kept as a
    /// one-shot rather than a parameter threaded through every `load`
    /// call site, since only one caller ever needs it.
    private var pendingProbeOverride: StudyProbe?
    /// The cold probe the CURRENT letter was opened as, or nil for a
    /// training pass. Stamped on every phase row the letter writes
    /// (`PhaseSessionRecord.probe`), so pretest, post-test and delayed
    /// rows on the same letter are distinguishable in the export.
    private(set) var currentProbe: StudyProbe?
    /// In-flight pre-task sound-arm demonstration (see
    /// `PreTaskDemonstration` and `armPreTaskDemonstration`). Cancelled
    /// on every fresh letter load and the moment a real touch begins
    /// (`TouchDispatcher.beginTouch`), so a scripted demo point is never
    /// still writing to `setAdaptivePlayback`/`setSpatialPitch` once the
    /// child's own trace starts driving them.
    private var preTaskDemoTask: Task<Void, Never>?
    /// In-flight delayed start of a study observe PRESENTATION — the guide
    /// animation and, in a sound arm, the whole-observe sound (P4), which
    /// start together once the observe instruction has been spoken
    /// (`armObservePresentationAfterCue`, Option B 2026-10-05). Cancelled
    /// on every fresh letter load, and self-guarding on the phase, so a
    /// start that outlives its observe phase never fires into the next one.
    private var observePresentationTask: Task<Void, Never>?
    /// The arm that claimed the pending presentation's sound, or nil when
    /// it carries none (the silent arm, a once-per-condition repeat, the
    /// axis-sweep switch). An arm change clears it (`applyArm`): the
    /// presentation still starts — observe must still end — but without
    /// a sound claimed under the outgoing arm.
    private var pendingObserveSoundArm: PilotAudioCondition?
    private let letterScheduler: LetterScheduler
    private let calibrationStore: CalibrationStore
    private let letterRecognizer: LetterRecognizerProtocol
    /// German speech synthesiser; non-readers hear scores as speech
    /// rather than seeing numeric dashboards.
    ///
    /// `var` since 2026-09-17, not `let`. The silent arm's authority
    /// (C3-2) has to hold for an arm that is REACHED mid-session, not
    /// only for one assigned at launch — see `applyArmAuthority`. Read
    /// sites are unchanged: every consumer reads the property, so a swap
    /// is visible to all of them at once.
    private(set) var speech: SpeechSynthesizing
    /// Bundled MP3 prompts (phase entries, praise tiers, paper cues,
    /// retrieval). Falls back to `speech` when missing; dynamic
    /// per-letter content goes through `speech` directly. `var` for the
    /// same reason as `speech` above.
    private(set) var prompts: any PromptPlaying
    /// The speech/prompt pair this session uses whenever the arm is NOT
    /// silent — i.e. exactly what init chose, which is already the null
    /// pair when study mode silences speech. Kept so a mid-session step
    /// OUT of the silent arm restores the same pair rather than
    /// ratcheting the session silent for good.
    private let audibleSpeech: SpeechSynthesizing
    private let audiblePrompts: any PromptPlaying
    /// The study voiceover (P3, 2026-10-04) when this session runs one —
    /// study mode with spoken feedback on — else nil. Held separately so
    /// `applyArmAuthority` can switch its sound EFFECTS with the arm while
    /// its spoken content stays the same in every arm.
    private let studyVoiceover: StudyVoiceoverPromptPlayer?
    /// The German voice the INJECTED synthesiser resolved, captured at
    /// init from `deps.speech` — not from `speech`, which is the null
    /// synthesiser whenever this session silences speech, and would
    /// otherwise make the readout depend on the arm. Shown read-only in
    /// the research dashboard so the proctor can record it (2026-10-05).
    let speechVoice: SpeechVoiceInfo?
    /// FreeWrite buffers + session timing + scoring.
    let freeWriteRecorder = FreeWritePhaseRecorder()

    // MARK: - Private playback / touch state

    var letters: [LetterAsset]          = []
    /// Non-nil when a study session's bundle scan yielded no letters —
    /// the repository's cache/sample fallback is bypassed under
    /// `studyMode`, so this is the refusal's reason (see init).
    private(set) var studyLetterSourceFailure: String?
    var letterIndex                      = 0
    private var variantStrokeCache: LetterStrokes? = nil
    /// Per-script stroke cache; invalidated in `schriftArt.didSet`.
    private var scriptStrokeCache: [SchriftArt: LetterStrokes] = [:]
    var audioIndex                       = 0
    /// Start of the current foreground window. Cleared on background
    /// so the session-duration timer doesn't tick while the iPad
    /// sleeps.
    var letterLoadTime: CFTimeInterval?
    /// Accumulated foreground-only practice time across
    /// background/foreground cycles for the current letter.
    var letterActiveTimeAccumulated: TimeInterval = 0
    /// Wall-clock `Date` of letter load. Distinct from `letterLoadTime`
    /// (CACurrentMediaTime) — survives background cycles.
    var letterLoadedDate: Date?
    var didCompleteCurrentLetter         = false
    /// Captured at selection so `schedulerEffectivenessProxy` has a
    /// real correlation value.
    var lastScheduledLetterPriority: Double = 0
    /// Two-phase init seam: built with a no-op callback, real
    /// `[weak self]` wired after `self` is initialised.
    let playback: PlaybackController
    private let messages: TransientMessagePresenter
    /// Internal (not private) so tests can drive `onCycleComplete`
    /// deterministically instead of waiting on real animation time.
    let animation: AnimationGuideController
    /// Observe-phase cycle counter for auto-advance.
    private var observeCycleCount: Int = 0
    /// Passes the observe demonstration makes before the phase advances.
    /// One, unless `StudyComparisonSettings.observePasses` restores the
    /// former two-pass behaviour for comparison — the supervisor's
    /// "einmal vorzeigen (vielleicht etwas langsamer)" made one pass the
    /// behaviour and this switch the way back to two.
    private let observePasses = StudyComparisonSettings.observePasses
    /// Whether this session practises all five study letters instead of
    /// the counterbalanced three. Off by default; on makes every letter
    /// trained, which removes the within-child trained/untrained
    /// contrast the post-test rests on — the supervisor's "jedes Kind
    /// alle 5 Buchstaben? Aber jeder Buchstabe nur einmal?", offered as a
    /// comparison rather than adopted as the design.
    ///
    /// Assigned in `init`, not from a property initialiser (2026-09-17),
    /// so `TracingDependencies.allFiveLetters` can inject it. Still
    /// captured ONCE — `StudyComparisonSwitchesTests
    /// .switchesAreCapturedAtInit` pins that, and this switch changes
    /// the practice pool, which must not move under a child. `nil` on
    /// the dependency means the device's own setting, unchanged.
    private let allFiveLetters: Bool
    /// How many times each letter's full three-phase flow runs before the
    /// proctor advances. 1 unless the comparison switch says otherwise —
    /// the supervisor's "Buchstabe dreimal?".
    private let letterRepeatCount = StudyComparisonSettings.letterRepeatCount
    /// Whether this session draws the stroke start dots, and whether it
    /// drives stereo pan, and how long it pauses between letters.
    ///
    /// Captured at INIT, like the three above and unlike their first
    /// versions (2026-09-17). Those read `StudyComparisonSettings` live on
    /// every call, which meant `panningEnabled` could be flipped MID-SESSION
    /// from the researcher screen — the manipulation changing under the
    /// child with no restart, which is precisely the failure mode the
    /// switches' footer promises cannot happen ("Änderungen werden beim
    /// nächsten App-Start wirksam"). A comparison run must be a property of
    /// the session that was set up, not something a proctor can change
    /// halfway through one.
    private let dotsVisible = StudyComparisonSettings.guidedDotsVisible
    /// Internal, not private: `TouchDispatcher` reads it on the touch path.
    let panningEnabled = StudyComparisonSettings.panningEnabled
    /// Captured from `TracingDependencies.presentationSpacingSeconds`
    /// (which reads `StudyComparisonSettings` by default) at init.
    private let presentationSpacing: TimeInterval
    /// Whether this session steps through all three audio arms, one per
    /// letter, instead of running the single arm assigned from the
    /// identifier — the supervisor's "alle Konditionen oder nur eine
    /// Kondition", offered as a comparison rather than adopted as the
    /// design.
    ///
    /// Same capture-at-init rule as the switches above, reached by a
    /// different route: it arrives through `TracingDependencies`, so a
    /// test can drive it without writing a `UserDefaults` key that every
    /// other suite in the parallel run would see. See the property's doc
    /// in `TracingDependencies`.
    private let cyclesAudioConditions: Bool
    /// Whether the pre-task demonstration is delivered once per audio
    /// CONDITION per session instead of on every letter load — the
    /// supervisor's "Einmal pro Kondition", OFF by default. Captured at
    /// INIT through `TracingDependencies`, same rule as
    /// `cyclesAudioConditions` beside it. See
    /// `StudyComparisonSettings.oncePerCondition` for the semantics and
    /// for the protocol consequence of switching it ON.
    private let demonstrationsOncePerCondition: Bool
    /// The audio conditions whose pre-task demonstration this SESSION has
    /// already delivered. Read only when
    /// `demonstrationsOncePerCondition` is ON; EMPTY and never written
    /// otherwise, so the default path is untouched by its existence.
    ///
    /// Written where a demonstration is actually ARMED — not on entry to
    /// `armPreTaskDemonstration` — so a branch that faults before arming
    /// (the phoneme arm's missing-file fault, the spatial arm's empty-
    /// sweep fault) does not consume the condition's one demonstration.
    /// The silent arm never writes: it adds no audio by construction
    /// (`PreTaskDemonstration`'s header), so there is nothing for this
    /// switch to suppress there, and the ghost-letter animation that IS
    /// its matched equivalent is a separate mechanism that keeps running
    /// per letter.
    ///
    /// Session-scoped, not device-scoped: cleared by
    /// `reapplyParticipantIdentity` so the next child enrolled on this
    /// iPad starts from an empty set rather than inheriting the outgoing
    /// child's used-up conditions.
    private var demonstratedAudioConditions: Set<PilotAudioCondition> = []
    /// The letter whose trial the CURRENT audio arm belongs to. The arm is
    /// a property of a letter's trial, so the cycle steps only when the
    /// loaded letter actually CHANGES — a re-load of the same letter
    /// (`startParkedLetter`, `repeatCurrentLetterIfConfigured`, a probe
    /// re-entry, a proctor dismissal) must not consume an arm the child
    /// has not finished using.
    ///
    /// `nil` until the launch letter is loaded: the first letter keeps the
    /// arm assigned from the identifier, so a cycle-ON session's first
    /// letter is the same letter-under-arm the same participant would have
    /// run with the switch OFF. Reset by `reapplyParticipantIdentity` so an
    /// incoming child starts from their own assignment.
    private var cycleArmLetter: String?
    /// Whether the spatial arm's pre-task demonstration runs the OLD scripted
    /// axis sweep or holds the carrier steady for the same window. STEADY IS
    /// THE RULED BEHAVIOUR (2026-09-18, "Glissando weg") and the default; the
    /// sweep is kept only as this researcher affordance, and the thesis now
    /// specifies the steady carrier rather than the sweep.
    /// Captured at INIT with the three above, for the
    /// same reason: whether the arm's mapping is INSTALLED by a
    /// demonstration before the task is part of what the session IS, so it
    /// must not be something a proctor can flip under the child half-way
    /// through one. OFF is the default and the behaviour since 6fb7233c;
    /// see `StudyComparisonSettings.spatialAxisDemonstration` for why OFF
    /// is nevertheless a divergence from the written protocol rather than
    /// a neutral default.
    private let axisDemonstrationEnabled = StudyComparisonSettings.spatialAxisDemonstration
    /// What THIS session runs under, as the stamp every row it writes
    /// carries: the non-default comparison switches, or nil when the
    /// session is at every default — the PILOT case, and the case that
    /// must stay an empty column so existing pilot analysis is untouched.
    ///
    /// BUILT ONCE, IN `init`, from the values this session actually
    /// RESOLVED — the injected `TracingDependencies` seams for the five
    /// switches that have one, this type's own captured `let`s for the
    /// other seven — and never recomputed. Deliberately not read at
    /// export time: the export can happen days after the session, on a
    /// device whose switches have since been changed, and a read there
    /// would stamp yesterday's rows with today's configuration. See
    /// `StudyComparisonConfiguration`.
    ///
    /// It is a property of the SESSION rather than of the switch file, so
    /// the value that reaches `PhaseSessionRecord
    /// .comparisonConfiguration` is the one the child's session ran
    /// under, even if a proctor moves a switch afterwards.
    let comparisonConfigurationStamp: String?
    /// Passes completed for the CURRENT letter. Reset when the letter
    /// changes and by `repeatCurrentLetterIfConfigured` when the count is
    /// exhausted.
    private var letterPasses = 1
    /// Idempotency key for `reloadStrokeCheckpoints`. Reset when source
    /// data changes (e.g. calibration save).
    private var lastCheckpointKey: CheckpointBuildKey?

    /// Touch-session state + begin/update/endTouch flow. Two-phase
    /// init pattern (back-reference wired after init).
    let touchDispatcher: TouchDispatcher

    /// Phase-transition pipeline (scoring, post-freeWrite overlays,
    /// controller advance, completion). Two-phase init pattern.
    let phaseTransitions: PhaseTransitionCoordinator

    // MARK: - Init

    @MainActor
    public convenience init() { self.init(.live) }

    @MainActor
    init(_ deps: TracingDependencies = .live) {
        // The silent ARM is authoritative (ruling C3-2, 2026-09-04): its
        // engine is a no-op object, so no audio path — coupling,
        // demonstration, replay, load, playback controller — can make a
        // sound whatever study mode or any pedagogical parameter says.
        // Speech and prompts are nulled for it below on the same footing —
        // EXCEPT in a study session's voiceover (P3, 2026-10-04), whose
        // spoken content every arm hears alike; see `studyVoiceover` below.
        let armIsSilent             = deps.audioCondition == .silent
        let effectiveAudio: AudioControlling = armIsSilent ? SilentAudio() : deps.audio
        self.audio                  = effectiveAudio
        // The REAL engine, kept reachable for the test-only audio probe.
        // MEASURED 2026-10-02 on the device: in the silent arm `audio`
        // is a `SilentAudio`, whose measurement members are no-ops, so
        // every measurement routed through `audio` vanished without a
        // word - and the silent arm is exactly the arm whose output most
        // needs asserting. `deps.audio` is the real engine in every arm,
        // so routing the probe through it works uniformly and changes no
        // playback behaviour: it only reads.
        self.audioSignalProbeSink = deps.audio
        self.progressStore          = deps.progressStore
        // Study sessions: the ONLY audio is the arm's designated sound.
        // Silencing at the injection seam kills every other feedback
        // channel at once — TTS (phase cues, praise, retry lines),
        // prompt MP3s, the celebration chime, tap/buzz/tick effects,
        // and haptics — in ALL arms, so the silent arm is actually
        // silent and the sound arms carry no uncontrolled audio.
        self.haptics                = deps.studyMode ? NullHapticEngine() : deps.haptics
        self.repo                   = deps.repo
        self.streakStore            = deps.streakStore
        self.dashboardStore         = deps.dashboardStore
        self.rawTraceStore          = deps.rawTraceStore
        self.participantArchive     = deps.participantArchive
        self.enrolmentLog           = deps.enrolmentLog
        self.onboardingStore        = deps.onboardingStore
        self.notificationScheduler  = deps.notificationScheduler
        self.observeCueEndToPresentation = deps.observeCueEndToPresentationSeconds
        self.observeCueFallback = deps.observeCueFallbackSeconds
        self.presentationSpacing = deps.presentationSpacingSeconds
        // Study pin (2026-09-04): the pedagogical flow is held constant
        // across arms (DECISIONS.md D1) and the pilot's outcome is the
        // freeWrite phase, which `.guidedOnly` / `.control` omit
        // entirely (`activePhases == [.guided]`). An enrolled install
        // otherwise derives this axis from UUID byte 0, so without this
        // pin ~2/3 of study participants would run a flow with NO
        // freeWrite phase — no primary outcome, no raw trace — and
        // `startPostTest`'s `resume(at: .freeWrite)` would silently
        // no-op on its `activePhases` guard. CI once caught exactly that
        // shape and the fix landed in a test fixture
        // (`StudyLetterSetTests` pins `.threePhase`), never in the app.
        // `ParticipantStore.conditionOverride` still governs the
        // non-study A/B flow; under studyMode it is moot.
        let effectiveCondition: ThesisCondition =
            deps.studyMode ? .threePhase : deps.thesisCondition
        self.thesisCondition        = effectiveCondition
        self.audioCondition         = deps.audioCondition
        self.trainedSubset          = deps.trainedSubset
        // Captured from the injection seam when a test supplies one, the
        // device's own key otherwise. Same once-per-VM capture as
        // `observePasses` above.
        self.allFiveLetters         = deps.allFiveLetters ?? StudyComparisonSettings.allFiveLetters
        self.enablePaperTransfer    = deps.enablePaperTransfer
        self.enableFreeformMode     = deps.enableFreeformMode
        self.enablePhonemeMode      = deps.enablePhonemeMode
        self.studyMode              = deps.studyMode
        self.participantEnrolled    = deps.participantEnrolled
        self.cyclesAudioConditions  = deps.cycleAllConditions
        self.demonstrationsOncePerCondition = deps.oncePerCondition
        self.enableRetrievalPrompts = deps.enableRetrievalPrompts
        self.enableBackwardChaining = deps.enableBackwardChaining
        self.letterRecognizer       = deps.letterRecognizer
        // Same studyMode silencing rationale as `haptics` above — and the
        // silent arm hears no speech or prompt in ANY mode (C3-2).
        //
        // The study-mode half is now switchable, on the supervisor's
        // "Voiceover??" (2026-09-17): `StudyComparisonSettings
        // .spokenFeedbackInStudy` restores the casual app's spoken
        // feedback inside a study session so the two can be compared.
        //
        // DEFAULT IS NOW ON (2026-10-02, David's decision after a proctor
        // run on the physical iPad): at OFF the phase prompts never
        // reached a child, which is exactly the complaint. The thesis
        // line this used to match ("no spoken prompts",
        // 03-architecture.typ:73) no longer describes the artefact and
        // must move with it. Setting the switch back to OFF restores the
        // thesis behaviour for a comparison run.
        //
        // The SILENT-ARM half stays unconditional and is evaluated first:
        // that is the arm's authority (C3-2), not a display preference,
        // and no comparison switch may put sound into the one arm whose
        // entire manipulation is the absence of it.
        // Read ONCE into a local, so the substitution below and the
        // session's configuration stamp further down cannot disagree
        // about which value this session ran under.
        let spokenFeedbackInStudy = deps.spokenFeedbackInStudy
            ?? StudyComparisonSettings.spokenFeedbackInStudy
        //
        // STUDY VOICEOVER (P3, David 2026-10-04): the spoken content is
        // IDENTICAL in ALL THREE ARMS. In study mode with spoken feedback
        // on, the silent arm no longer loses its speech: speech is not
        // sonification, and an arm that never hears "Jetzt du." is a
        // second manipulation the design does not contain. The prompts go
        // through `StudyVoiceoverPromptPlayer`, which passes the study's
        // spoken phrases in every arm alike and forwards the non-speech
        // effects (tick, chimes) for the sound arms only. The silent arm's
        // SONIFICATION stays off unconditionally — `effectiveAudio` above
        // and `TouchDispatcher`'s silent-arm return, neither touched here.
        //
        // Outside study mode the casual path is unchanged: the silent arm
        // nulls speech and prompts (C3-2). Study mode with the switch OFF
        // is unchanged too: the null pair for every arm.
        let studyVoiceoverOn = deps.studyMode && spokenFeedbackInStudy
        let silenceSpeech = studyVoiceoverOn
            ? false
            : (armIsSilent || deps.studyMode)
        let studyVoiceover: StudyVoiceoverPromptPlayer? = studyVoiceoverOn
            ? StudyVoiceoverPromptPlayer(inner: deps.makePromptPlayer(deps.speech),
                                         soundEffectsAllowed: !armIsSilent)
            : nil
        self.studyVoiceover = studyVoiceover
        // Built once, stored twice: `audible*` is the pair this session
        // uses in every non-silent arm, and the live properties start
        // there too (which IS the null pair when the arm assigned at
        // launch is silent outside the study voiceover, or study mode
        // silences speech). A later arm step re-points the live pair and
        // restores from here — see `applyArmAuthority`.
        let audibleSpeech: SpeechSynthesizing = silenceSpeech ? NullSpeechSynthesizer() : deps.speech
        let audiblePrompts: any PromptPlaying
        if let studyVoiceover {
            audiblePrompts = studyVoiceover
        } else if silenceSpeech {
            audiblePrompts = NullPromptPlayer()
        } else {
            audiblePrompts = deps.makePromptPlayer(deps.speech)
        }
        self.speechVoice            = deps.speech.resolvedVoice
        self.audibleSpeech          = audibleSpeech
        self.audiblePrompts         = audiblePrompts
        self.speech                 = audibleSpeech
        self.prompts                = audiblePrompts
        // Control condition uses fixed difficulty so the manipulation
        // can't confound the phase-progression IV. Study devices pin
        // difficulty at the standard tier for the same reason — the
        // pilot's IV is the audio arm, and an adapting checkpoint
        // radius would vary the guided task between children.
        self.adaptationPolicy       = deps.adaptationPolicy ?? (
            deps.thesisCondition == .control || deps.studyMode
                ? FixedAdaptationPolicy(currentTier: .standard)
                : MovingAverageAdaptationPolicy()
        )

        // Honour any recorded variant so post-hoc analysis sees the
        // first-encounter variant for this participant; otherwise
        // fall back to the parent's toggle.
        let useShort = UserDefaults.standard.bool(forKey: "de.flamingistan.primae.useShortOnboarding")
        let recordedVariant = deps.onboardingStore.variantUsed
        let activeVariant: OnboardingVariant = recordedVariant ?? (useShort ? .short : .full)
        self.onboardingVariant = activeVariant

        var coordinator = OnboardingCoordinator(steps: activeVariant.steps)
        if let savedStep = deps.onboardingStore.savedStep,
           activeVariant.steps.contains(savedStep) {
            coordinator.resume(at: savedStep)
        }
        self.onboardingCoordinator = coordinator
        self.onboardingStep        = coordinator.currentStep
        self.isOnboardingComplete  = deps.onboardingStore.hasCompletedOnboarding
        self.phaseController = LearningPhaseController(condition: effectiveCondition)
        // Study pins: the pilot is Druckschrift-only and its letter
        // order must be identical across children/devices — a stray
        // device setting must not swap the stimulus geometry or the
        // sequence. Session-only (init assignment skips the didSets,
        // so the stored parent settings survive studyMode).
        self.schriftArt = deps.studyMode ? .druckschrift : deps.schriftArt
        self.letterOrdering = deps.studyMode ? .motorSimilarity : deps.letterOrdering

        // Per-VM controllers from factories so tests can swap any one
        // without subclassing.
        self.messages         = deps.makeMessagePresenter()
        self.animation        = deps.makeAnimationGuide()
        self.calibrationStore = deps.makeCalibrationStore()
        self.letterScheduler  = deps.makeLetterScheduler()

        haptics.prepare()
        // Two-phase init: build with a no-op callback, wire the real
        // `[weak self]` once every stored property is assigned.
        let pb = deps.makePlaybackController(effectiveAudio) { _ in }
        self.playback = pb
        // Same pattern for touchDispatcher / phaseTransitions.
        let td = TouchDispatcher()
        // The sound gate's two ANDed trigger boundaries, captured HERE —
        // once, at view-model construction, so a proctor cannot move them
        // under a child mid-session (the property `StudyComparisonSwitches
        // Tests.switchesAreCapturedAtInit` pins for the older switches).
        //
        // One of them lands on the dispatcher, which the VM owns for the
        // life of the session. The other lands on the GRID, not on a
        // tracker: cells are rebuilt from scratch on every letter and every
        // preset flip (`SequenceGridController.load`), so a value written
        // onto `strokeTracker` in place would be silently discarded at the
        // next letter — an inert switch, which is the failure this project
        // has already shipped once. `grid.soundGateRadiusFactor` re-applies
        // itself to every cell it builds, so no load path can miss it.
        self.touchDispatcher = td
        td.playbackActivationVelocityThreshold = CGFloat(deps.soundGateVelocityFloor)
        grid.soundGateRadiusFactor = CGFloat(deps.soundGateRadiusFactor)
        let ptc = PhaseTransitionCoordinator()
        self.phaseTransitions = ptc
        // The session's comparison configuration, stamped once, here.
        // Every value is one this session already resolved — the `let`s
        // above and the `TracingDependencies` seams — so the stamp cannot
        // drift from the behaviour it describes, and it is fixed before
        // the first row can be written. It sits at the end of the
        // property assignments (immediately before the `[weak self]`
        // wiring below) because Swift requires every stored property
        // initialised before `self` may escape.
        self.comparisonConfigurationStamp = StudyComparisonConfiguration(
            observePasses: observePasses,
            spokenFeedbackInStudy: spokenFeedbackInStudy,
            allFiveLetters: allFiveLetters,
            letterRepeatCount: letterRepeatCount,
            cycleAllConditions: deps.cycleAllConditions,
            presentationSpacingSeconds: presentationSpacing,
            panningEnabled: panningEnabled,
            guidedDotsVisible: dotsVisible,
            spatialAxisDemonstration: axisDemonstrationEnabled,
            soundGateRadiusFactor: deps.soundGateRadiusFactor,
            soundGateVelocityFloor: deps.soundGateVelocityFloor,
            oncePerCondition: deps.oncePerCondition
        ).nonDefaultStamp
        pb.onIsPlayingChanged = { [weak self] in self?.isPlaying = $0 }
        pb.reloadBeforePlay   = { [weak self] in self?.reloadActiveAudioFile() }
        td.vm = self
        ptc.vm = self
        // The observe sound tracks the animated dot (2026-10-05), and the
        // observe presentation waits for the spoken cue to END. The cue is
        // spoken through the prompt player built from `deps.speech`, so
        // that synthesiser's end-of-utterance report is the one to hear.
        animation.onFrame = { [weak self] frame in self?.handleGuideFrame(frame) }
        deps.speech.setUtteranceEndHandler { [weak self] text, cancelled in
            self?.cueUtteranceEnded(text: text, cancelled: cancelled)
        }
        // Same two-phase pattern: `self` is fully assigned now, so it's
        // safe to capture weakly. Subscribes to the FIRST disk-write
        // failure any study data store reports — see
        // PersistenceFailureCenter and `handlePersistenceFailure`.
        PersistenceFailureCenter.shared.subscribe { [weak self] description in
            self?.handlePersistenceFailure(description)
        }
        // Study devices always parse the bundle. `loadLettersFast()`
        // serves the on-disk letter cache whenever its sentinel matches
        // `CFBundleShortVersionString-CFBundleVersion` — which is the
        // constant "1.0-1" in every configuration of this project — so a
        // study build re-deployed over an existing install would keep
        // tracing and SCORING the previous build's strokes.json while
        // `resolvedStrokes(for:)` reports "bundle geometry". The frozen-
        // stimulus claim (thesis Ch.5) rests on the bundle, not on a
        // cache keyed by a version string nobody bumps (2026-09-04).
        // And never the cache-or-sample fallback either: `loadLetters()`
        // "never returns empty", so a study device whose bundle scan
        // failed would trace a previous build's cached geometry or a
        // synthetic "A" and stamp ordinary rows. Bundle or refuse
        // (audit 2026-09-06; the precondition below carries the text).
        if deps.studyMode {
            switch repo.loadBundledLettersOnly() {
            case .success(let bundled):
                letters = bundled
            case .failure(let error):
                letters = []
                studyLetterSourceFailure = String(describing: error)
            }
        } else {
            letters = repo.loadLettersFast()
        }
        // Seed the mirror so the rail badge + gallery pick up
        // pre-existing progress on first render.
        allProgress = progressStore.allProgress
        // Surface startup audio failures as a brief toast.
        if let audioError = effectiveAudio.initializationError {
            messages.show(toast: audioError)
        }
        loadFirstTrainedLetter()
    }

    /// Loads the launch/current participant's first trained letter,
    /// parked (no phase cue). Factored out of `init` (2026-09-14) so
    /// `reapplyParticipantIdentity` can re-run exactly this step for an
    /// incoming child without repeating the rest of init's one-time
    /// setup.
    ///
    /// Under studyMode the launch letter is the FIRST TRAINED letter,
    /// not `letters.first`: the repository sorts by name, so every
    /// device used to open on "A" — an UNTRAINED letter for the four
    /// subsets without it (FIL, FIM, FLM, ILM), fully traceable with
    /// scaffolding because `load(letter:)` never consults the
    /// `visibleLetterNames` filter, and with A's observe animation
    /// and sound-arm demonstration armed before any cold probe of A
    /// (audit 2026-09-06). The trained pool is empty only when the
    /// bundle is (refused earlier) — then nothing loads.
    private func loadFirstTrainedLetter() {
        let first: LetterAsset?
        if studyMode {
            first = visibleLetterNames.first.flatMap { name in
                letters.first(where: { $0.name == name })
            }
        } else {
            first = letters.first
        }
        guard let first else { return }
        letterIndex = letters.firstIndex(where: { $0.name == first.name }) ?? 0
        // Don't play the phase cue here — the audio session hasn't
        // settled and would produce ~2 s of crackle. A study launch is
        // PARKED (see `launchParked`).
        load(letter: first, playPhaseCue: false, parked: studyMode)
    }

    // MARK: - Toggles

    func toggleGhost()             { showGhost.toggle();         toast("Hilfslinien \(showGhost ? "an" : "aus")") }

    /// Switch between standard and variant stroke form. Reloads
    /// checkpoints + resets tracing progress; phase state unchanged.
    func toggleVariant() {
        guard currentLetterHasVariants, letters.indices.contains(letterIndex) else { return }
        let letter = letters[letterIndex]
        showingVariant.toggle()
        if showingVariant && variantStrokeCache == nil {
            variantStrokeCache = loadVariantStrokesFromBundle(for: letter)
        }
        lastCheckpointKey = nil
        strokeTracker.reset()
        progress = 0
        activePath.removeAll(keepingCapacity: true)
        reloadStrokeCheckpoints(for: letter)
        toast(showingVariant ? "Variante" : "Standard")
    }

    private func loadVariantStrokesFromBundle(for letter: LetterAsset) -> LetterStrokes? {
        guard let variantID = letter.variants?.first else { return nil }
        return repo.loadVariantStrokes(for: letter.name, variantID: variantID)
    }

    /// Bundle strokes for the active script (loads
    /// `strokes_<variantID>.json` on first access). `nil` for
    /// Druckschrift (uses LetterAsset directly) or when no variant
    /// file exists. Driven by `SchriftArt.bundleVariantID`.
    private var activeScriptStrokes: LetterStrokes? {
        guard !letters.isEmpty, letterIndex < letters.count,
              let variantID = schriftArt.bundleVariantID else { return nil }
        if let cached = scriptStrokeCache[schriftArt] { return cached }
        guard let loaded = repo.loadVariantStrokes(
            for: letters[letterIndex].name, variantID: variantID) else { return nil }
        scriptStrokeCache[schriftArt] = loaded
        return loaded
    }

    // MARK: - Accessibility

    var accessibilityCanvasLabel: String {
        "Schreibfläche — Buchstabe \(currentLetterName)"
    }

    var accessibilityCanvasValue: String {
        // No numeric readout in a study session (2026-09-17). The thesis
        // is explicit that a child on a study device sees no numeric
        // measure — "every numeric measure lives behind a parental gate"
        // (03-architecture.typ:10) and study mode "removes every ... that
        // is not the arm's designated audio" (:73). A VoiceOver user was
        // hearing "50 Prozent fertig" on the tracing canvas, which is the
        // one child-facing surface where the measure is being produced.
        // Wording, not a number, is all that is left, so the state is
        // still announced and only its precision is withheld.
        if studyMode { return progress >= 1 ? "Fertig" : "In Arbeit" }
        let pct = Int(max(0, min(1, progress)) * 100)
        if pct == 0   { return "Nicht begonnen" }
        if pct == 100 { return "Fertig" }
        return "\(pct) Prozent fertig"
    }

    /// Autoplay the active cell's letter audio on cell advance in
    /// word mode. Always variant 0; silent for letters without audio.
    func autoplayActiveCellLetter() {
        let activeLetter = gridCellLetter(at: gridActiveCellIndex) ?? currentLetterName
        guard let asset = letters.first(where: { $0.name == activeLetter }),
              let first = activeAudioFiles(for: asset).first else { return }
        audio.loadAudioFile(named: first, autoplay: true)
    }

    /// Load the active cell's arm file WITHOUT autoplay. Called at every
    /// touch-down and — since 2026-09-06 — before every `play()`: the
    /// engine's `stop()` discards its file (`finishStop`: `currentFile =
    /// nil`) and `play()` is a no-op without one, so after the idle
    /// transition fired mid-stroke (a ≥ 0.12 s pause) the rest of that
    /// stroke was silent in both sound arms while `isPlaying` read true.
    /// Silent arm: no files, nothing loads.
    func reloadActiveAudioFile() {
        guard letters.indices.contains(letterIndex) else { return }
        let files = activeAudioFiles(for: letters[letterIndex])
        guard files.indices.contains(audioIndex) else { return }
        audio.loadAudioFile(named: files[audioIndex], autoplay: false)
    }

    func replayAudio() {
        // Study sessions: no on-demand replay. The arm's sound reaches
        // the child ONLY through the trace coupling (thesis Ch.4) and
        // the observe demonstration — the whole-observe sound (P4), or
        // the 2 s window under the axis-sweep switch. This entry is
        // wired to the Apple Pencil squeeze / double-tap, a VoiceOver
        // custom action, and the retrieval prompt — none of which the
        // design describes, all of which would add sound-arm-only
        // exposure the silent arm cannot match (its file list is
        // empty), in whatever phase they fire in (`loadAudioFile(
        // autoplay: true)` loops the file regardless of phase — a
        // second, child-triggered playback layered over the writing
        // passes' own coupling). Gated 2026-09-04; the freeWrite
        // sound-off gate it also cited was lifted 2026-10-02 (#27) and
        // is no longer a reason.
        guard !studyMode else { return }
        // Reloads and autoplays the active cell's letter audio.
        // Silence is acceptable for letters without audio assets.
        let activeLetter = gridCellLetter(at: gridActiveCellIndex)
            ?? currentLetterName
        guard let asset = letters.first(where: { $0.name == activeLetter }) else { return }
        let files = activeAudioFiles(for: asset)
        guard files.indices.contains(audioIndex) else { return }
        audio.loadAudioFile(named: files[audioIndex], autoplay: true)
    }

    /// Audio file list for the active pilot arm (`audioCondition`). The
    /// arm chooses the CONTENT; the adaptive-playback coupling
    /// (TouchDispatcher.updateAdaptivePlayback) is identical for both
    /// sound arms and reads none of this — only the file list differs
    /// (§2.6 matching discipline). Silent returns []; every read site
    /// short-circuits on an empty list, so no file is ever loaded and no
    /// loop can play.
    func activeAudioFiles(for asset: LetterAsset) -> [String] {
        switch audioCondition {
        case .silent:
            return []
        case .spatial:
            // One shared, letter-independent carrier tone: the arm's
            // information channel is pen position (Y→pitch, X→pan), not
            // sound identity. No fallback to name audio: that would leak
            // letter-name content into the non-phonemic arm and confound
            // the contrast. `studyMode` is irrelevant here — the carrier
            // is bundled, so there is nothing to force or degrade to.
            return [SpatialSonification.carrierToneFile]
        case .phoneme:
            // H2.1 — study devices force phoneme content. A phoneme-arm
            // participant must hear the phoneme, never the letter name,
            // regardless of the parent `enablePhonemeMode` toggle (an
            // unset toggle would otherwise corrupt the IV silently). This
            // resolves at letter-load time, never on the per-tick
            // coupling path, so the matching discipline is untouched.
            if studyMode {
                if !asset.phonemeAudioFiles.isEmpty {
                    return asset.phonemeAudioFiles
                }
                // FAIL CLOSED (ruling C3-6, 2026-09-04). This letter has
                // no phoneme recording (the H5 gap). Degrading to the
                // name/word audio used to play a WRONG stimulus under the
                // phoneme label (for M the first name file is the word
                // "Meer"); returning nothing here alone would make a
                // second silent arm nobody notices. So: no file, AND the
                // session is refused before any trace can start — see
                // `studyPreconditionFailure`, which the Schule surface
                // shows and `beginTouch` honours.
                pilotAudioLogger.error(
                    "Phoneme-arm study device: letter '\(asset.name, privacy: .public)' has no phoneme recording — REFUSING (H5). No name/word audio is substituted.")
                return []
            }
            // Off study devices: preserve the exact pre-pilot toggle so
            // casual users are byte-identical.
            if enablePhonemeMode, !asset.phonemeAudioFiles.isEmpty {
                return asset.phonemeAudioFiles
            }
            return asset.audioFiles
        }
    }

    // MARK: - Within-subject arm cycle (comparison runs only)

    /// Step the audio arm at a letter boundary when the session is a
    /// cycle-all-conditions comparison run. Called from `load(letter:)`
    /// only, and only after that method has recorded the OUTGOING letter's
    /// unload row — both facts are load-bearing, see the call site.
    ///
    /// The step is keyed on the letter actually changing, not on `load`
    /// being called: a re-load of the same letter is not a new trial, and
    /// the arm a child is mid-way through must survive it. The cycle wraps
    /// (silent → phoneme), which is what makes an all-five-letter session
    /// work and what makes a proctor's back-and-forth navigation
    /// well-defined.
    private func cycleAudioConditionIfConfigured(toLetterNamed name: String) {
        guard cyclesAudioConditions else { return }
        guard let armLetter = cycleArmLetter else {
            // Launch letter: ADOPTS the arm assigned from the identifier
            // (or the researcher override) instead of consuming a step.
            // So a cycle-ON session's first letter is the same
            // letter-under-arm the same child would have run with the
            // switch OFF, and the identifier's own modulo assignment
            // distributes the cycle's starting point across children
            // rather than starting everyone at `.phoneme`.
            cycleArmLetter = name
            return
        }
        guard armLetter != name else { return }
        cycleArmLetter = name
        applyArm(audioCondition.nextInCycle)
    }

    /// Make `next` the session's arm, with the authority the arm carries.
    ///
    /// Internal, not private, as a TEST SEAM — the same call this codebase
    /// makes for `panningEnabled` and `LetterRepository.init(weight:)`.
    /// The C3-2 property applied here is reachable on TWO paths: the
    /// comparison cycle's letter boundary, and `reapplyParticipantIdentity`
    /// on new-child enrolment. Only the first is testable without this
    /// seam — enrolment's arm is UUID-derived, so a test driving it would
    /// exercise the silent branch roughly one draw in three and quietly
    /// pass the rest of the time. A property that holds two times in three
    /// is not pinned.
    func applyArm(_ next: PilotAudioCondition) {
        guard next != audioCondition else { return }
        // A pending observe sound was claimed under the outgoing arm:
        // drop the SOUND, keep the presentation. Cancelling the whole
        // pending start (as before Option B) would now also cancel the
        // observe animation, and observe ends only when that animation
        // completes its pass — the phase would never end.
        pendingObserveSoundArm = nil
        audioCondition = next
        applyArmAuthority()
    }

    /// The current arm's own authority (ruling C3-2), applied whenever the
    /// arm CHANGES. At launch this is done by construction — the silent
    /// arm is handed a `SilentAudio` engine and a null speech/prompt pair
    /// (`init`) — but construction happens once, and the comparison cycle
    /// can reach the silent arm later.
    ///
    /// What "silent" rests on for an arm reached mid-session, path by
    /// path: the engine is stopped (its `stop()` clears the loaded file,
    /// and its `play()` is a no-op without one), any in-flight pre-task
    /// demonstration is cancelled, `activeAudioFiles` returns [] so no
    /// load site can hand the engine a file, `TouchDispatcher`'s coupling
    /// short-circuits on the live arm, and the speech/prompt pair becomes
    /// the null one. Stepping back OUT restores the pair the session
    /// began with, so this is a state, not a one-way ratchet.
    ///
    /// In a study session running the voiceover (P3, 2026-10-04) the pair
    /// is NOT nulled: the silent arm hears the same spoken content as every
    /// arm, and only the voiceover's sound effects (tick, chimes) switch
    /// off with the arm.
    ///
    /// The remaining guarantee is the one construction gives and this
    /// cannot: `vm.audio` stays the same object, so the ENGINE is a real
    /// one holding no file rather than the `SilentAudio` no-op. Same
    /// quiet, different mechanism.
    private func applyArmAuthority() {
        // Study voiceover (P3): the spoken content stays the same in
        // every arm, so the speech/prompt pair is NOT nulled for the silent
        // arm here — only its sound effects stop, below, and its engine.
        studyVoiceover?.soundEffectsAllowed = audioCondition != .silent
        guard audioCondition == .silent else {
            speech  = audibleSpeech
            prompts = audiblePrompts
            return
        }
        if studyVoiceover != nil {
            cancelPreTaskDemonstration()
            audio.stop()
            playback.request(.idle, immediate: true)
            return
        }
        cancelPreTaskDemonstration()
        speech.stop()
        speech  = NullSpeechSynthesizer()
        prompts = NullPromptPlayer()
        audio.stop()
        playback.request(.idle, immediate: true)
    }

    // MARK: - Pre-task sound-arm demonstration

    /// Cancel any in-flight pre-task demonstration. Called the moment a
    /// real touch begins so the child's own trace is never racing a
    /// scripted demo point for the shared `setAdaptivePlayback`/
    /// `setSpatialPitch` calls — `TouchDispatcher.beginTouch` already
    /// reloads the real per-touch audio file regardless, which alone
    /// would supersede the demo's own file, but cancelling here also
    /// stops the demo's own sweep loop from continuing to run at all.
    func cancelPreTaskDemonstration() {
        preTaskDemoTask?.cancel()
        preTaskDemoTask = nil
    }

    /// Arm the pre-task sound-arm demonstration for a freshly loaded
    /// letter. Pilot-only (gated on `studyMode`, same gate H2.1 uses to
    /// force phoneme content) — casual, non-study sessions are
    /// unaffected. See `PreTaskDemonstration`'s header for the full
    /// rationale and the per-arm content. `duration` defaults to
    /// `PreTaskDemonstration.duration`; overridable so tests don't have
    /// to wait out the full production window.
    ///
    /// Not `private` — called from `load(letter:)`'s two fresh-letter
    /// entry points (observe and direct-to-guided), and directly from
    /// tests.
    func armPreTaskDemonstration(for letter: LetterAsset,
                                 duration: TimeInterval = PreTaskDemonstration.duration) {
        preTaskDemoTask?.cancel()
        preTaskDemoTask = nil
        guard studyMode else { return }
        // "Einmal pro Kondition" (comparison runs only, OFF by default).
        // ON delivers this demonstration at the first letter loaded in
        // each audio condition and on no later letter in it; OFF is the
        // behaviour every build before the switch had — a demonstration
        // ahead of EVERY letter. The read is here, beside the other
        // guards; the write is at each arming point below, so a branch
        // that faults before it arms does not consume the condition. See
        // `StudyComparisonSettings.oncePerCondition` for why OFF is the
        // default and what ON costs the protocol.
        if demonstrationsOncePerCondition,
           demonstratedAudioConditions.contains(audioCondition) {
            return
        }
        switch audioCondition {
        case .silent:
            // No added audio — the unchanged ghost-letter animation
            // already running for this letter load IS the matched
            // non-auditory equivalent. See PreTaskDemonstration header.
            return
        case .phoneme:
            guard let first = activeAudioFiles(for: letter).first else {
                // Unreachable behind `studyPreconditionFailure`; if it ever
                // is reached, it is a fault, not a quiet skip (C1-6).
                pilotAudioLogger.fault("Pre-task demonstration SKIPPED: no phoneme file for \(letter.name, privacy: .public) — the session should have been refused.")
                return
            }
            // Past this branch's only failure path, so the condition's
            // one demonstration is spent HERE and not on a letter whose
            // phoneme file was missing.
            demonstratedAudioConditions.insert(audioCondition)
            preTaskDemoTask = Task { [weak self] in
                // `.cancel()` only flips this flag — it does NOT stop
                // the closure from starting, so a task cancelled before
                // it ever ran (e.g. superseded by another
                // `armPreTaskDemonstration` call before this one got a
                // scheduler turn) would otherwise still fire the load
                // below. Checked BEFORE any side effect, not just before
                // the sleep.
                guard let self, !Task.isCancelled else { return }
                // Rate/pan reset before playing — mirrors the .spatial
                // branch below. Without this, the phoneme plays at
                // whatever rate/pan the PREVIOUS letter's touch coupling
                // left the engine in, from the second letter on.
                self.audio.setAdaptivePlayback(speed: 1.0, horizontalBias: 0)
                self.audio.loadAudioFile(named: first, autoplay: true)
                try? await Task.sleep(for: .seconds(duration))
                // loadAudioFile(autoplay: true) schedules LOOPING
                // playback (AudioEngine.scheduleLooping) — without this
                // stop, the phoneme keeps looping past the intended
                // 2.0 s window for the rest of the (touch-disabled)
                // observe phase. Guarded like .spatial's own stop below:
                // a cancelled task (superseded by the next letter, or a
                // real touch beginning) skips it, since a fresher demo
                // or the real touch coupling is already driving the
                // engine by then.
                if !Task.isCancelled { self.audio.stop() }
            }
        case .spatial:
            // TWO BEHAVIOURS, ONE SWITCH (2026-09-17). The spatial arm's
            // pre-task demonstration is either the WINDOW alone with the
            // carrier held steady — the RULED behaviour (2026-09-18) and the
            // default — or the old scripted axis sweep, kept only as a
            // researcher affordance. The sweep left the flow on the
            // supervisor's "Glissando weg" (6fb7233c) and is no longer what
            // the protocol specifies, so OFF is not a divergence.
            // `StudyComparisonSettings.spatialAxisDemonstration` selects
            // between them, captured at init with the other comparison
            // switches.
            //
            // WHAT BOTH SHARE. The carrier loads and autoplays for the same
            // `duration` either way, and stops when the window ends, so this
            // arm runs a demonstration of the same length as the phoneme
            // arm's — the duration match that 04-implementation.typ:17 and
            // 06-evaluation.typ:62 both rest on. Dropping the window would
            // have made this arm's demonstration shorter than the phoneme
            // arm's, which is the one thing the shared window exists to
            // prevent. Neither behaviour is trace-coupled: this runs on its
            // own scripted timeline, never through `TouchDispatcher`.
            //
            // The tracing-time pitch mapping is untouched in both: pen Y
            // still drives pitch in the guided phase through
            // `TouchDispatcher`, and that is the arm's manipulation. The
            // switch governs the pre-task demonstration only.
            //
            // `duration <= 0` makes `axisSweep` produce no samples. That is
            // reachable from tests but not from production (the default is
            // `PreTaskDemonstration.duration`, 2.0 s), and it is checked
            // BEFORE the load precisely so the fault below cannot leave a
            // looping carrier behind.
            let sweepSamples = axisDemonstrationEnabled
                ? PreTaskDemonstration.axisSweep(duration: duration)
                : []
            if axisDemonstrationEnabled && sweepSamples.isEmpty {
                // A FAULT, NOT A QUIET SKIP (C1-6) — symmetry with
                // `.phoneme` (2026-09-17).
                //
                // The phoneme branch cannot reach its demonstration
                // without a file: the carrier precondition and the
                // phoneme precondition each refuse the session first, and
                // the branch above logs a fault if it is somehow reached
                // anyway. This branch has no such guarantee. `axisSweep`
                // is the ONLY thing between the spatial arm and a
                // demonstration that never plays, and returning silently
                // would leave: no sound, no on-screen signal, nothing in
                // the record.
                //
                // For a study arm whose entire manipulation IS that sound,
                // a silently-absent demonstration is a data-validity
                // confound rather than a cosmetic gap — the session would
                // run, record, and be analysed as though the spatial arm
                // had been delivered. Refusing loudly costs nothing
                // audible and cannot be mistaken for a delivered arm.
                pilotAudioLogger.fault("Pre-task demonstration SKIPPED: axisSweep produced no samples for the spatial arm (duration \(duration, privacy: .public)s) — the arm's stimulus would be absent, so this is a fault and not a quiet skip.")
                return
            }
            // Past the fault guard above, so the condition's one
            // demonstration is spent here rather than on the letter that
            // hit the empty-sweep fault. BOTH sub-branches below deliver a
            // demonstration — the sweep, or the steady window — so this
            // sits ahead of the split, not inside one half of it.
            demonstratedAudioConditions.insert(audioCondition)
            audio.loadAudioFile(named: SpatialSonification.carrierToneFile, autoplay: true)
            if axisDemonstrationEnabled {
                // ON: the OLD axis demonstration, kept as a researcher
                // affordance only — not the specified behaviour since the
                // 2026-09-18 ruling. Pitch follows
                // the sweep point's vertical leg, pan its horizontal one,
                // one full top→bottom→top pass over the shared window.
                preTaskDemoTask = Task { [weak self] in
                    guard let self, !Task.isCancelled else { return }
                    var previousElapsed: TimeInterval = 0
                    for sample in sweepSamples {
                        if Task.isCancelled { break }
                        let dt = sample.elapsed - previousElapsed
                        if dt > 0 { try? await Task.sleep(for: .seconds(dt)) }
                        previousElapsed = sample.elapsed
                        if Task.isCancelled { break }
                        self.audio.setAdaptivePlayback(
                            speed: 1.0,
                            horizontalBias: Float(max(-1.0, min(1.0, sample.point.x * 2.0 - 1.0))))
                        self.audio.setSpatialPitch(
                            cents: SpatialSonification.pitchCents(forNormalizedY: sample.point.y))
                    }
                    // Same guard shape as the OFF branch below and as the
                    // phoneme branch: a cancelled task means a fresher
                    // demonstration or the real touch coupling is already
                    // driving the engine, and stopping here would cut it.
                    if !Task.isCancelled { self.audio.stop() }
                }
            } else {
                // OFF: the window without the movement. Neutral rate,
                // centre pan and zero pitch for the whole `duration`.
                audio.setAdaptivePlayback(speed: 1.0, horizontalBias: 0)
                audio.setSpatialPitch(cents: 0)
                preTaskDemoTask = Task { [weak self] in
                    guard let self, !Task.isCancelled else { return }
                    try? await Task.sleep(for: .seconds(duration))
                    if !Task.isCancelled { self.audio.stop() }
                }
            }
        }
    }

    // MARK: - Letter navigation

    func resetLetter() {
        strokeTracker.reset()
        // `reset()` drops the definition; the checkpoints have to come
        // back or nothing can be hit. This used to be masked by the
        // dispatcher re-mapping checkpoints on every touch update while
        // `vm.canvasSize` lagged the overlay (CI run 1649, 2026-09-05).
        if letters.indices.contains(letterIndex) {
            reloadStrokeCheckpoints(for: letters[letterIndex])
        }
        progress = 0
        activePath.removeAll(keepingCapacity: true)
        touchDispatcher.resetVelocity()
        playback.resumeIntent = false
        playback.cancelPending()
        audio.stop()
        playback.forceIdle()
        isPlaying = false
        didCompleteCurrentLetter = false
        messages.clearCompletionState()
        stopGuideAnimation()
        toast("Zurückgesetzt")
    }

    func loadLetter(name: String) {
        guard let idx = letters.firstIndex(where: { $0.name == name }) else { return }
        letterIndex = idx
        // Reset the repeat counter HERE, not in `load(letter:)` (2026-09-17).
        // It used to be reset only by `nextLetter`/`previousLetter`/
        // `randomLetter`, so any other way of changing letter leaked the
        // pass count — and this is the path the cold probes take
        // (`startColdProbe`). With the repeat switch at 3, a post-test
        // probe on an UNTRAINED letter could inherit a stale count, then
        // repeat after its one-shot override had already been consumed,
        // re-entering observe and writing training rows for a letter the
        // design requires to be untrained. Default is 1, so this could not
        // reach pilot data — but it is exactly the contrast H6 rests on.
        //
        // Deliberately NOT in `load(letter:)`: the repeat path calls that
        // directly, and resetting there would make the repeat reset its
        // own counter and loop forever.
        letterPasses = 1
        load(letter: letters[idx])
        toast("Buchstabe: \(currentLetterName)")
    }

    /// H6 post-test: load one of the two study letters this participant
    /// does NOT train, for a single COLD `freeWrite` pass. `load(letter:)`
    /// normally resets into `observe` (or `guided`, per thesis condition);
    /// this jumps straight to `freeWrite` instead, because reaching
    /// observe or guided at all would BE training the letter — the exact
    /// thing the within-child trained-vs-untrained contrast depends on
    /// not happening. No new export tagging is needed: `trainedSubset` is
    /// already stamped on every `PhaseSessionRecord`, so a freeWrite row
    /// for a letter outside it is already legible as untrained.
    ///
    /// Guarded on `studyMode` and on the letter actually being untrained —
    /// the researcher UI only ever offers the untrained pair, but the VM
    /// re-checks so a stale UI state can't start a real practice session
    /// under the post-test label. `loadLetter` itself is NOT gated by
    /// `visibleLetterNames` (that filter is UI-only), which is what makes
    /// this reachable at all.
    @discardableResult
    func startPostTest(letter: String) -> String? {
        startColdProbe(letter: letter, kind: .posttest)
    }

    /// Open a study letter COLD in the freeWrite phase as the given probe
    /// (2026-09-04, generalising the H6 post-test route). `.pretest` and
    /// `.delayed` accept any of the five study letters — the thesis's
    /// pretest covers all five, trained included, and so does the delayed
    /// retention test; `.posttest` keeps H6's restriction to the untrained
    /// pair. The kind is stamped on the letter's rows. Refused outside
    /// study mode and for any letter outside the study set.
    /// Returns `nil` on success, or a short German proctor-facing reason
    /// when the probe was silently refused (2026-09-15: the researcher UI
    /// used to swallow every refusal — the proctor saw no reaction at all
    /// and had no way to tell "refused" apart from "the dismissal didn't
    /// work"). Callers that don't need the reason may ignore it.
    ///
    /// Checks `studyLetterSourceFailure` directly — not the full
    /// `sessionBlockReason` umbrella — before calling `loadLetter`
    /// (2026-09-15, second pass). Reason: the Schule canvas and
    /// `TouchDispatcher` already refuse loudly on `sessionBlockReason`
    /// (a bundle-scan failure leaving `letters` empty, a missing spatial
    /// carrier tone, missing phoneme recordings, a persistence failure,
    /// ...), but the research-dashboard probe buttons are a SEPARATE
    /// screen that never consulted any of it — reachable via the
    /// parent-area gear regardless of canvas state. This adds only the
    /// bundle-scan-failure check specifically (not the full umbrella) —
    /// pulling in the whole thing would silently change which
    /// conditions block a probe, which is a bigger behavior change than
    /// this pass is for. (Written 2026-09-15, when a probe was a
    /// sound-off production that needed no audio checks of its own.
    /// Since P2, 2026-10-04, a probe's writing couples to the arm's sound
    /// like every other writing pass, so the arm's recording IS
    /// load-bearing here: the one audio check that matters for a probe —
    /// this letter's file for the current arm — is now made below
    /// (`probeArmAudioMissingReason`), without taking the rest of the
    /// umbrella.) Without the bundle-scan check, `kind.permits`
    /// checks the letter's NAME against a static set, not whether it
    /// actually exists in `letters`; if the bundle scan found zero
    /// letters, `permits` can still return true, this function still
    /// returns `nil` ("success"), and `loadLetter`'s own
    /// `guard let idx = letters.firstIndex(...) else { return }` no-ops
    /// silently underneath — the caller has no way to tell it didn't
    /// work. This is the same failure class as the CoreML model that
    /// never loaded and the disk writes that failed silently: the app
    /// must refuse loudly, not look like it worked. The `letters.contains`
    /// guard right below is belt-and-braces for the same failure mode
    /// under a narrower cause (this letter specifically missing, without
    /// the whole bundle scan having failed).
    @discardableResult
    func startColdProbe(letter: String, kind: StudyProbe) -> String? {
        // After a reset/restore the arms in memory are stale until relaunch
        // (review 2026-09-05). Only that block applies here: a probe writes
        // under whatever arm is current, coupling to its sound like every
        // other writing pass (P2) — whose recording is checked below.
        guard !(studyMode && participantIdentityChanged) else {
            return "Teilnehmer gewechselt — App neu starten"
        }
        guard studyMode else {
            return "Nicht im Studienmodus"
        }
        if let studyLetterSourceFailure {
            return "Keine Buchstaben aus dem Bundle geladen (\(studyLetterSourceFailure))"
        }
        // Under the `allFiveLetters` comparison switch there is no
        // untrained letter, so the post-test has no population at all —
        // `permits` below would refuse every letter for that reason, but
        // its generic message reads as a per-letter refusal and hides the
        // fact that the whole design's within-child contrast is
        // unavailable in this configuration. Say so, and say why (2026-09-17).
        //
        // Keyed on the STATE (an empty untrained set), not on the switch
        // label, so it stays true if some other configuration ever
        // trains every letter.
        if kind == .posttest, effectiveTrainedSubset.untrainedLetters.isEmpty {
            return "Kein Post-Test in dieser Sitzung: das Kind hat alle fünf Buchstaben geübt — es gibt keinen ungeübten Buchstaben. Der Vergleich geübt/ungeübt entfällt damit, und die Sitzung ist ein Vergleichslauf, kein Pilotenlauf."
        }
        guard kind.permits(letter: letter,
                           untrained: effectiveTrainedSubset.untrainedLetters,
                           studyLetters: studyBaseLetters) else {
            return "Buchstabe für diesen Test nicht zulässig"
        }
        guard let asset = letters.first(where: { $0.name == letter }) else {
            return "Buchstabe „\(letter)“ nicht im Bundle geladen"
        }
        // P2 (2026-10-04): the probe's writing must SOUND in the sound
        // arms. A probe whose arm recording is missing would otherwise
        // run, record an outcome row, and look valid — produced in
        // silence, in an arm whose condition is sound. Refused instead,
        // by the same rule the session precondition applies to training
        // letters (C1-6: a fault, not a quiet skip).
        if let reason = probeArmAudioMissingReason(for: asset) {
            return reason
        }
        pendingProbeOverride = kind
        loadLetter(name: letter)
        return nil
    }

    /// Why a cold probe of `letter` cannot run in the CURRENT arm because
    /// that arm's sound for it is missing — or nil when it can (P2,
    /// 2026-10-04). Mirrors `studyPreconditionFailure`'s audio half for
    /// training letters, applied to the one letter the probe opens:
    /// phoneme needs this letter's phoneme take (the file
    /// `activeAudioFiles` would play — empty when missing, since study mode
    /// fails closed rather than falling back to name audio); spatial needs
    /// the shared carrier in the bundle; silent needs nothing.
    func probeArmAudioMissingReason(for letter: LetterAsset) -> String? {
        switch audioCondition {
        case .silent:
            return nil
        case .spatial:
            return SpatialSonification.carrierToneURL() == nil
                ? "Test kann nicht starten: Raumklang-Arm ohne Trägerton (\(SpatialSonification.carrierToneFile)). Das Kind würde ohne den Ton seines Arms schreiben."
                : nil
        case .phoneme:
            return activeAudioFiles(for: letter).isEmpty
                ? "Test kann nicht starten: keine Phonem-Aufnahme für „\(letter.name)“. Das Kind würde ohne den Ton seines Arms schreiben."
                : nil
        }
    }

    /// Whether the filled reference glyph is drawn on the canvas. Study
    /// freeWrite — training pass or cold probe — writes the letter FROM
    /// MEMORY (thesis Ch.3, Ch.6, Abstract): until 2026-09-04 the filled
    /// font outline stayed on screen in every phase, so the "from memory"
    /// outcome was copying over a visible model. Outside the study the
    /// casual app keeps its outline.
    /// The progress bar and pill grow with checkpoint coverage on every
    /// touch, in every phase. In study freeWrite that is a per-child,
    /// performance-contingent signal on the outcome trial — hidden, like
    /// the glyph and the numeric readout (audit 2026-09-04).
    var showsProgressFeedback: Bool {
        !(studyMode && learningPhase == .freeWrite)
    }

    var showsReferenceGlyph: Bool {
        !(studyMode && learningPhase == .freeWrite)
    }

    var allLetterNames: [String] { letters.map(\.name) }

    func nextLetter() {
        letterPasses = 1
        let visible = visibleLetterNames
        guard !visible.isEmpty else { return }
        // The child's set is FINISHED and the proctor has been told so
        // (2026-10-02). Without this the wrap-around `(idx + 1) % count`
        // silently sends the child back to the first letter, so a proctor
        // who looks away for ten seconds comes back to a child who has
        // been silently given a second pass — a second set of rows under
        // the same participantId. A study session ends when its set ends;
        // the only thing that starts another is "Nächstes Kind".
        guard !awaitingNextParticipant else { return }
        let currentIdx = visible.firstIndex(of: currentLetterName) ?? -1
        let nextName = visible[(currentIdx + 1) % visible.count]
        guard let idx = letters.firstIndex(where: { $0.name == nextName }) else { return }
        letterIndex = idx
        load(letter: letters[idx])
        toast("Buchstabe: \(currentLetterName)")
    }

    func previousLetter() {
        letterPasses = 1
        let visible = visibleLetterNames
        guard !visible.isEmpty else { return }
        let currentIdx = visible.firstIndex(of: currentLetterName) ?? 0
        let prevName = visible[(currentIdx - 1 + visible.count) % visible.count]
        guard let idx = letters.firstIndex(where: { $0.name == prevName }) else { return }
        letterIndex = idx
        load(letter: letters[idx])
        toast("Buchstabe: \(currentLetterName)")
    }

    /// Restart the CURRENT letter from observe when the comparison switch
    /// asks for more than one pass per letter — the supervisor's
    /// "Buchstabe dreimal?". Returns true when it restarted, so the caller
    /// can skip what it would otherwise do next.
    ///
    /// Advancement BETWEEN letters stays a proctor action
    /// (06-evaluation.typ:15); this only repeats the letter the proctor is
    /// already on, and only while the switch is on. At the default of 1 it
    /// returns false immediately and nothing changes.
    ///
    /// Safe against the abandonment-row path: `load(letter:)` calls
    /// `recordUnloadOfCurrentLetter` for the OUTGOING letter first, and
    /// that returns early when `phaseController.isLetterSessionComplete`
    /// (PhaseTransitionCoordinator:194) — which it is, the letter having
    /// just completed. So a repeat cannot manufacture a `completed: false`
    /// row for a letter that in fact finished.
    @discardableResult
    func repeatCurrentLetterIfConfigured() -> Bool {
        guard letterRepeatCount > 1, letterPasses < letterRepeatCount,
              letters.indices.contains(letterIndex) else { return false }
        letterPasses += 1
        resetLetter()
        load(letter: letters[letterIndex])
        toast("Buchstabe \(currentLetterName) — \(letterPasses). von \(letterRepeatCount)")
        return true
    }

    /// Demo word list — Austrian Volksschule 1. Klasse Woche-1
    /// tracing words, ordered shortest → longest. Every word
    /// composes from letters in the demo bundle.
    static let demoWordList: [String] = [
        "OMA", "OMI", "OPA", "MAMA", "PAPA", "LAMA", "KILO", "FILM"
    ]

    func randomLetter() {
        letterPasses = 1
        let visible = visibleLetterNames
        guard !visible.isEmpty else { return }
        let randomName = visible[Int.random(in: 0..<visible.count)]
        guard let idx = letters.firstIndex(where: { $0.name == randomName }) else { return }
        letterIndex = idx
        load(letter: letters[idx])
        randomAudioVariant()
        toast("Zufall: \(currentLetterName)")
    }

    func nextAudioVariant() {
        // Study sessions: the two-finger canvas swipe that cycles takes
        // would (a) autoplay the arm's sound in any phase, freeWrite and
        // post-test included — a child-triggered preview outside the
        // protocol, layered over the writing passes' own coupling (the
        // sound-off gate this used to cite was lifted 2026-10-02, #27),
        // and (b) let the child pick which take plays, unrecorded. Every
        // study load resets `audioIndex` to 0, so the realised file is a
        // deterministic function of (letter, arm, bundle). Gated
        // 2026-09-04, same reasoning as `replayAudio`.
        guard !studyMode else { return }
        guard !letters.isEmpty else { return }
        let files = activeAudioFiles(for: letters[letterIndex])
        guard !files.isEmpty else { return }
        guard files.indices.contains(audioIndex) else { audioIndex = 0; return }
        audioIndex = (audioIndex + 1) % files.count
        // Autoplay so the long-press UI gesture both switches and previews
        // in one step — no "silent swap" that requires a second tap to hear.
        audio.loadAudioFile(named: files[audioIndex], autoplay: true)
        toast("Ton \(audioIndex + 1) von \(files.count): \(soundLabel(for: files[audioIndex]))")
    }

    func previousAudioVariant() {
        // See `nextAudioVariant`.
        guard !studyMode else { return }
        guard !letters.isEmpty else { return }
        let files = activeAudioFiles(for: letters[letterIndex])
        guard !files.isEmpty else { return }
        guard files.indices.contains(audioIndex) else { audioIndex = 0; return }
        audioIndex = (audioIndex - 1 + files.count) % files.count
        audio.loadAudioFile(named: files[audioIndex], autoplay: true)
        toast("Ton \(audioIndex + 1) von \(files.count): \(soundLabel(for: files[audioIndex]))")
    }

    /// Human-friendly label — strips the letter prefix and `.mp3` so
    /// toasts read "Ton 4 von 5: Affe" instead of raw filenames.
    private func soundLabel(for file: String) -> String {
        var label = (file as NSString).deletingPathExtension
        if label.hasPrefix(currentLetterName), label.count > currentLetterName.count {
            label.removeFirst(currentLetterName.count)
        }
        return label.isEmpty ? file : label
    }

    // MARK: - Touch handling (forwarded to TouchDispatcher)

    func beginTouch(at p: CGPoint, t: CFTimeInterval) {
        touchDispatcher.beginTouch(at: p, t: t)
    }

    func updateTouch(at p: CGPoint, t: CFTimeInterval, canvasSize: CGSize) {
        touchDispatcher.updateTouch(at: p, t: t, canvasSize: canvasSize)
    }

    /// Test-only dispatcher state inspection.
    var debugSmoothedVelocity: CGFloat { touchDispatcher.smoothedVelocity }
    var debugIsSingleTouchInteractionActive: Bool { touchDispatcher.isSingleTouchInteractionActive }

    // MARK: - Lifecycle

    public func appDidEnterBackground() async {
        guard playback.appIsForeground else { return }
        playback.appIsForeground = false
        playback.cancelPending()
        // Study mode: a freeWrite production that is finished (pen up)
        // but not yet scored — quiet window pending, or recognizer in
        // flight — is scored and recorded now, before the stores drain
        // below. The trial most at risk is the last one of a session:
        // the proctor closes the app right after the child lifts the
        // pen, and the async completion never ran. `endTouch()` ends a
        // gesture that was still down, so that production is finished
        // too — it is recorded here as well, because the quiet-window
        // task it schedules may never run in a suspended app
        // (audit 2026-09-04).
        endTouch()
        phaseTransitions.finalizeFinishedFreeWriteIfPending()
        // Stop the active-time timer so backgrounded time isn't
        // counted; the accumulator survives the round-trip.
        if let start = letterLoadTime {
            letterActiveTimeAccumulated += CACurrentMediaTime() - start
            letterLoadTime = nil
        }
        let cmd = playback.transition(to: .idle)
        playback.apply(cmd)
        if cmd == .none { audio.stop(); isPlaying = false }
        audio.suspendForLifecycle()
        // Halt in-flight TTS so the voice doesn't keep talking.
        speech.stop()
        playback.resetPlayIntentClock()
        // Drain disk writes synchronously: iOS's suspension grace
        // window otherwise raced the prior fire-and-forget Tasks and
        // could lose a letter completion seconds before backgrounding.
        await progressStore.flush()
        await streakStore.flush()
        await dashboardStore.flush()
        // The raw trace and the PhaseSessionRecord that links to it live
        // in two separate stores. Draining the record without the trace
        // leaves exactly the dangling `rawTraceID` that the
        // capture-before-record ordering in `PhaseTransitionCoordinator`
        // exists to prevent — and the trial at risk is the last one of a
        // session, because that is when the proctor closes the app.
        await rawTraceStore.flush()
        await onboardingStore.flush()
        await enrolmentLog.flush()
    }

    public func appDidBecomeActive() {
        playback.appIsForeground = true
        audio.resumeAfterLifecycle()
        // Restart the active-time live slice for this foreground
        // window; the pre-background slice is in the accumulator.
        if letterLoadTime == nil, !didCompleteCurrentLetter, !launchParked {
            letterLoadTime = CACurrentMediaTime()
        }
        if playback.resumeIntent {
            playback.request(playback.state, immediate: true)
        }
        // Refresh daily reminder with current streak
        if isOnboardingComplete {
            notificationScheduler.scheduleDailyReminder(
                currentStreak: streakStore.currentStreak,
                onboardingComplete: true
            )
        }
    }

    func endTouch(fromPencil: Bool? = nil) {
        touchDispatcher.endTouch(fromPencil: fromPencil)
    }

    // MARK: - Animation guide

    func startGuideAnimation() {
        // Use rawGlyphStrokes so the dot follows the CURRENT script;
        // `letters[..].strokes` would play a Druckschrift path over a
        // Playwrite glyph in Schreibschrift mode.
        guard !letters.isEmpty, letterIndex < letters.count,
              let rawStrokes = rawGlyphStrokes,
              !rawStrokes.strokes.isEmpty else { return }
        armObserveAutoAdvance()
        animation.start(strokes: rawStrokes)
        startObservePhaseAudio(startingAt: rawStrokes.strokes.first?.checkpoints.first.map {
            CGPoint(x: $0.x, y: $0.y)
        })
        startAudioSignalTicker()
    }

    /// Test-only: report measured output level DURING the phase, not only
    /// at the boundary it eventually reaches. A no-op unless the probe was
    /// launch-armed, so the pilot artefact never runs the timer.
    ///
    /// WHY THIS IS ONE HELPER CALLED FROM EVERY LANDING SITE, and not an
    /// inline call sprinkled at the sites that remembered. It has been
    /// wrong twice, in opposite directions, and both times the symptom was
    /// the instrument reporting nothing:
    ///
    ///   - It hung off `startGuideAnimation` alone, which is reached only
    ///     when ADVANCING into observe. A session's FIRST letter goes
    ///     through `load(letter:)`'s own observe branch and produced an
    ///     empty log for exactly the session a proctor runs first.
    ///   - Then it was added to the observe branch of `load(letter:)`
    ///     only. MEASURED 2026-10-03: a session that lands DIRECTLY in
    ///     `freeWrite` — the H6 post-test pretest, which deliberately
    ///     skips every earlier phase — reached its landing branch at
    ///     `:3129` and started nothing, so the probe logged **zero
    ///     freeWrite samples**. The phase was not silent; it was
    ///     unmeasured, and the two are indistinguishable from the log.
    ///
    /// The landing branches are mutually exclusive, and the ticker is
    /// idempotent (`AudioEngine.startAudioSignalTicker` stops any existing
    /// timer first), so calling it from each is safe and a future phase
    /// added to the ladder cannot silently go dark.
    private func startAudioSignalTicker() {
        audioSignalProbeSink.startAudioSignalTicker(intervalSeconds: 2.0) {
            [weak self] in self?.phaseController.currentPhase.rawName ?? "unknown"
        }
    }

    /// The arm's sound under the WHOLE demonstration, not a 2 s sample
    /// (2026-10-02, proctor's device run: "I want it to play when the
    /// letter is being shown how to draw it the whole time").
    ///
    /// Before this, a study child's sound reached them through the trace
    /// coupling alone while drawing — so the observe phase, the one moment
    /// the letter is actually being SHOWN, was the one phase with nothing
    /// to hear. The engine loops the loaded file, so one autoplay covers
    /// the animation's full duration and stops when the phase advances
    /// (`resetForPhaseTransition` -> `audio.stop()`, which already fades
    /// out over `fadeOutSeconds`).
    ///
    /// Plays through a fade-IN so the demonstration does not open with a
    /// click. Silent arm: `activeAudioFiles` returns [], so this is a no-op
    /// — the arm stays silent without a second check here.
    ///
    /// WIRED 2026-10-04. Until then its only caller was
    /// `startGuideAnimation`, reached only when `advance()` lands on
    /// observe — which it never does, observe being the first active
    /// phase — so production never called it. The study path now starts
    /// it from `load(letter:)`, after the file reload AND the observe
    /// cue gap (`claimWholeObserveSound`, `armObservePresentationAfterCue`).
    ///
    /// TRACKED, not steady (David, 2026-10-05: "When the letter drawing is
    /// shown the audio is not tracked like it is when I draw the letter
    /// myself" — reversing D9's steady-carrier ruling of 2026-09-18). The
    /// sound starts with the coupling parameters of the dot's FIRST point,
    /// still (slowest rate), through `ArmCoupling` — the same mapping the
    /// pen uses — and `handleGuideFrame` then tracks the dot frame by frame.
    /// Starting from the dot also replaces whatever rate/pan/pitch the
    /// PREVIOUS letter's tracing left the engine in.
    private func startObservePhaseAudio(startingAt firstPoint: CGPoint?) {
        guard letters.indices.contains(letterIndex) else { return }
        guard let first = activeAudioFiles(for: letters[letterIndex]).first else { return }
        let p = firstPoint.map(canvasNormalizedPoint(forCellPoint:)) ?? CGPoint(x: 0.5, y: 0.5)
        ArmCoupling.apply(
            ArmCoupling.parameters(canvasNormalized: p, velocity: 0,
                                   panningEnabled: panningEnabled, arm: audioCondition),
            to: audio)
        audio.loadAudioFile(named: first, autoplay: false)
        audio.play(fadeInSeconds: observeAudioFadeInSeconds)
        observeSoundTracksDot = true
    }

    /// Whether the observe sound is playing and should follow the dot.
    /// Set when `startObservePhaseAudio` starts it; cleared on every load
    /// and phase transition.
    private var observeSoundTracksDot = false

    /// The dot's cell-normalised point → canvas-normalised (pan/pitch
    /// space). In a study session the one cell IS the canvas, so this is
    /// the identity there; the general form keeps pan honest elsewhere.
    private func canvasNormalizedPoint(forCellPoint p: CGPoint) -> CGPoint {
        let cell = grid.activeCell.frame
        guard cell.width > 0, cell.height > 0,
              canvasSize.width > 0, canvasSize.height > 0 else { return p }
        return CGPoint(x: (cell.minX + p.x * cell.width) / canvasSize.width,
                       y: (cell.minY + p.y * cell.height) / canvasSize.height)
    }

    /// The observe sound tracks the animated dot exactly as it tracks the
    /// child's pen (2026-10-05), through the ONE shared mapping
    /// (`ArmCoupling`): rate from the dot's velocity in pt/s, pan from x,
    /// pitch from y in the spatial arm only. A still dot (the 1.0 s start
    /// hold, a stroke's dwell, the pause after the pass) plays on at the
    /// slowest rate (velocity 0 → 0.5) — no pause. A stroke-to-stroke jump
    /// is a pen lift, not motion: it never enters the velocity.
    func handleGuideFrame(_ frame: AnimationGuideController.Frame) {
        guard observeSoundTracksDot, studyMode,
              phaseController.currentPhase == .observe,
              audioCondition != .silent else { return }
        let point: CGPoint
        let velocity: CGFloat
        switch frame {
        case .still(let p):
            point = p
            velocity = 0
        case .move(let from, let to, let seconds):
            let cell = grid.activeCell.frame
            let w = cell.width > 0 ? cell.width : canvasSize.width
            let h = cell.height > 0 ? cell.height : canvasSize.height
            let distance = hypot((to.x - from.x) * w, (to.y - from.y) * h)
            point = to
            velocity = seconds > 0 ? distance / CGFloat(seconds) : 0
        case .jump:
            return
        }
        ArmCoupling.apply(
            ArmCoupling.parameters(canvasNormalized: canvasNormalizedPoint(forCellPoint: point),
                                   velocity: velocity,
                                   panningEnabled: panningEnabled, arm: audioCondition),
            to: audio)
    }

    /// Whether this study observe phase gets the sound arm's sound for the
    /// whole animation (P4, David 2026-10-04) — and, if so, records that
    /// the condition's demonstration was delivered, exactly as
    /// `armPreTaskDemonstration` does when it arms one.
    ///
    /// No for: casual sessions; the silent arm (its condition is the
    /// absence of sound; it keeps the unchanged animation); the spatial arm
    /// with the researcher-only axis-sweep switch ON (that switch asks for
    /// the OLD scripted sweep, which `armPreTaskDemonstration` still
    /// delivers); and a condition already demonstrated under the
    /// "Einmal pro Kondition" comparison switch, which keeps its meaning.
    ///
    /// A phoneme letter with no phoneme file is a fault, not a quiet skip
    /// (C1-6), and does not consume the condition's demonstration.
    private func claimWholeObserveSound(for letter: LetterAsset) -> Bool {
        guard studyMode, audioCondition != .silent else { return false }
        if audioCondition == .spatial && axisDemonstrationEnabled { return false }
        if demonstrationsOncePerCondition,
           demonstratedAudioConditions.contains(audioCondition) {
            return false
        }
        guard activeAudioFiles(for: letter).first != nil else {
            pilotAudioLogger.fault("Whole-observe sound SKIPPED: no audio file for \(letter.name, privacy: .public) in the \(self.audioCondition.rawValue, privacy: .public) arm — the session should have been refused.")
            return false
        }
        // A pending demonstration from an earlier load must not stop this
        // sound at its 2 s mark.
        cancelPreTaskDemonstration()
        demonstratedAudioConditions.insert(audioCondition)
        return true
    }

    /// Cancel a pending study observe presentation. Called on every fresh
    /// letter load (a new load re-derives everything the start would
    /// assume — its phase, its letter, its arm).
    private func cancelPendingObservePresentation() {
        observePresentationTask?.cancel()
        observePresentationTask = nil
        observeCueEndTask?.cancel()
        observeCueEndTask = nil
        pendingObserveSoundArm = nil
        pendingObservePresentation = nil
        observeSoundTracksDot = false
    }

    /// P4 (supervisor rulings 2026-10-05, Option B and the cue-gap fix): in
    /// a study session the observe instruction ("Schau genau hin.") is
    /// spoken FIRST; then the guide animation and — in a sound arm — the
    /// arm's dot-tracked sound start TOGETHER, in the same main-actor turn.
    ///
    /// WHEN. `observeCueEndToPresentationSeconds` (1.0 s) after the cue
    /// utterance ENDS, reported by the speech seam
    /// (`cueUtteranceEnded`), or `observeCueFallbackSeconds` (3.0 s) after
    /// the cue STARTED, whichever comes first; same in all three arms
    /// (ruling 2026-10-05, protocol r5; replaces the fixed 2.0 s from the
    /// cue's start of #39). Before Option B the animation
    /// started at 0.3 s and only the sound waited, so every animation ran
    /// ~1.7 s with no sound (device run R01).
    ///
    /// Every arm gets the same timing; the silent arm (and any arm whose
    /// sound is not claimed) starts the animation alone. Nothing skips the
    /// sound for timing: the animation cannot have finished before it
    /// started. The phase guard only stands down for a phase the PROCTOR
    /// left. The sound ends with the phase: `resetForPhaseTransition` stops
    /// the engine. The strokes are read when the start FIRES, so a canvas
    /// laid out during the wait is honoured.
    private func armObservePresentationAfterCue(letter: LetterAsset, soundArm: PilotAudioCondition?) {
        observePresentationTask?.cancel()
        observeCueEndTask?.cancel()
        observeCueEndTask = nil
        pendingObserveSoundArm = soundArm
        observePresentationGeneration &+= 1
        let generation = observePresentationGeneration
        pendingObservePresentation = (generation: generation, letter: letter)
        let fallback = observeCueFallback + presentationSpacing
        observePresentationTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            try? await Task.sleep(for: .seconds(fallback))
            guard !Task.isCancelled else { return }
            self.startPendingObservePresentation(generation: generation)
        }
    }

    /// Start the pending presentation for `generation`, once: the first of
    /// the cue-end path and the fallback wins; a stale generation (a newer
    /// load) is ignored.
    private func startPendingObservePresentation(generation: Int) {
        guard let pending = pendingObservePresentation, pending.generation == generation else { return }
        pendingObservePresentation = nil
        observePresentationTask?.cancel()
        observePresentationTask = nil
        observeCueEndTask?.cancel()
        observeCueEndTask = nil
        guard phaseController.currentPhase == .observe else { return }
        let strokes = rawGlyphStrokes ?? pending.letter.strokes
        guard !strokes.strokes.isEmpty else { return }
        animation.start(strokes: strokes)
        if let arm = pendingObserveSoundArm, arm == audioCondition {
            startObservePhaseAudio(startingAt: strokes.strokes.first?.checkpoints.first.map {
                CGPoint(x: $0.x, y: $0.y)
            })
        }
        pendingObserveSoundArm = nil
    }

    /// The speech seam's end-of-utterance report (`setUtteranceEndHandler`,
    /// registered at init). Only the OBSERVE CUE counts, and only the cue
    /// of the CURRENT load: `pendingObserveCues` counts cues queued by
    /// loads and not yet ended, so an older load's cue ending after a new
    /// load (the synthesiser queues FIFO) leaves the count above zero and
    /// is ignored. Any other utterance is ignored by its text. A cancelled
    /// cue is counted down but starts nothing — the fallback covers it.
    private func cueUtteranceEnded(text: String, cancelled: Bool) {
        guard text == ChildSpeechLibrary.phaseEntry(.observe) else { return }
        pendingObserveCues = max(0, pendingObserveCues - 1)
        guard pendingObserveCues == 0, !cancelled,
              let pending = pendingObservePresentation else { return }
        let generation = pending.generation
        let delay = observeCueEndToPresentation + presentationSpacing
        observeCueEndTask?.cancel()
        observeCueEndTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self.startPendingObservePresentation(generation: generation)
        }
    }

    /// The pending presentation (generation + letter), nil once started.
    private var pendingObservePresentation: (generation: Int, letter: LetterAsset)?
    private var observePresentationGeneration = 0
    /// In-flight cue-end start (1.0 s after the cue ends).
    private var observeCueEndTask: Task<Void, Never>?
    /// Observe cues spoken by loads and not yet reported ended.
    private var pendingObserveCues = 0

    /// Seconds after the observe cue ENDS / after it STARTS (fallback) —
    /// copied from `TracingDependencies` at init.
    private let observeCueEndToPresentation: TimeInterval
    private let observeCueFallback: TimeInterval

    /// Short enough to be inaudible as a delay, long enough to remove the
    /// click. Matches the fade-out's order of magnitude.
    private let observeAudioFadeInSeconds: TimeInterval = 0.12

    /// Auto-advance the observe phase after the second cycle so
    /// non-reading children aren't stuck waiting on "Tippen". Installed
    /// on EVERY observe entry: `load(letter:)` used to drive the animator
    /// without it, so the very first letter of a session could only leave
    /// observe by the tap — which studyMode makes inert — and the counter
    /// kept counting guided-phase loops, so later letters left observe
    /// after ONE cycle (audit 2026-09-04, class one/two).
    private func armObserveAutoAdvance() {
        observeCycleCount = 0
        animation.onCycleComplete = { [weak self] in
            guard let self else { return }
            self.observeCycleCount += 1
            // ONE pass, not two (2026-09-17). The supervisor's note was
            // "einmal vorzeigen (vielleicht etwas langsamer)" — show it
            // once, a bit slower — so the single pass now runs at
            // `AnimationSpeed.slow` (see
            // `AnimationGuideController.observeUnitsPerSecond`), which
            // keeps the observe window roughly its former length while
            // showing the letter one time instead of twice.
            //
            // The counter and its reset stay: `onCycleComplete` is
            // re-armed on every observe entry, and the guided phase no
            // longer drives the animator at all, so this counter can
            // only ever count observe cycles.
            if self.observeCycleCount >= self.observePasses,
               self.phaseController.currentPhase == .observe {
                self.completeObservePhase()
            }
        }
    }

    func stopGuideAnimation() {
        animation.stop()
    }

    // MARK: - Onboarding control

    /// Advance one onboarding step.
    func advanceOnboarding() {
        guard onboardingCoordinator.advance() else { return }
        onboardingStep = onboardingCoordinator.currentStep
        if onboardingCoordinator.isComplete {
            // Record the first-completion variant only; re-runs leave
            // the historical record alone.
            onboardingStore.markComplete(variant: onboardingVariant)
            isOnboardingComplete = true
            speakInitialPhaseCueAfterOnboarding()
            // Request notification permission + schedule daily reminder.
            Task { [weak self] in
                guard let self else { return }
                _ = await self.notificationScheduler.requestPermission()
                self.notificationScheduler.scheduleDailyReminder(
                    currentStreak: self.streakStore.currentStreak,
                    onboardingComplete: true
                )
            }
        } else {
            onboardingStore.saveProgress(step: onboardingCoordinator.currentStep)
        }
    }

    /// Skip all onboarding steps immediately.
    func skipOnboarding() {
        onboardingCoordinator.skip()
        onboardingStep = onboardingCoordinator.currentStep
        onboardingStore.markComplete(variant: onboardingVariant)
        isOnboardingComplete = true
        speakInitialPhaseCueAfterOnboarding()
    }

    /// Play the phase-entry prompt right after onboarding finishes —
    /// the cue at the end of `load(letter:)` is gated on
    /// isOnboardingComplete and skipped during init, so refire here.
    private func speakInitialPhaseCueAfterOnboarding() {
        prompts.play(
            ChildSpeechLibrary.phaseEntryPromptKey(phaseController.currentPhase),
            fallbackText: ChildSpeechLibrary.phaseEntry(phaseController.currentPhase)
        )
    }

    /// Reset onboarding so it replays. Re-reads the parent variant
    /// preference; the historical `variantUsed` is preserved.
    func restartOnboarding() {
        // Read the recorded A/B variant BEFORE the reset wipes it — the
        // guard in `markComplete` ("record only on the first complete")
        // was defeated by the one path it exists for (audit 2026-09-04).
        let recordedVariant = onboardingStore.variantUsed
        onboardingStore.reset()
        // The recorded assignment is the install's ORIGINAL variant and is
        // kept across the reset; the flow shown on a parent re-run follows
        // the parent's toggle (review 2026-09-05).
        if let recordedVariant { onboardingStore.recordVariant(recordedVariant) }
        let useShort = UserDefaults.standard.bool(forKey: "de.flamingistan.primae.useShortOnboarding")
        onboardingVariant = useShort ? .short : .full
        onboardingCoordinator = OnboardingCoordinator(steps: onboardingVariant.steps)
        onboardingStep = onboardingCoordinator.currentStep
        isOnboardingComplete = false
    }

    // MARK: - Learning phase control

    /// Forwards to PhaseTransitionCoordinator.
    func advanceLearningPhase() {
        phaseTransitions.advance()
    }

    /// Run the recognizer on the freeWrite buffer. Result drives
    /// celebration vs retry routing in the coordinator.
    func runRecognizerForFreeWrite(score: CGFloat) {
        let pts = freeWritePoints
        let breaks = freeWriteRecorder.strokeStartIndices
        let size = canvasSize
        let expected = currentLetterName
        // FreeformController owns the spinner flag — only one
        // recognition is ever in flight.
        freeform.isRecognizing = true
        // Form-accuracy history feeds the calibrator's practised-letter
        // boost; empty on first encounter (skipped path). NOT
        // `recognitionAccuracy` — that is the recognizer's own past
        // CONFIDENCE, a different instrument from "has this child
        // historically formed this letter well" (2026-09-04 fix; see
        // `ProgressStoring.recordCompletion` and `formAccuracyHistory`).
        let history = (progressStore.progress(for: expected)
                       .formAccuracyHistory ?? [])
                      .map { CGFloat($0) }
        let token = recognitionTokens.issue()
        Task { [weak self, letterRecognizer] in
            let result = await letterRecognizer.recognize(
                points: pts, strokeStartIndices: breaks,
                canvasSize: size, expectedLetter: expected,
                historicalFormScores: history)
            guard let self else { return }
            await MainActor.run {
                guard self.recognitionTokens.isStillActive(token) else { return }
                self.freeform.isRecognizing = false
                self.lastRecognitionResult = result
                if let r = result {
                    self.progressStore.recordRecognitionSample(
                        letter: expected, result: r)
                    self.refreshProgressMirror()
                }
                self.phaseTransitions.completePostFreeWriteRecognition(
                    score: score, result: result)
            }
        }
    }

    /// Drop any in-flight recognizer completion so it cannot land after
    /// the trial has been recorded by another route. Used by the
    /// study-mode unload / background path
    /// (`PhaseTransitionCoordinator.finalizeFinishedFreeWriteIfPending`).
    func abortInFlightRecognition() {
        recognitionTokens.cancel()
        freeform.isRecognizing = false
    }

    /// Record the paper-transfer self-assessment and advance the queue.
    func submitPaperTransfer(score: Double) {
        progressStore.recordPaperTransferScore(for: currentLetterName, score: score)
        refreshProgressMirror()
        overlayQueue.dismiss()
    }

    /// Tap-to-continue completion of the observe phase.
    func completeObservePhase() {
        guard phaseController.currentPhase == .observe else { return }
        stopGuideAnimation()
        // The demonstration is layered over the observe window and must
        // not outlive it (for the study letters two cycles take 5–11 s and
        // the demonstration 2.0 s, so this is a guard, not a live case).
        cancelPreTaskDemonstration()
        advanceLearningPhase()
    }

    /// Direct-phase dot tap. Correct order: confirmation audio +
    /// arrow, advances. Wrong order: gentle haptic, pulse the
    /// correct dot.
    func tapDirectDot(index: Int) {
        guard phaseController.currentPhase == .direct else { return }
        guard let rawStrokes = rawGlyphStrokes else { return }
        let total = rawStrokes.strokes.count
        guard index < total, !directTappedDots.contains(index) else { return }

        if index == directNextExpectedDotIndex {
            // The DirectPhaseDotsOverlay tap handler wraps this in
            // `withAnimation`; the curve lives at the call site so
            // the VM doesn't import SwiftUI.
            directTappedDots.insert(index)
            haptics.fire(.checkpointHit)
            // Per-tap chime: distinct confirmation per dot. Letter
            // audio plays only on first tap; replaying it per dot
            // was perceived as noisy duplication of the observe demo.
            prompts.playTapChime()
            // Brief directional arrow along the stroke path.
            directArrowStrokeIndex = index
            // Defer the final-dot phase advance until the arrow has
            // finished rendering so the last stroke gets its cue too.
            let isLastTap = directTappedDots.count >= total
            Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: .seconds(1.2))
                if self.directArrowStrokeIndex == index {
                    self.directArrowStrokeIndex = nil
                }
                if isLastTap, self.phaseController.currentPhase == .direct {
                    self.haptics.fire(.letterCompleted)
                    self.advanceLearningPhase()
                }
            }
        } else {
            // Wrong dot — gentle haptic + lower-pitched buzz that
            // bypasses the mute switch (same path as the correct
            // chime) so the child hears the contrast.
            haptics.fire(.offPath)
            prompts.playWrongTapChime()
            directPulsingDot = true
            directPulsingTask?.cancel()
            directPulsingTask = Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: .milliseconds(700))
                self.directPulsingDot = false
                self.directPulsingTask = nil
            }
        }
    }

    /// Apply calibrated bbox-relative checkpoints (the JSON shape).
    /// Maps through the live cell's glyph rect into cell-fraction
    /// before loading the tracker so proximity hit-tests share frame
    /// with the renderer's ghost path.
    func applyCalibration(_ strokes: [[CGPoint]]) {
        let defs = strokes.enumerated().map { (i, pts) in
            StrokeDefinition(id: i + 1, checkpoints: pts.map { cp in
                Checkpoint(x: cp.x, y: cp.y)
            })
        }
        // The letter's own radius, not a constant: the corpus carries 0.1
        // and 0.05, and a calibration round-trip must not rewrite the
        // scored tolerance (audit 2026-09-04).
        let authoredRadius = letters.indices.contains(letterIndex)
            ? letters[letterIndex].strokes.checkpointRadius : 0.05
        let bboxStrokes = LetterStrokes(letter: currentLetterName, checkpointRadius: authoredRadius, strokes: defs)
        let cellSize = grid.activeCell.frame.size
        guard cellSize.width > 0, cellSize.height > 0,
              let gr = PrimaeLetterRenderer.normalizedGlyphRect(
                for: currentLetterName, canvasSize: cellSize,
                schriftArt: schriftArt,
                openTypeFeatures: currentGlyphFeatures) else {
            strokeTracker.load(bboxStrokes)
            return
        }
        let mapped = bboxStrokes.strokes.map { def in
            StrokeDefinition(
                id: def.id,
                checkpoints: def.checkpoints.map { cp in
                    Checkpoint(
                        x: gr.minX + cp.x * gr.width,
                        y: gr.minY + cp.y * gr.height
                    )
                }
            )
        }
        strokeTracker.load(LetterStrokes(letter: bboxStrokes.letter,
                                         checkpointRadius: bboxStrokes.checkpointRadius
                                             * sqrt(gr.width * gr.height),
                                         strokes: mapped))
    }

    /// Load the spaced-repetition-recommended letter.
    func loadRecommendedLetter() {
        // Study sessions use a fixed deterministic order, never the
        // spaced-repetition scheduler (letter order must not diverge
        // with performance). Defensive: the celebration overlay that
        // normally triggers this is itself gated off under studyMode.
        if studyMode {
            nextLetter()
            return
        }
        // Confirmation haptic on celebration "Weiter".
        haptics.fire(.letterCompleted)
        let available = visibleLetterNames
        let scored = letterScheduler.prioritized(available: available,
                                                  progress: progressStore.allProgress)
        // Reset the queue when nothing's available so the celebration
        // doesn't strand the child.
        guard let best = scored.first,
              let idx  = letters.firstIndex(where: { $0.name == best.letter }) else {
            overlayQueue.reset()
            return
        }
        // Capture priority for `schedulerEffectivenessProxy`.
        letterIndex = idx
        load(letter: letters[idx])
        // AFTER load: load(letter:) clears it so a letter reached by the
        // arrows or a probe does not carry the previous pick's priority
        // (review 2026-09-05).
        lastScheduledLetterPriority = best.priority
        toast("Empfohlen: \(currentLetterName)")
        // Slot a retrieval prompt ahead of tracing when the scheduler
        // says it's time and the letter has enough prior completions.
        if enableRetrievalPrompts {
            let prog = progressStore.progress(for: best.letter)
            if retrievalScheduler.shouldPrompt(for: best.letter, progress: prog) {
                let distractors = retrievalDistractors(for: best.letter, from: available)
                overlayQueue.enqueue(.retrievalPrompt(letter: best.letter, distractors: distractors))
            }
        }
    }

    /// Pick two distractors. Prefers motor-similarity cluster-mates
    /// (within ±5 rank) for pedagogical value; falls back to random
    /// pool members when the pool is small.
    private func retrievalDistractors(for target: String, from pool: [String]) -> [String] {
        let candidates = pool.filter { $0 != target }
        guard !candidates.isEmpty else { return [] }
        let order = LetterOrderingStrategy.motorSimilarity.orderedLetters()
        let rank: (String) -> Int = { letter in
            order.firstIndex(of: letter) ?? Int.max
        }
        let targetRank = rank(target)
        let near = candidates
            .filter { abs(rank($0) - targetRank) <= 5 }
            .shuffled()
            .prefix(2)
        if near.count == 2 { return Array(near) }
        return Array(candidates.shuffled().prefix(2))
    }

    /// Record the retrieval outcome and dismiss the overlay.
    func submitRetrievalAnswer(letter: String, correct: Bool) {
        progressStore.recordRetrievalAttempt(letter: letter, correct: correct)
        refreshProgressMirror()
        haptics.fire(correct ? .letterCompleted : .offPath)
        // 0.6 s delay so the colour-coded reveal renders before the
        // overlay dismisses.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            await MainActor.run { self?.overlayQueue.dismiss() }
        }
    }

    /// The 5-letter pilot stimulus set (uppercase-only in study
    /// sessions), read from its single owner in Core rather than
    /// re-declared. Anlaut phonemes /a/ /ɪ/ /m/ /f/ /l/ are all vowels
    /// or continuants, so every study letter is loopable (moots D6).
    private let studyBaseLetters = Set(TrainedLetterSubset.studyLetters)

    /// Non-nil when a study session MUST NOT start (ruling C3-6,
    /// 2026-09-04): a phoneme-arm study device whose bundled study
    /// letters lack phoneme recordings. Computed from the loaded letters
    /// so a device with the recordings clears it. The Schule surface
    /// replaces the canvas with this message and `beginTouch` refuses
    /// every trace while it is set — a phoneme session that measures
    /// nothing must be impossible to run by mistake, the same shape as
    /// the CoreML model that never loaded. Proctor-facing text (the
    /// child never sees a session in this state).
    var studyPreconditionFailure: String? {
        guard studyMode else { return nil }
        // A fresh study iPad is NOT enrolled until "Neuer Teilnehmer" is
        // tapped; until then all three assignment axes silently fell to
        // their defaults (phoneme, AFI, threePhase) — one arm, one subset,
        // no randomisation, stamped on every row (class two, 2026-09-05).
        // The bundle scan found no letters: without this refusal the
        // repository would have served the cache or a synthetic "A"
        // (class two, 2026-09-06). Checked first — it is the stimulus.
        if let studyLetterSourceFailure {
            return "Keine Buchstaben aus dem Bundle geladen (\(studyLetterSourceFailure)). Die Sitzung wird nicht gestartet — ein Ersatz aus dem Cache oder ein eingebauter Beispielbuchstabe wäre nicht der eingefrorene Stimulus."
        }
        if !participantEnrolled {
            // Names the RAIL first, because that is the proctor's actual
            // route (2026-10-02). This text used to name only the research
            // area, which sent the proctor through the gear, the parent
            // area and the Research tab to enrol child #1 — the very
            // seven-step detour the rail gesture (PR #22) exists to
            // remove. The screen that tells a proctor what to do is the
            // one thing they read, so it has to name the cheapest correct
            // action. Both routes are still offered: the dashboard button
            // runs the same control.
            return "Kein Teilnehmer eingeschrieben. In der Seitenleiste doppelt tippen und „Nächstes Kind“ wählen (auch im Forschungsbereich möglich), damit Arm und Buchstaben zugewiesen werden — sonst laufen alle Kinder unter denselben Voreinstellungen."
        }
        // Spatial arm: its stimulus and its demonstration are one bundled
        // carrier file; the engine merely logs when it is missing, so the
        // arm would run without its manipulation and the proctor could
        // not tell (ruling C1-6: hard requirement, like the phonemes).
        if audioCondition == .spatial {
            return SpatialSonification.carrierToneURL() == nil
                ? "Spatial-Arm ohne Trägerton (\(SpatialSonification.carrierToneFile)). Die Sitzung wird nicht gestartet — weder Tracing-Ton noch Demonstration könnten spielen."
                : nil
        }
        guard audioCondition == .phoneme else { return nil }
        let missing = letters
            .filter { studyBaseLetters.contains($0.baseLetter) && $0.letterCase == .upper
                      && $0.phonemeAudioFiles.isEmpty }
            .map(\.name)
            .sorted()
        guard !missing.isEmpty else { return nil }
        return "Phonem-Arm ohne Phonem-Aufnahmen für: \(missing.joined(separator: ", ")). "
            + "Die Sitzung wird nicht gestartet — es würde ein falscher oder gar kein Laut gespielt. "
            + "Aufnahmen als <Buchstabe>_phoneme<n>.<Format> in Resources/Letters/<Buchstabe>/ "
            + "ablegen (Format: mp3, wav, m4a, aac, flac oder ogg; H5)."
    }

    /// The letters this SESSION actually trains — which is what every
    /// consumer that reasons about trained-vs-untrained must read, and
    /// what every exported row must be stamped with.
    ///
    /// Normally the assignment axis's subset (`trainedSubset`, from UUID
    /// byte 9 / the researcher override). Under the `allFiveLetters`
    /// comparison switch it is `.allFive` instead: the session practises
    /// all five, so "trained" is all five and `untrainedLetters` is
    /// EMPTY.
    ///
    /// WHY THIS EXISTS (2026-09-17). The switch used to widen the
    /// practice pool and nothing else, so three readers kept answering
    /// from the 3-subset assignment while the child trained five:
    ///   - `PhaseTransitionCoordinator` stamped `trainedSubset.rawValue`
    ///     on every exported row (both `:226` and `:433`), so the row
    ///     asserted the child was untrained on two letters the child had
    ///     just practised;
    ///   - `startColdProbe` gated the post-test on
    ///     `trainedSubset.untrainedLetters`, so those two trained letters
    ///     were offered and ACCEPTED as the "untrained" probe;
    ///   - `ParentDashboardExporter.derivedTrainedPostTestIndices`
    ///     re-derived "was this letter trained" from the same column, so
    ///     the post-test tag was withheld from the letters that had in
    ///     fact been trained.
    /// Every analysis that partitions trained from untrained from the
    /// export would have been wrong for those rows, and the contrast the
    /// design rests on was fabricated by the bookkeeping rather than
    /// measured. One owner for the question, so the three cannot
    /// disagree again.
    ///
    /// With the switch OFF this is `trainedSubset` itself, so every
    /// stamped value, gate and pool is byte-identical to the behaviour
    /// before this property existed.
    var effectiveTrainedSubset: TrainedLetterSubset {
        allFiveLetters ? .allFive : trainedSubset
    }

    /// Visible letters, sorted by `letterOrdering`. `studyMode` pins the
    /// pool to the 5-letter UPPERCASE pilot stimulus set regardless of
    /// `showAllLetters`; outside study sessions the app stays
    /// full-alphabet (`showAllLetters` defaults true and is not flipped).
    var visibleLetterNames: [String] {
        let pool: [String]
        if studyMode {
            // Practice pool = the letters this session trains
            // (uppercase): the assigned 3 of the 5 study letters, or all
            // five under the `allFiveLetters` comparison switch. The H6
            // post-test covers all 5 either way; the untrained 2 are the
            // within-child baseline when there are any.
            //
            // Reads `effectiveTrainedSubset` rather than re-deciding the
            // switch here — the pool and the stamped row must not be able
            // to disagree about which letters were trained, and this is
            // the same fact.
            pool = letters
                .filter {
                    studyBaseLetters.contains($0.baseLetter)
                    && effectiveTrainedSubset.letters.contains($0.baseLetter)
                    && $0.letterCase == .upper
                }
                .map(\.name)
        } else if showAllLetters {
            pool = letters.map(\.name)
        } else {
            pool = letters.filter { studyBaseLetters.contains($0.baseLetter) }.map(\.name)
        }
        let order = letterOrdering.orderedLetters()
        let rankMap = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        let ordered = pool.sorted { a, b in
            let ra = rankMap[a.uppercased()] ?? Int.max
            let rb = rankMap[b.uppercased()] ?? Int.max
            return ra == rb ? a < b : ra < rb
        }
        // DE-DUPLICATE, order-preserving. This list is a navigation
        // pool of NAMES, and both `nextLetter()` and `previousLetter()`
        // navigate it BY INDEX — so a repeated name makes
        // `visible[(idx + 1) % count]` resolve to the same letter and
        // the chevron looks dead.
        //
        // Measured on device 2026-09-16 (iPad 00008103-000E60311AE8801E,
        // Debug-Study): the study pool for a trained subset of F/I/L held
        // FIFTEEN entries — five copies of each — and `letters` held 295
        // assets in total, because `BundleLetterResourceProvider
        // .searchBundles` enumerates the module bundle AND the main bundle
        // and `allResourceURLs()` concatenates both, so every letter is
        // collected more than once. `nextLetter()` then advanced from the
        // first "I" to the second "I", leaving the pill unchanged on every
        // tap. That is the whole of report 1.
        //
        // Deduplicating here fixes the navigation for any cause of a
        // repeated name. The over-collection itself is a separate defect
        // (295 assets where 87 files exist) and is NOT fixed here.
        var seen = Set<String>()
        return ordered.filter { seen.insert($0).inserted }
    }

    var activeStrokeIndex: Int { strokeTracker.currentStrokeIndex }
    /// Whether the stroke at `index` has been completed.
    func isStrokeCompleted(_ index: Int) -> Bool {
        strokeTracker.progress.indices.contains(index) && strokeTracker.progress[index].complete
    }

    func resetForPhaseTransition() {
        // The probe's closing window for the ending phase is emitted by
        // `PhaseTransitionCoordinator.advance` BEFORE the phase advances
        // (2026-10-05) — here, after the advance, it carried the NEXT
        // phase's name.
        // The observe sound stops with its phase (below), so it no longer
        // tracks the dot.
        observeSoundTracksDot = false
        strokeTracker.reset()
        guard letters.indices.contains(letterIndex) else { return }
        reloadStrokeCheckpoints(for: letters[letterIndex])
        progress = 0
        // Snapshot the just-finished trace so the canvas keeps showing
        // it for ~5 s while the next phase comes up — child sees their
        // own ink survive the transition rather than blink away.
        //
        // …but NOT into `freeWrite` (2026-10-02, proctor's device run).
        // That phase is the UNASSISTED trial: the outline is gone on
        // purpose, and the ink of the assisted attempt left on screen is
        // an aid the child can trace over. Beyond looking wrong, it
        // contaminates the one phase whose whole point is that nothing
        // is left to copy. The comfort of watching one's own ink survive
        // is kept where it is earned — observe -> guided, where the
        // outline is still present anyway.
        let carriesIntoUnassistedTrial = phaseController.currentPhase == .freeWrite
        if !activePath.isEmpty, !carriesIntoUnassistedTrial {
            lingeringInk = activePath
            lingeringInkClearTask?.cancel()
            lingeringInkClearTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let self else { return }
                self.lingeringInk = []
            }
        } else if carriesIntoUnassistedTrial {
            // Any snapshot still fading from an EARLIER transition would
            // outlive its 5 s and reach the unassisted trial anyway.
            lingeringInkClearTask?.cancel()
            lingeringInk = []
        }
        activePath.removeAll(keepingCapacity: true)
        lastRecognitionResult = nil
        recognitionTokens.cancel()
        // didCompleteCurrentLetter means "letter session done"; the
        // sequence-completion path on guided sets it true, but only
        // the guided *phase* is done, so reset here to keep the
        // freeWrite auto-advance gate working across guided→freeWrite.
        didCompleteCurrentLetter = false
        // Preserve lastGuidedScore across clearAll — the guided→
        // freeWrite path sets it immediately before we get here, and
        // SchuleWorldView's "Nachspuren fertig" card needs it.
        let savedGuidedScore = freeWriteRecorder.lastGuidedScore
        freeWriteRecorder.clearAll()
        freeWriteRecorder.lastGuidedScore = savedGuidedScore
        // Stop the previous phase's guide animation before deciding
        // whether to restart — otherwise it scans into freeWrite/direct.
        stopGuideAnimation()
        if phaseController.currentPhase == .freeWrite {
            freeWriteRecorder.startSession()
        } else if phaseController.currentPhase == .guided {
            freeWriteRecorder.startGuidedSpeedTracking()
            // NO guide animation in the guided phase (2026-09-17). The
            // animated guide dot is the OBSERVE phase's element — the
            // thesis scopes it there ("the animation ends after two
            // cycles", 03-architecture.typ:16) and describes guided as
            // "the letter is shown as a ghost outline and the child
            // traces it" with progress tracked by checkpoint proximity
            // (:18), with no moving dot. Running the same animator here
            // put a dot on the canvas for the whole time the child was
            // tracing — the supervisor read it as the app tracing the
            // letter for them ("beim nachfahren selbst kein Punkt").
            // The ghost outline and the stroke start dots remain; those
            // are what guided is specified to show.
            stopGuideAnimation()
        }
        directTappedDots.removeAll()
        directPulsingTask?.cancel()
        directPulsingTask = nil
        directPulsingDot = false
        directArrowStrokeIndex = nil
        // Phase transitions can fire mid-stroke from updateTouch; if
        // the gesture is then interrupted (incoming call, Control
        // Centre swipe), the active flag would strand true and reject
        // future touches. Reset goes through the dispatcher.
        touchDispatcher.resetTouchState()
        playback.resumeIntent = false
        playback.cancelPending()
        audio.stop()
        playback.forceIdle()
        isPlaying = false
    }

    // MARK: - Parent dashboard access

    var dashboardSnapshot: DashboardSnapshot { dashboardStore.snapshot }

    /// Every participant recorded on this device, export-ready: every
    /// sealed archive (see `ParticipantArchiveStore`) plus the current
    /// live participant, oldest `enrolledAt` first — the "export once at
    /// the end covering everyone" a multi-child kindergarten session
    /// needs (2026-09-14), instead of one export per child that had to
    /// happen before the next enrolment or be lost.
    var allParticipantExportSources: [ParticipantExportSource] {
        let archived = participantArchive.archivedParticipants.map {
            ParticipantExportSource(snapshot: $0.snapshot, participantId: $0.participantId,
                                    progress: $0.progress, rawTraces: $0.rawTraces,
                                    enrolledAt: $0.enrolledAt)
        }
        let current = ParticipantExportSource(
            snapshot: dashboardSnapshot, participantId: ParticipantStore.participantId,
            progress: allProgress, rawTraces: rawTraces, enrolledAt: ParticipantStore.enrolledAt)
        return archived + [current]
    }
    /// Every enrolment on this device, oldest first — exported as its own
    /// block, never as participants (`ParentDashboardExporter
    /// .enrolmentBlock`).
    var enrolmentRecords: [EnrolmentRecord] { enrolmentLog.enrolments }
    var currentStreak: Int { streakStore.currentStreak }
    var longestStreak: Int { streakStore.longestStreak }
    /// Achievement events the child has unlocked. Surfaced in the
    /// Fortschritte badge gallery.
    var earnedRewards: Set<RewardEvent> { streakStore.earnedRewards }

    enum SpeedTrendDirection { case improving, stable, declining }

    /// Aggregate writing-speed trend across all practiced letters.
    /// Returns nil when fewer than two speed samples exist for any letter.
    var writingSpeedTrend: SpeedTrendDirection? {
        let trends = progressStore.allProgress.values
            .compactMap(\.speedTrend)
            .filter { $0.count >= 2 }
        guard !trends.isEmpty else { return nil }
        var totalRelGain = 0.0
        var count = 0
        for trend in trends {
            let half = max(1, trend.count / 2)
            let oldAvg = trend.prefix(half).reduce(0.0, +) / Double(half)
            let newAvg = trend.suffix(trend.count - half).reduce(0.0, +) / Double(trend.count - half)
            guard oldAvg > 0 else { continue }
            totalRelGain += (newAvg - oldAvg) / oldAvg
            count += 1
        }
        guard count > 0 else { return nil }
        let avg = totalRelGain / Double(count)
        if avg > 0.10 { return .improving }
        if avg < -0.10 { return .declining }
        return .stable
    }

    // MARK: - Debug

    #if DEBUG
    /// Raw-name of the participant's assigned A/B condition. Surfaced in the
    /// dashboard's debug-only Forschungsmetriken section so a researcher can
    /// confirm at a glance which arm the device is on.
    var thesisConditionRawName: String { thesisCondition.rawValue }
    #endif

    // Test-support surface, deliberately compiled in BOTH configurations
    // (2026-09-17). These four were `#if DEBUG`-gated, and that is what
    // made `PrimaeNativeTests` structurally unable to build under
    // `Release-Study` — the configuration the PILOT actually ships. The
    // unit suite had therefore only ever validated a configuration no
    // participant ever runs, which is the wrong way round: a `-O` build
    // is where an inliner bug would live (ROADMAP F11), and it was the
    // one build with no test coverage at all.
    //
    // Read-only accessors plus one await; none of them mutates state, so
    // compiling them in changes no behaviour. They are NOT on the
    // ios-build.yml SURFACES list — that check is for child- and
    // parent-facing surfaces compiled out of the study build, which these
    // are not.
    var debugActivePathCount: Int { activePath.count }

    /// Test-only deterministic await for the playback debounce window.
    /// Lets integration tests skip the real wall-clock sleep that made
    /// `fastTouch_triggersPlay` flaky on slow CI runners.
    func awaitPlaybackDebounce() async {
        await playback.pendingTransition?.value
    }

    /// Test-only inspection of the D-1 active-time accumulator.
    /// Exposed so the suite can pin the
    /// background-pauses-the-timer / foreground-resumes-it contract
    /// without the integration overhead of a full session-complete
    /// path. nil when a foreground window is currently open.
    var debugLetterLoadTime: CFTimeInterval? { letterLoadTime }

    /// TEST-ONLY: the latest measured `AUDIO-SIGNAL` line, or nil before
    /// the first measurement window closes.
    ///
    /// Read by the XCUI test off the accessibility tree. It has to ride
    /// that channel because there is no shared writable location between
    /// the app and the test runner (see `AudioSignalProbe
    /// .latestSummaryLine`). nil in any launch that is not probe-armed,
    /// so it is inert in the pilot artefact.
    var debugAudioSignalSummary: String? { audioSignalProbeSink.latestAudioSignalSummary }
    var debugLetterActiveTimeAccumulated: TimeInterval { letterActiveTimeAccumulated }

    // MARK: - Private helpers

    /// Load a letter into the canvas + reset phase state.
    ///
    /// `playPhaseCue: false` skips the spoken phase prompt at the
    /// end of this method. The init-time call (`load(letter: first)`
    /// from `init(_:)`) passes `false` because the audio engine
    /// hasn't finished bringing up its session, AVSpeech / the
    /// PromptPlayer would queue speech against a half-warm
    /// pipeline, and the resulting clip is what plays as ~2 s of
    /// crackle when a returning user opens the app straight to the
    /// main screen. Subsequent loads (user picks a letter, the
    /// scheduler advances after a celebration) all default to
    /// `playPhaseCue: true` because by then the app is settled.
    /// Study launch state: the launch letter is loaded but NOTHING is
    /// armed — no observe animation, no auto-advance, no sound-arm
    /// demonstration, no active-time clock — until `startParkedLetter()`
    /// (the observe pill tap under studyMode). Before 2026-09-06 the
    /// launch letter ran a full unattended observe phase at app start:
    /// its demonstration played into whatever the headphones were
    /// pointed at, two cycles auto-advanced it into `direct`, and the
    /// proctor's first probe load then wrote a `completed:false` row for
    /// a letter nobody touched — all before the pretest.
    private(set) var launchParked = false

    /// The child's trained set is finished: the last letter's session is
    /// recorded, the closing celebration has played, and the device waits
    /// for "Nächstes Kind" (2026-10-02).
    ///
    /// Set only when the letter just finished is the LAST of the visible
    /// trained set, so a mid-set letter never trips it. Reset by
    /// `resetForNewParticipant`, which is the single place a new child's
    /// session begins — including the in-place path, since that is what
    /// the batch flow uses between children.
    private(set) var awaitingNextParticipant = false

    /// Called by the final-phase pipeline once the LAST letter of the
    /// child's set is recorded. Separate from the setter because the
    /// coordinator is a different type and this is a state TRANSITION,
    /// not a field it should reach for.
    func finishSetAwaitingNextParticipant() {
        awaitingNextParticipant = true
    }

    /// True when the letter on screen is the last of the child's trained
    /// set, in the fixed study order. Read from `visibleLetterNames`, the
    /// same pool `nextLetter()` walks, so "last" cannot disagree with
    /// "next".
    /// Whether finishing this letter finishes the child's SET — the
    /// condition for the one end-of-set celebration.
    ///
    /// REQUIRES MORE THAN ONE LETTER IN THE POOL (2026-10-02,
    /// MEASURED). A one-letter pool made every trial "the last one", so
    /// the celebration fired per letter — which is precisely the
    /// per-letter reward the C2 ruling suppresses, and it would tell a
    /// proctor running 30-40 children that every child "finished" after
    /// a single letter. The guard costs nothing: a session whose pool is
    /// genuinely one letter long has no meaningful "end of set" to
    /// announce, and the trial still completes and records normally.
    var isLastLetterOfSet: Bool {
        let visible = visibleLetterNames
        guard visible.count > 1,
              let idx = visible.firstIndex(of: currentLetterName) else { return false }
        return idx == visible.count - 1
    }

    /// Start the parked launch letter for real (full `load`, which arms
    /// everything the observe phase needs). No-op unless parked.
    func startParkedLetter() {
        guard launchParked, letters.indices.contains(letterIndex) else { return }
        launchParked = false
        load(letter: letters[letterIndex])
    }

    private func load(letter: LetterAsset, playPhaseCue: Bool = true, parked: Bool = false) {
        launchParked = parked
        // Set in the observe branch below, acted on after the file reload
        // further down (P4 — see `claimWholeObserveSound` and
        // `armObservePresentationAfterCue`).
        var startWholeObserveSound = false
        var armStudyObservePresentation = false
        // Study mode: the OUTGOING letter's trial must not vanish — a
        // finished-but-unscored freeWrite is scored and recorded, a
        // letter left mid-phase gets a `completed: false` row. Runs
        // BEFORE anything below resets state; a no-op at init and for an
        // untouched letter. See PhaseTransitionCoordinator
        // .recordUnloadOfCurrentLetter (2026-09-04).
        phaseTransitions.recordUnloadOfCurrentLetter(
            touchStillActive: touchDispatcher.isSingleTouchInteractionActive)
        // The arm steps HERE — after that unload row, and before anything
        // below reads the arm (the pre-task demonstration, the audio file
        // list, the phase rows). Both halves are deliberate (2026-09-17):
        // the unload record stamps `audioCondition` onto the OUTGOING
        // letter's final row, so stepping first would relabel a letter's
        // last row with the NEXT letter's arm — the one corruption this
        // feature could inflict on the export. Nothing below can fire
        // mid-trace: `load(letter:)` is the only caller, it is synchronous
        // and main-actor isolated, so the arm cannot change between a
        // child's touch-down and touch-up.
        cycleAudioConditionIfConfigured(toLetterNamed: letter.name)
        lastScheduledLetterPriority = 0   // only loadRecommendedLetter sets it, after this load
        phaseController.reset()
        // Cold-probe override (pretest / post-test / delayed), consumed
        // here so it never leaks into the NEXT letter load. Landing
        // directly in freeWrite is a supported shape below (activePhases
        // requires .threePhase, which studyMode pins) — the "if
        // phaseController.currentPhase == .freeWrite" checks further down
        // handle starting the freeWriteRecorder session for a phase
        // reached this way. `currentProbe` is what the rows get stamped
        // with; a normal training load clears it.
        currentProbe = pendingProbeOverride
        pendingProbeOverride = nil
        if currentProbe != nil {
            phaseController.resume(at: .freeWrite)
        }
        freeWriteRecorder.clearAll()
        showingVariant = false
        variantStrokeCache = nil
        scriptStrokeCache.removeAll(keepingCapacity: true)
        // FreeformController owns lastFreeformFormScore now — clearing the
        // freeform buffers as part of letter load resets it alongside.
        freeform.clearBuffers()
        lastRecognitionResult = nil
        recognitionTokens.cancel()
        overlayQueue.reset()
        directTappedDots.removeAll()
        directPulsingTask?.cancel()
        directPulsingTask = nil
        // A pending whole-observe start belongs to the letter being
        // replaced — without this, a fast proctor arrow could fire the
        // outgoing letter's observe sound into the incoming letter's
        // observe phase, a condition that already spent its claim
        // included.
        cancelPendingObservePresentation()
        directPulsingDot = false
        directArrowStrokeIndex = nil
        showGhost                      = false
        currentLetterName              = letter.name
        // Only point at which the detector can downgrade from .pencil
        // back to .finger — see InputModeDetector for the hysteresis
        // rule. Runs BEFORE reapplyGridPreset so the grid reflects
        // post-reset state.
        detector.resetForSequenceChange()
        // Build the grid BEFORE loading stroke checkpoints: reapplyGridPreset
        // creates fresh LetterCell instances with brand-new StrokeTrackers,
        // and `strokeTracker` is now a computed alias for grid.activeCell.tracker.
        // Loading into the old grid's tracker would be thrown away here.
        reapplyGridPreset()
        reloadStrokeCheckpoints(for: letter)
        // Errorless-learning ramp for the first three sessions on a
        // new letter. The MovingAveragePolicy starts at `.standard`
        // for every letter regardless of prior exposure; widening
        // the radius on the first few encounters supports motor-
        // pattern formation without repeated near-miss failure on
        // novel letters (Skinner 1958; Terrace 1963). From session 4
        // the policy tier drives the radius again.
        // Errorless-learning ramp — suppressed in study sessions: the
        // radius must be identical for every child regardless of prior
        // exposure (guided difficulty is held constant, like the
        // adaptation policy).
        let priorCompletions = progressStore.progress(for: letter.name).completionCount
        if !studyMode, priorCompletions < 3 {
            strokeTracker.radiusMultiplier = max(
                strokeTracker.radiusMultiplier,
                DifficultyTier.easy.radiusMultiplier
            )
        }
        progress                       = 0
        audioIndex                     = 0
        didCompleteCurrentLetter       = false
        letterLoadTime                 = CACurrentMediaTime()
        letterActiveTimeAccumulated    = 0
        letterLoadedDate               = Date()
        messages.clearCompletionState()
        activePath.removeAll(keepingCapacity: true)
        touchDispatcher.resetTouchState()
        playback.resumeIntent   = true
        playback.cancelPending()
        stopGuideAnimation()
        // Auto-start stroke animation in observe phase, or skip phases entirely
        // when the letter has no strokes (lowercase/umlaut placeholders) — there's
        // nothing to demonstrate, and isComplete would otherwise report vacuous success.
        if phaseController.currentPhase == .observe {
            // Use the active script's strokes (rawGlyphStrokes) for both the
            // empty-strokes skip check and the animation payload so
            // Schreibschrift mode animates the Playwrite path, not the
            // Druckschrift skeleton from letter.strokes.
            let observeStrokes = rawGlyphStrokes ?? letter.strokes
            if observeStrokes.strokes.isEmpty {
                phaseController.advance(score: 1.0)  // skip observe
                if phaseController.currentPhase == .direct {
                    phaseController.advance(score: 1.0)  // skip direct (no dots to tap)
                }
            } else if parked {
                // Parked study launch: the ghost is on screen, nothing
                // runs, no active time accrues. `startParkedLetter()`
                // re-runs this load un-parked.
                letterLoadTime = nil
            } else {
                armObserveAutoAdvance()
                if studyMode {
                    // P4, Option B (2026-10-05): the animation waits for
                    // the observe instruction and starts WITH the arm's
                    // sound — armed below, after the file reload. Every
                    // arm, so their timing stays matched.
                    armStudyObservePresentation = true
                } else {
                    animation.startAfterDelay(0.3 + presentationSpacing,
                                              strokes: observeStrokes)
                }
                // P4 (David, 2026-10-04): in a study session the sound
                // arms hear their sound for the WHOLE observe animation.
                // That replaces the 2 s pre-task demonstration here — the
                // demonstration's own `audio.stop()` at 2 s would cut the
                // whole-animation sound short. The sound itself starts
                // BELOW, after this load's file reload, which stops
                // playback (`AudioEngine.loadAudioFile` → `player.stop()`):
                // started here, it would be silenced within the same call,
                // which is exactly what happened to the spatial carrier.
                startWholeObserveSound = claimWholeObserveSound(for: letter)
                if !startWholeObserveSound {
                    armPreTaskDemonstration(for: letter)
                }
                startAudioSignalTicker()
            }
        }
        // If we land directly in guided or freeWrite (e.g. after skipping phases or
        // for thesis conditions that omit observe/direct), start the speed clock now.
        if phaseController.currentPhase == .freeWrite {
            freeWriteRecorder.startSession()
            // H6 post-test: deliberately NO demonstration — reaching
            // this letter at all is a cold, untrained probe, and a
            // demonstration would train the very thing the probe
            // depends on not having happened.
            preTaskDemoTask?.cancel()
            preTaskDemoTask = nil
            // MEASURED 2026-10-03: without this the probe produced ZERO
            // samples here, because this branch never reaches either
            // observe landing site. A phase with no samples cannot be
            // distinguished from a phase that is genuinely silent — see
            // `startAudioSignalTicker`.
            startAudioSignalTicker()
        } else if phaseController.currentPhase == .guided {
            freeWriteRecorder.startGuidedSpeedTracking()
            // No guide animation here either — see the note in the
            // phase-entry path above. Guided shows the ghost outline and
            // the stroke start dots, not a moving dot.
            stopGuideAnimation()
            armPreTaskDemonstration(for: letter)
            startAudioSignalTicker()
        }
        if let firstAudio = activeAudioFiles(for: letter).first {
            audio.loadAudioFile(named: firstAudio, autoplay: false)
            playback.request(.idle, immediate: true)
            // Audio plays in response to touches via the playback state machine;
            // no observe-phase auto-play (it would loop silently behind onboarding
            // and start immediately on letter switch without any user action).
        }
        // The one exception to "no observe-phase auto-play": the study
        // sound arms' whole-observe sound (P4), claimed in the observe
        // branch above. Armed here, AFTER the reload just above, so the
        // reload cannot stop what it starts — and STARTED, together with
        // the observe animation, only once the observe instruction below
        // has been spoken (flag 3, 2026-10-04; Option B, 2026-10-05). See
        // `armObservePresentationAfterCue`. It ends with the phase:
        // `resetForPhaseTransition` stops the engine.
        if armStudyObservePresentation {
            armObservePresentationAfterCue(letter: letter,
                                           soundArm: startWholeObserveSound ? audioCondition : nil)
        }
        // Speak the initial phase prompt once a fresh letter loads.
        // Phase *transitions* are spoken from `advanceLearningPhase`;
        // this site covers the very first phase a child sees per
        // letter (typically observe, but can be guided when the
        // thesis condition skips observe/direct or when an empty-
        // strokes letter auto-skipped). Empty-strokes letters that
        // vacuously land at .guided also land here, so a child
        // still gets a verbal cue rather than silence.
        //
        // Gated on onboarding completion: this method runs once
        // during VM init (`load(letter: first)` in `init(_:)`),
        // which fires *before* SwiftUI decides whether to show
        // OnboardingView. Speaking here on a first-run install
        // makes the welcome screen play 2 s of "Pass jetzt gut
        // auf!" while the child looks at the onboarding cards —
        // confusing audio for content the screen doesn't show.
        // Once onboarding completes, every subsequent letter load
        // is post-onboarding and the cue is welcome.
        //
        // STUDY BUILDS HAVE NO ONBOARDING (2026-10-04). `OnboardingView`
        // is compiled out, so nothing ever set `isOnboardingComplete` and
        // "Schau genau hin." reached no child in any arm. The study-safe
        // trigger: study mode, landing in observe, and NOT parked — the
        // parked launch load runs before a child is enrolled, and
        // `startParkedLetter` re-runs this load un-parked when one is.
        // One load is one observe phase, so this speaks once per observe
        // phase, in every arm (the study voiceover, P3). The whole-observe
        // sound WAITS THIS CUE OUT before starting
        // (`armObservePresentationAfterCue`, flag 3, Option B): the child hears the
        // instruction, then the arm's sound — not both at once.
        // Deliberately observe only: a cold probe lands in freeWrite and
        // stays without a cue, as before.
        let studyObserveCue = studyMode && !parked
            && phaseController.currentPhase == .observe
        if studyObserveCue && playPhaseCue {
            // One more observe cue queued; its end starts the presentation
            // (`cueUtteranceEnded`). Counted so an OLDER load's cue ending
            // late is not mistaken for this one's.
            pendingObserveCues += 1
        }
        if (isOnboardingComplete || studyObserveCue) && playPhaseCue {
            prompts.play(
                ChildSpeechLibrary.phaseEntryPromptKey(phaseController.currentPhase),
                fallbackText: ChildSpeechLibrary.phaseEntry(phaseController.currentPhase)
            )
        }
    }

    private func randomAudioVariant() {
        let files = activeAudioFiles(for: letters[letterIndex])
        guard !files.isEmpty else { return }
        audioIndex = Int.random(in: 0..<files.count)
        audio.loadAudioFile(named: files[audioIndex], autoplay: false)
        playback.request(.idle, immediate: true)
    }

    func showCompletionHUD() {
        // Reward-class feedback — off in study sessions (audit C2).
        guard !studyMode else { return }
        messages.show(completion: "🎉 \(currentLetterName) geschafft!")
    }

    /// Reload stroke checkpoints mapped to canvas-normalised coordinates (0–1).
    /// Pass `usingSize` to override `self.canvasSize` — used by `updateTouch` to
    /// guarantee the mapping size equals the size used to normalise the touch point.
    /// Idempotent: a rebuild with the same (letter, size, schriftArt) as the
    /// prior successful rebuild is skipped, so the rotation safety-net window
    /// in `updateTouch` and repeated `canvasSize.didSet` triggers at the same
    /// dimensions don't burn CPU re-mapping unchanged data. The cache hit is
    /// gated on `strokeTracker.definition != nil` so any path that resets the
    /// tracker (resetLetter, phase transition) automatically misses and rebuilds
    /// without each reset site having to remember to invalidate the key.
    func reloadStrokeCheckpoints(for letter: LetterAsset, usingSize size: CGSize? = nil) {
        // Stroke coordinates in JSON are glyph-relative (0–1 within bounding box).
        // Map to per-cell-normalised coordinates using each cell's glyph rect,
        // so a multi-cell layout runs each cell's tracker in its own
        // cell-local 0–1 space. For a length-1 finger sequence the single
        // cell's frame equals the whole canvas, so the mapping is identical
        // to the pre-grid canvas-wide checkpoints.
        //
        // Source-of-truth priority: variant (when toggled) → per-script JSON
        // → user calibration → bundle default.
        let effectiveSize = size ?? canvasSize
        let key = CheckpointBuildKey(letter: letter.name, size: effectiveSize, schriftArt: schriftArt, showingVariant: showingVariant)
        if key == lastCheckpointKey, strokeTracker.definition != nil { return }
        let source: LetterStrokes
        if showingVariant, let vs = variantStrokeCache {
            source = vs
        } else if let ss = activeScriptStrokes {
            source = ss
        } else {
            source = resolvedStrokes(for: letter)
        }
        for cell in grid.cells {
            let cellLetter = cell.item.letter
            // Per-cell source: the loaded letter keeps its full override
            // chain (variant / script / calibration). Other letters (word
            // mode: the non-first cells) fall back to the bundle's default
            // Druckschrift strokes for that letter. Unknown letters skip.
            let cellSource: LetterStrokes
            if cellLetter == letter.name {
                cellSource = source
            } else if let cellAsset = letters.first(where: { $0.name == cellLetter }) {
                cellSource = cellAsset.strokes
            } else {
                continue
            }
            let cellSize = cell.frame.size
            // `tracker.load` resets `radiusMultiplier` to 1.0; a canvas
            // resize mid-letter must not silently drop the errorless-
            // learning ramp / adapted tier (audit 2026-09-04). Study
            // builds pin it to 1.0 anyway.
            let keptRadiusMultiplier = cell.tracker.radiusMultiplier
            defer { cell.tracker.radiusMultiplier = keptRadiusMultiplier }
            guard cellSize.width > 0, cellSize.height > 0 else {
                // Pre-layout state (e.g. during init before onAppear) — fall
                // back to the source strokes so the tracker at least has
                // definition loaded; the next layout pass will rebuild.
                cell.tracker.load(cellSource)
                continue
            }
            // JSON stroke checkpoints are glyph-bbox-relative (0..1 of
            // the rendered glyph's bbox). Map them through the cell's
            // glyph rect into cell-fraction coords (0..1 of the cell)
            // so proximity hit-tests and the renderer share one frame.
            // Skip the remap when the rect lookup fails so the tracker
            // at least has a definition; pre-layout passes also fall
            // through this branch.
            if let gr = PrimaeLetterRenderer.normalizedGlyphRect(
                for: cellLetter, canvasSize: cellSize,
                schriftArt: schriftArt,
                openTypeFeatures: PrimaeLetterRenderer.openTypeFeatures(
                    for: cellLetter, schriftArt: schriftArt, variant: showingVariant)) {
                let mappedStrokes = cellSource.strokes.map { def in
                    StrokeDefinition(
                        id: def.id,
                        checkpoints: def.checkpoints.map { cp in
                            Checkpoint(
                                x: gr.minX + cp.x * gr.width,
                                y: gr.minY + cp.y * gr.height
                            )
                        }
                    )
                }
                cell.tracker.load(LetterStrokes(
                    letter: cellSource.letter,
                    checkpointRadius: cellSource.checkpointRadius
                        * sqrt(gr.width * gr.height),
                    strokes: mappedStrokes
                ))
            } else {
                cell.tracker.load(cellSource)
            }
        }
        lastCheckpointKey = key
    }

    /// The effective stroke definition for every loaded letter — the
    /// calibration when one's been saved, the bundle default otherwise.
    /// This is what the calibrator's "Alle" button ships so a session
    /// can be exported even when the user hasn't tapped Speichern on
    /// each individual letter.
    func loadAllEffectiveStrokes() -> [String: LetterStrokes] {
        var out: [String: LetterStrokes] = [:]
        for letter in letters {
            let resolved = calibrationStore.strokes(for: letter.name,
                                                    schriftArt: schriftArt)
                ?? letter.strokes
            out[letter.name] = resolved
        }
        return out
    }

    /// Wipes every persisted calibration for the active script and
    /// reloads the current letter so the bundle takes over immediately.
    /// Used after shipping a new bundle that supersedes the on-device
    /// calibration set.
    func clearAllCalibrations() {
        calibrationStore.clearAll(for: schriftArt)
        lastCheckpointKey = nil
        if letters.indices.contains(letterIndex) {
            reloadStrokeCheckpoints(for: letters[letterIndex])
        }
    }

    /// Single clean-slate action for a new enrollee on a shared study
    /// device. The caller MUST have exported first (researcher-gated in
    /// ResearchDashboard) — this is irreversible. Wipes every
    /// participant-scoped data store, clears on-device calibrations, and
    /// regenerates participant identity (new UUID → re-randomised arms,
    /// cleared overrides, fresh enrolment). Device/parent config is
    /// preserved. Returns the new participant UUID.
    ///
    /// The new arm assignment takes effect on the NEXT app launch — the
    /// VM captures `thesisCondition` / `audioCondition` as `let` at init —
    /// so the caller surfaces a "relaunch required" prompt.
    /// Set by `resetForNewParticipant()` and `markParticipantRestored()`.
    /// The arms and the trained subset are `let`s captured at init, so
    /// the VM in memory still carries the PREVIOUS child's; until the
    /// relaunch the research screen asks for, a session would stamp the
    /// new id with the old arm and letters (audit 2026-09-04). Tracing
    /// is refused instead.
    private(set) var participantIdentityChanged = false

    func markParticipantRestored() { participantIdentityChanged = true }

    /// A researcher override (pedagogical arm, audio arm, trained
    /// subset) is read ONCE at init; the running VM keeps its `let`
    /// arms. Until 2026-09-06 nothing blocked tracing after an override
    /// was set, so a session could stamp rows under the UUID-derived arm
    /// after the proctor had chosen a different one — internally
    /// consistent rows, invisible until export. Same relaunch block as
    /// a restored identity.
    private(set) var assignmentOverrideChanged = false

    func markAssignmentOverrideChanged() { assignmentOverrideChanged = true }

    /// Set once, by `handlePersistenceFailure`, on the first disk-write
    /// failure any study data store reports through
    /// `PersistenceFailureCenter` (2026-09-14). Never cleared in
    /// production — see that type's `resetForTesting` doc for why.
    private(set) var persistenceFailureMessage: String?

    /// MainActor callback registered with `PersistenceFailureCenter` at
    /// init. Turns a silent `try?`-swallowed disk write into a visible
    /// toast immediately, plus a hard `sessionBlockReason` stop from the
    /// next check onward — the pilot runs once per child, so "log it and
    /// carry on" is never the right response to "the data may not be
    /// saving." Internal, not `private`, so tests can drive this
    /// directly rather than through the process-wide `.shared` center —
    /// see that type's doc for why sharing it across test suites is
    /// deliberately avoided.
    func handlePersistenceFailure(_ description: String) {
        guard persistenceFailureMessage == nil else { return }   // first failure wins the message
        persistenceFailureMessage =
            "Speichern fehlgeschlagen — diese Sitzung wird angehalten, damit keine Daten verloren gehen. Gerät prüfen (Speicherplatz/Berechtigungen) und die App neu starten."
        toast("⚠️ Speichern fehlgeschlagen — Sitzung angehalten")
        storePersistenceLogger.error(
            "TracingViewModel: session hard-stopped on persistence failure: \(description, privacy: .public)")
    }

    /// Why the Schule surface must not start a session right now, or nil.
    /// Folds the study precondition (phoneme recordings), the
    /// identity-changed relaunch requirement, and a failed disk write to
    /// any study data store into one child-facing stop.
    var sessionBlockReason: String? {
        // Checked FIRST, deliberately: a persistence failure means
        // nothing recorded from this point is guaranteed to survive —
        // that outranks every other reason to continue, including one
        // that would otherwise just need a relaunch (2026-09-14).
        if studyMode, let persistenceFailureMessage {
            return persistenceFailureMessage
        }
        if studyMode, participantIdentityChanged {
            return "Teilnehmer gewechselt — die App muss neu gestartet werden, damit Arm und Buchstaben des neuen Kindes gelten."
        }
        if studyMode, assignmentOverrideChanged {
            return "Zuweisung geändert — die App muss neu gestartet werden, damit der gewählte Arm bzw. die gewählten Buchstaben gelten."
        }
        return studyPreconditionFailure
    }

    @discardableResult
    func resetForNewParticipant() -> UUID {
        // Seal the OUTGOING participant's complete record BEFORE any
        // store below is wiped (2026-09-14) — the fix for a confirmed
        // data-loss defect: until this, every prior child's rows on this
        // device were destroyed unconditionally, with no on-device copy
        // surviving except an export the proctor might not have finished
        // saving. Built from the CURRENT in-memory values, which are
        // value types copied into the record here — safe against the
        // stores' `.reset()` calls immediately below, which mutate the
        // stores, not this already-copied struct. See
        // `ParticipantArchiveStore.swift`.
        //
        // ONLY WHEN THEY ACTUALLY DID SOMETHING (2026-10-01, F1). This was
        // unconditional, and a proctor tapping "Neuer Teilnehmer" twice
        // sealed the never-used participant in between: a complete,
        // well-formed block with a valid participantId header and zero data
        // rows. Nothing errored — but `allParticipantExportSources` emits
        // every sealed archive, so the combined export counted those phantoms
        // toward N and every per-arm denominator derived from it.
        //
        // MEASURED on the study iPad, not theorised: 43 sealed archives, 25
        // of them with zero phase rows (18 with data). So this is the common
        // case in a multi-child session, not the rare double-tap edge case it
        // reads like above.
        //
        // The guard reads the SNAPSHOT's two append-only series rather than
        // `progress`/`rawTraces`: a child who traced produced phase rows, and
        // those are what the export's N is derived from. Checking the richer
        // stores instead would keep a phantom alive for a child who somehow
        // touched progress without completing a phase.
        let outgoingSnapshot = dashboardStore.snapshot
        let outgoingDidAnything = !outgoingSnapshot.phaseSessionRecords.isEmpty
            || !outgoingSnapshot.sessionDurations.isEmpty
        if outgoingDidAnything {
            participantArchive.archive(ArchivedParticipant(
                participantId: ParticipantStore.participantId,
                enrolledAt: ParticipantStore.enrolledAt,
                archivedAt: Date(),
                snapshot: outgoingSnapshot,
                progress: progressStore.allProgress,
                rawTraces: rawTraceStore.traces
            ))
        }
        participantIdentityChanged = true
        // Close the outgoing child's in-flight trial FIRST: a pending
        // quiet-window task, an in-flight recognition, or the ink still
        // in the recorder would otherwise be scored on the next load and
        // written under the NEW id with the OLD arms (review 2026-09-05).
        touchDispatcher.resetTouchState()
        abortInFlightRecognition()
        freeWriteRecorder.clearAll()
        didCompleteCurrentLetter = true
        // Reset the phase controller HERE, unconditionally — not left to
        // `loadFirstTrainedLetter`'s `load(letter:)` call below, which
        // resets it as a side effect but can silently no-op (e.g. no
        // letter in `letters` is visible under the newly-derived
        // trainedSubset). Found 2026-09-14: when that happened, the
        // OUTGOING child's `phaseController` state (mid-`.freeWrite`,
        // stale `phaseScores`) survived the reset untouched, and the
        // very next ordinary `loadLetter` call for the INCOMING child —
        // now correctly unblocked — read that stale state as "an
        // abandoned trial" and wrote a phantom row for it, attributed to
        // nobody's real activity. Resetting here makes the phase state
        // clean regardless of whether a letter load follows. `progress`
        // and `directTappedDots` are cleared alongside it for the same
        // reason — `load(letter:)` clears both too, but only on a
        // successful load.
        phaseController.reset()
        progress = 0
        directTappedDots.removeAll()
        // A new child's session begins; the previous one's "finished,
        // hand the device over" hold is over.
        awaitingNextParticipant = false
        dashboardStore.reset()          // PhaseSessionRecords, letterStats, durations
        progressStore.resetAll()        // all LetterProgress
        streakStore.reset()             // streak + stars
        rawTraceStore.reset()           // cold raw freeWrite traces
        clearAllCalibrations()          // on-device stroke overrides (active SchriftArt)
        let newID = ParticipantStore.startNewParticipant()  // new UUID + arms + enrolment
        // …and TELL this view model, or `studyPreconditionFailure` keeps
        // reading the value captured at init and the start-gate never
        // clears (2026-10-02, measured on the iPad). Read from the store
        // rather than hardcoded `true` so the flag can only ever claim
        // what the device actually persisted.
        participantEnrolled = ParticipantStore.isEnrolled
        refreshProgressMirror()         // clear the SwiftUI progress mirror
        // Re-derive this device's live arm assignment for the incoming
        // child IN PLACE (2026-09-14) — see `reapplyParticipantIdentity`.
        // Without this, every enrolment needed a force-quit + relaunch,
        // which a kindergarten queue with one proctor and one iPad
        // cannot absorb between children.
        reapplyParticipantIdentity()
        // Log the enrolment ITSELF, apart from any participant data
        // (2026-10-04). The guard above deliberately does not seal a child
        // who did nothing, so without this a child who stops before
        // finishing a letter leaves no trace at all. The arm and subset
        // are read from the assignment for the NEW identifier — the same
        // values `reapplyParticipantIdentity` just applied in a study
        // session — so the record is right outside one too. It never
        // becomes a participant: see `EnrolmentLog.swift`.
        enrolmentLog.append(EnrolmentRecord(
            participantId: newID,
            enrolledAt: ParticipantStore.enrolledAt,
            audioCondition: .defaultForInstall,
            trainedSubset: TrainedLetterSubset.defaultForInstall.rawValue,
            protocolRevision: StudyProtocol.revision))
        return newID
    }

    /// Re-derives the live arm assignment for whichever participant
    /// `ParticipantStore.participantId` now names, and loads their first
    /// trained letter — the in-process replacement (2026-09-14) for the
    /// app relaunch `resetForNewParticipant` used to require.
    ///
    /// Scoped to `studyMode` deliberately, not a general capability: a
    /// STUDY build pins every OTHER init-time decision that could
    /// otherwise depend on the arms (haptics/speech/prompts → Null,
    /// adaptationPolicy → Fixed, schriftArt → Druckschrift, letterOrdering
    /// → motorSimilarity — see `init`) to `studyMode` alone, not to the
    /// arm values, so re-deriving just the three arm properties here is a
    /// COMPLETE re-init for the pilot, not a partial one that silently
    /// leaves something stale. A non-study install's haptics/speech ARE
    /// arm-dependent (the silent-arm nulling), so it is deliberately left
    /// on the old relaunch-required path (`sessionBlockReason`) rather
    /// than risk an incomplete in-place rebuild there — that path is not
    /// what the kindergarten pilot workflow depends on.
    private func reapplyParticipantIdentity() {
        guard studyMode else { return }
        thesisCondition = .threePhase   // studyMode always pins this; restated for symmetry.
        // Through `applyArm`, not a bare assignment: the incoming child's
        // arm carries its own authority with it (C3-2), so a switch from a
        // sound arm into the silent one also silences speech here — the
        // same hole this closes that the comparison cycle would otherwise
        // open from the other direction. `cycleArmLetter` is cleared so the
        // incoming child's FIRST letter adopts their assigned arm rather
        // than consuming a step of the outgoing child's cycle.
        applyArm(.defaultForInstall)
        cycleArmLetter  = nil
        // The incoming child's session has demonstrated nothing yet
        // (2026-09-17). Without this, an iPad with `oncePerCondition` ON
        // would carry the OUTGOING child's used-up conditions into the
        // next child's session — and since the app is deliberately not
        // relaunched between children (`resetForNewParticipant`), the
        // second child in the same arm would be denied the demonstration
        // entirely, silently. Cleared before `loadFirstTrainedLetter`
        // below, which is what arms that child's first demonstration.
        demonstratedAudioConditions.removeAll()
        trainedSubset   = .defaultForInstall
        loadFirstTrainedLetter()
        // …and UN-PARK it, because enrolling IS the proctor saying the
        // session starts now (2026-10-02). The park exists for the APP
        // LAUNCH: before it, an unattended launch ran a full observe
        // phase — demonstration into whatever the headphones pointed at,
        // auto-advancing, and a `completed:false` row for a letter nobody
        // touched, all before the pretest. That risk is about the app
        // coming up on its own, and it is untouched by this: nothing
        // happens until a proctor has enrolled a child. What this removes
        // is the extra tap between children in a batch of 30-40, which is
        // the workflow the rail gesture (PR #22) exists to serve.
        //
        // A no-op unless the launch letter is actually parked, so it
        // cannot double-start a letter, and inert outside studyMode.
        startParkedLetter()
        participantIdentityChanged = false
    }

    /// Persist calibrated glyph-relative checkpoints. Delegates to CalibrationStore
    /// and re-applies the new data to the tracker so the current letter reflects
    /// the calibration immediately without navigating away and back.
    /// The letter's authored checkpoint radius under the current script.
    private func authoredCheckpointRadius(for letter: String) -> CGFloat {
        strokeTracker.definition?.checkpointRadius
            ?? letters.first(where: { $0.name == letter })?.strokes.checkpointRadius
            ?? 0.10
    }

    func persistCalibratedStrokes(_ strokes: [[CGPoint]], for letter: String) {
        calibrationStore.persist(strokes, for: letter, schriftArt: schriftArt,
                                 checkpointRadius: authoredCheckpointRadius(for: letter))
        guard letters.indices.contains(letterIndex) else { return }
        // Calibration replaces the source checkpoint set, so the (letter, size)
        // idempotency cache no longer reflects what's loaded — invalidate it
        // before the rebuild call so the cache check doesn't short-circuit us.
        lastCheckpointKey = nil
        reloadStrokeCheckpoints(for: letters[letterIndex])
    }

    /// Variant that persists to an explicit schriftArt — required when the
    /// active schriftArt has just changed (the calibrator's navigation
    /// auto-save fires after vm.schriftArt has already become the new
    /// value, so the unsaved edits belong to the PREVIOUS schriftArt). No
    /// tracker reload here because the live tracker is already loading
    /// the new schriftArt; restamping the previous one would fight that.
    func persistCalibratedStrokes(_ strokes: [[CGPoint]],
                                   for letter: String,
                                   schriftArt: SchriftArt) {
        calibrationStore.persist(strokes, for: letter, schriftArt: schriftArt,
                                 checkpointRadius: authoredCheckpointRadius(for: letter))
    }

    func toast(_ text: String) {
        messages.show(toast: text)
    }

    /// Idempotency key for `reloadStrokeCheckpoints`. Equal keys mean the cached
    /// strokeTracker contents are still valid for the requested mapping —
    /// (letter changes invalidate via name; rotations via size; font swaps via
    /// schriftArt). Calibration changes invalidate manually since the source
    /// data is not in this key.
    private struct CheckpointBuildKey: Equatable {
        let letter: String
        let size: CGSize
        let schriftArt: SchriftArt
        let showingVariant: Bool
    }

    // MARK: - Freeform writing mode

    /// Switch the app into freeform writing. Clears any in-progress guided
    /// state and starts a fresh blank canvas. The reference letter is
    /// whatever the child last tapped in the letter picker — that name
    /// travels with us as the comparison target.
    func enterFreeformMode(subMode: FreeformSubMode = .letter) {
        freeform.writingMode = .freeform
        freeform.freeformSubMode = subMode
        clearFreeformCanvas()
        freeform.freeformTargetWord = subMode == .word
            ? FreeformWordList.all.first : nil
        // Halt any in-progress phase audio/animation so freeform is quiet.
        stopGuideAnimation()
        audio.stop()
        playback.forceIdle()
        isPlaying = false
        // Probe the recognizer so the freeform footer can distinguish
        // "still thinking" from "model not available" on first paint.
        // Two-flag idempotency: the value flag (`isRecognitionModelAvailable
        // == nil`) gates *re-probing* once the answer is known, while the
        // in-flight flag (`isProbingModel`) gates a second dispatch during
        // the dispatch→result window — without it, rapid freeform-mode
        // toggles spawn redundant CoreML model loads.
        if freeform.isRecognitionModelAvailable == nil, !freeform.isProbingModel {
            freeform.isProbingModel = true
            Task { [weak self, letterRecognizer] in
                let available = await letterRecognizer.isModelAvailable()
                await MainActor.run {
                    self?.freeform.isRecognitionModelAvailable = available
                    self?.freeform.isProbingModel = false
                }
            }
        }
        toast(subMode == .word ? "Wort schreiben" : "Freies Schreiben")
    }

    /// Return to guided tracing mode. Re-loads the current letter so
    /// phase state and strokes are rebuilt fresh.
    func exitFreeformMode() {
        freeform.writingMode = .guided
        freeform.freeformSubMode = .letter
        freeform.freeformTargetWord = nil
        clearFreeformCanvas()
        if letters.indices.contains(letterIndex) {
            load(letter: letters[letterIndex])
        }
    }

    /// Wipe the freeform drawing buffer without leaving freeform mode.
    /// Used by the "Nochmal" button after a recognition result.
    func clearFreeformCanvas() {
        freeform.clearBuffers()
        lastRecognitionResult = nil
        recognitionTokens.cancel()
    }

    /// Pick the next target word for freeform word mode.
    func selectFreeformWord(_ word: FreeformWord) {
        freeform.freeformTargetWord = word
        freeform.freeformSubMode = .word
        clearFreeformCanvas()
    }

    /// Begin a freeform stroke. Mirrors `beginTouch` but skips all
    /// checkpoint / phase / audio side effects. Cancels any pending
    /// recognition debounce so the recognizer waits for THIS stroke to
    /// finish — critical for multi-stroke letters like A, E, F.
    func beginFreeformTouch(at p: CGPoint) {
        guard writingMode == .freeform else { return }
        freeform.pendingRecognitionTask?.cancel()
        freeform.pendingRecognitionTask = nil
        freeform.isWaitingForRecognition = false
        freeform.freeformActivePath = [p]
    }

    func updateFreeformTouch(at p: CGPoint, canvasSize size: CGSize) {
        guard writingMode == .freeform else { return }
        // Record the freeform canvas dimensions separately — we don't
        // touch `canvasSize` because its didSet rebuilds the guided-mode
        // stroke tracker and fires needless work during a blank-canvas
        // stroke. Recognition uses the size passed into submit.
        freeform.freeformCanvasSize = size
        // Skip microscopic repeats — keeps the buffer from ballooning on
        // a palm rest or a stationary touch.
        if let last = freeform.freeformActivePath.last,
           hypot(p.x - last.x, p.y - last.y) < 1.0 { return }
        freeform.freeformActivePath.append(p)
    }

    /// End a freeform stroke. In letter sub-mode this arms a debounced
    /// recognition call — the child has `freeformRecognitionDelay`
    /// seconds to start the next stroke before the recognizer runs.
    /// Multi-stroke letters (A, E, F, H, K, T, X …) need this window so
    /// they don't get classified after only their first stroke. Word
    /// sub-mode waits for the explicit "Fertig" button regardless.
    func endFreeformTouch() {
        guard writingMode == .freeform else { return }
        if freeform.freeformActivePath.count >= 2 {
            freeform.freeformStrokeSizes.append(freeform.freeformActivePath.count)
            freeform.freeformPoints.append(contentsOf: freeform.freeformActivePath)
        }
        freeform.freeformActivePath.removeAll(keepingCapacity: true)

        if freeform.freeformSubMode == .letter, freeform.freeformPoints.count >= 2 {
            scheduleFreeformLetterRecognition()
        }
    }

    /// Arm a debounced recognition call. Cancels any previously-armed
    /// task first so a rapid stroke sequence only produces ONE
    /// recognition call, fired `freeformRecognitionDelay` seconds after
    /// the most recent pen-lift.
    private func scheduleFreeformLetterRecognition() {
        freeform.pendingRecognitionTask?.cancel()
        freeform.isWaitingForRecognition = true
        let delay = freeform.freeformRecognitionDelay
        freeform.pendingRecognitionTask = Task { [weak self] in
            let nanos = UInt64((delay * 1_000_000_000).rounded())
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled, let self else { return }
            self.freeform.isWaitingForRecognition = false
            self.recognizeFreeformLetter()
        }
    }

    private func recognizeFreeformLetter() {
        let pts = freeform.freeformPoints
        let size = freeform.freeformCanvasSize.width > 0
            ? freeform.freeformCanvasSize : canvasSize
        freeform.isRecognizing = true
        freeform.hasRecognitionCompleted = false
        let token = recognitionTokens.issue()
        Task { [weak self, letterRecognizer] in
            let result = await letterRecognizer.recognize(
                points: pts, canvasSize: size, expectedLetter: nil)
            guard let self else { return }
            await MainActor.run {
                guard self.recognitionTokens.isStillActive(token) else { return }
                self.freeform.isRecognizing = false
                self.freeform.hasRecognitionCompleted = true
                self.lastRecognitionResult = result
                if let result {
                    self.freeform.lastFreeformFormScore = self.freeformFormAccuracy(
                        points: pts, canvasSize: size,
                        predictedLetter: result.predictedLetter)
                    self.recordFreeformCompletion(result: result)
                    // Verbal mirror of the freeform popup's headline so a
                    // child who can't read still hears whether the model
                    // recognised their letter. Empty string returns are
                    // intentional silence (low confidence).
                    // W-30: recognizer was called with expectedLetter: nil,
                    // so result.isCorrect is always false — ChildSpeechLibrary
                    // would never take the positive "Du hast ein X geschrieben!"
                    // branch. In freeform mode the prediction IS the answer
                    // (there is no wrong letter), so synthesise a corrected
                    // result that treats the top prediction as correct.
                    let corrected = RecognitionResult(
                        predictedLetter: result.predictedLetter,
                        confidence: result.confidence,
                        topThree: result.topThree,
                        isCorrect: true)
                    let line = ChildSpeechLibrary.recognition(
                        corrected, expected: result.predictedLetter)
                    if !line.isEmpty { self.speech.speak(line) }
                } else {
                    self.freeform.lastFreeformFormScore = nil
                }
            }
        }
    }

    /// Score how closely the freeform path matches the recognized
    /// letter's reference strokes — using the **currently selected
    /// font's** stroke definition, not the Druckschrift default. A
    /// child practising Schreibschrift draws a curvy A that should be
    /// scored against the cursive reference, and a child practising
    /// Druckschrift the angular one. Returns nil when the letter has
    /// no bundled reference for the active font.
    ///
    /// Delegates the maths to `FreeWriteScorer.formAccuracyShape` —
    /// bounding-box normalisation, per-stroke densification, and
    /// symmetric Hausdorff happen there.
    private func freeformFormAccuracy(points: [CGPoint],
                                      canvasSize: CGSize,
                                      predictedLetter: String) -> CGFloat? {
        guard canvasSize.width > 0, canvasSize.height > 0,
              points.count >= 2,
              let reference = referenceStrokes(forLetterNamed: predictedLetter,
                                               schrift: schriftArt)
        else { return nil }
        return FreeWriteScorer.formAccuracyShape(
            tracedPoints: points,
            reference: reference
        )
    }

    /// Resolve a letter name (e.g. "A", "f", "ß") to the stroke
    /// definition for the given script. Schreibschrift /
    /// Grundschrift / Vereinfachte Ausgangsschrift /
    /// Schulausgangsschrift each ship per-letter `strokes_<id>.json`
    /// in the bundle (loaded via `LetterRepository.loadVariantStrokes`);
    /// Druckschrift uses the primary `LetterAsset.strokes`. Falls back
    /// to Druckschrift if a variant isn't bundled for this letter so
    /// new fonts don't have to ship the full alphabet to be useful.
    private func referenceStrokes(forLetterNamed name: String,
                                   schrift: SchriftArt) -> LetterStrokes? {
        let candidates = [name, name.uppercased(), name.lowercased()]
        if let variantID = schrift.bundleVariantID {
            for candidate in candidates {
                if let variant = repo.loadVariantStrokes(
                    for: candidate, variantID: variantID) {
                    return variant
                }
            }
        }
        // Druckschrift, or variant not bundled for this letter — fall
        // back to the primary strokes.json. Better to score against the
        // print form than to drop the metric entirely.
        for candidate in candidates {
            if let asset = letters.first(where: { $0.name == candidate }) {
                return asset.strokes
            }
        }
        return nil
    }

    /// Submit a finished freeform word. Assigns each completed stroke to
    /// one of `target.word.count` equal-width columns by its x-centroid,
    /// then recognises each column independently. Overlapping handwritten
    /// letter bounding boxes (M bleeds into A) no longer collapse into a
    /// single cluster — each stroke belongs to exactly one bucket even
    /// when the child's writing overlaps. `freeformWordResultSlots` holds
    /// one entry per target letter (nil when the column got no strokes)
    /// so the UI can draw grey placeholder chips for missing letters.
    func submitFreeformWord() {
        guard writingMode == .freeform, freeformSubMode == .word,
              let target = freeform.freeformTargetWord,
              !freeform.freeformPoints.isEmpty else { return }

        let segmentationWidth = freeform.freeformCanvasSize.width > 0
            ? freeform.freeformCanvasSize.width : canvasSize.width
        let targetLetters = Array(target.word)
        let buckets = Self.bucketStrokesByTargetLetter(
            points: freeform.freeformPoints,
            strokeSizes: freeform.freeformStrokeSizes,
            canvasWidth: segmentationWidth,
            letterCount: targetLetters.count
        )
        let size = freeform.freeformCanvasSize.width > 0
            ? freeform.freeformCanvasSize : canvasSize

        freeform.isRecognizing = true
        freeform.hasRecognitionCompleted = false
        // Pre-compute per-letter recognition history on the main
        // actor so the detached Task can look it up without re-
        // entering the VM's isolation. Activates the calibrator's
        // practised-letter boost for whichever targets the child has
        // history on. Words with repeated letters (MAMA, OMMA) map
        // the same letter twice; both lookups return the same
        // scores, so collapsing duplicates with `{ first, _ in first }`
        // is semantically equivalent and sidesteps the
        // `Dictionary(uniqueKeysWithValues:)` duplicate-key trap.
        let historyByLetter: [String: [CGFloat]] = Dictionary(
            targetLetters.map { ch -> (String, [CGFloat]) in
                let key = String(ch)
                // formAccuracyHistory, not recognitionAccuracy — see the
                // 2026-09-04 fix note on runRecognizerForFreeWrite.
                let scores = (progressStore.progress(for: key).formAccuracyHistory ?? [])
                              .map { CGFloat($0) }
                return (key, scores)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let token = recognitionTokens.issue()
        Task { [weak self, letterRecognizer] in
            var slots: [RecognitionResult?] = []
            for i in 0..<targetLetters.count {
                let seg = i < buckets.count ? buckets[i] : []
                guard seg.count >= 2 else { slots.append(nil); continue }
                let expected = String(targetLetters[i])
                let r = await letterRecognizer.recognize(
                    points: seg, canvasSize: size, expectedLetter: expected,
                    historicalFormScores: historyByLetter[expected] ?? [])
                slots.append(r)
            }
            guard let self else { return }
            await MainActor.run {
                guard self.recognitionTokens.isStillActive(token) else { return }
                self.freeform.isRecognizing = false
                self.freeform.hasRecognitionCompleted = true
                let present = slots.compactMap { $0 }
                self.freeform.freeformWordResultSlots = slots
                self.freeform.freeformWordResults = present
                if let last = present.last {
                    self.lastRecognitionResult = last
                }
                self.recordFreeformWordCompletion(
                    target: target, results: present)
            }
        }
    }

    private func recordFreeformCompletion(result: RecognitionResult) {
        // Freeform letter sessions record under the predicted letter so
        // the dashboard tallies what the child actually wrote (not what
        // they were trying to write — the latter is nil in freeform).
        let label = result.predictedLetter.uppercased()
        progressStore.recordFreeformCompletion(letter: label, result: result)
        refreshProgressMirror()
    }

    private func recordFreeformWordCompletion(target: FreeformWord,
                                              results: [RecognitionResult]) {
        for r in results {
            let label = r.predictedLetter.uppercased()
            progressStore.recordFreeformCompletion(letter: label, result: r)
        }
        refreshProgressMirror()
    }

    // MARK: - Segmentation

    /// Assign every stroke to one of `letterCount` equal-width columns
    /// by the x-coordinate of its centroid. Works even when the child's
    /// handwriting overlaps horizontally — each stroke is a unit and
    /// ends up in exactly one bucket regardless of what the other
    /// strokes do. Returns an array of length `letterCount`; empty
    /// buckets stay empty (caller pads those as missing letters in the
    /// UI). Strokes whose centroid falls outside the canvas clamp to
    /// the nearest bucket rather than being dropped, so a child who
    /// started writing a bit to the right of the visual guides still
    /// gets their strokes accounted for.
    static func bucketStrokesByTargetLetter(
        points: [CGPoint],
        strokeSizes: [Int],
        canvasWidth: CGFloat,
        letterCount: Int
    ) -> [[CGPoint]] {
        guard letterCount > 0, canvasWidth > 0, !strokeSizes.isEmpty else {
            return Array(repeating: [], count: max(letterCount, 0))
        }
        let bucketWidth = canvasWidth / CGFloat(letterCount)
        var buckets: [[CGPoint]] = Array(repeating: [], count: letterCount)
        var cursor = 0
        for strokeLen in strokeSizes {
            let endIdx = min(cursor + strokeLen, points.count)
            guard endIdx > cursor else { cursor = endIdx; continue }
            let strokePoints = Array(points[cursor..<endIdx])
            cursor = endIdx
            let sumX = strokePoints.reduce(0.0) { $0 + $1.x }
            let centroidX = sumX / CGFloat(strokePoints.count)
            let raw = Int((centroidX / bucketWidth).rounded(.down))
            let idx = min(letterCount - 1, max(0, raw))
            buckets[idx].append(contentsOf: strokePoints)
        }
        return buckets
    }
}
