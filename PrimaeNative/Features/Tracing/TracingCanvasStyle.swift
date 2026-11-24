// TracingCanvasStyle.swift
// PrimaeNative
//
// What the child's tracing screen draws for its guide marks: the ghost
// line, the stroke start dots, the casing under the ink and the phase
// dots (protocol revision 23, design audit 2026-11-10, docs/DECISIONS.md
// r23). Kept as VALUES, not draw calls, so the tests can read them: a
// Canvas's draw closure cannot be called from a test (CLAUDE.md, Test
// Infrastructure 3).
//
// The contrast figures are against the reference glyph (#424958) and the
// paper (#F8FAFC) as measured on the study iPad. Each value was chosen by
// rendering it in the running app on that iPad (candidate "B" on the r23
// design canvas), not from a mock-up.

import CoreGraphics

nonisolated enum TracingCanvasStyle {

    // MARK: Ghost line (audit finding 4)

    /// Light blue, solid. 5.0 to 1 on the glyph; r22 drew the line dark
    /// blue at 35 % opacity (#38518C on the glyph), 1.17 to 1.
    static let ghostHex: UInt32 = 0x93C5FD
    static let ghostLineWidth: CGFloat = 6

    /// How the ghost line is stroked, as ONE value the canvas is handed
    /// (`TracingViewModel.CanvasDrawPlan.ghost`) and replays without a
    /// literal of its own. `opacity` is 1: the line is solid (r22 drew it
    /// at 35 % opacity).
    struct GhostStroke: Equatable {
        let hex: UInt32
        let opacity: Double
        let width: CGFloat
    }

    static let ghostStroke = GhostStroke(hex: ghostHex, opacity: 1, width: ghostLineWidth)

    // MARK: Ink (audit finding 10)

    /// A paper-coloured casing drawn under every ink stroke, this wide on
    /// each side. The ink colour itself is unchanged (2.40 to 1 on the
    /// glyph); the casing gives the stroke an edge of 8.6 to 1 against
    /// the glyph. On the paper the casing is invisible (same colour).
    static let inkCasingPerSide: CGFloat = 3

    // MARK: Ink widths (ROADMAP D9 question 1, decided 2026-11-24)

    /// Ink widths are ABSOLUTE, in points, not scaled to the canvas or the
    /// letter (`docs/BAKE_INVARIANTS.md` §5.3: a pen leaves a mark of
    /// the same width whatever size the child writes; the study runs on one
    /// iPad model, where 1 pt = 0.19 mm). The device switch is HARD and per
    /// stroke: a stroke has one device for its whole life, fixed at
    /// touch-down (`TouchDispatcher`, D9 question 2), so a crossfade would
    /// have nothing to blend. Values unchanged from r27; see
    /// `docs/DECISIONS.md`, "Renderer architecture (ROADMAP D9)".
    ///
    /// Finger: 14 pt (2.7 mm), no pressure.
    static let fingerInkWidth: CGFloat = 14
    /// Pencil: 8 pt + 14 pt x normalised force, 8-22 pt (1.5-4.2 mm).
    static let pencilInkBaseWidth: CGFloat = 8
    static let pencilInkPressureGain: CGFloat = 14
    /// Ink kept on a finished cell of a multi-cell layout.
    static let retainedInkWidth: CGFloat = 12
    /// The just-finished trace held on screen after a phase transition.
    static let lingeringInkWidth: CGFloat = 14

    /// Every ink width the canvas strokes, as ONE value it is handed
    /// (`TracingViewModel.CanvasDrawPlan.ink`) and replays without a
    /// literal of its own (CLAUDE.md, Test Infrastructure 3).
    struct InkWidths: Equatable {
        /// The stroke under the pen now: finger width, or the Pencil's
        /// pressure width.
        let live: CGFloat
        /// Free-writing strokes already lifted (single-cell study layout).
        /// Finger width whatever device drew them: what stays on screen is
        /// the record the scorer reads, not the pressure trace.
        let completedFreeWrite: CGFloat
        let retained: CGFloat
        let lingering: CGFloat
    }

    /// Finger width without a pressure; the Pencil's pressure width with one.
    static func inkWidth(forPressure pressure: CGFloat?) -> CGFloat {
        pressure.map { pencilInkBaseWidth + $0 * pencilInkPressureGain } ?? fingerInkWidth
    }

    static func inkWidths(livePressure: CGFloat?) -> InkWidths {
        InkWidths(live: inkWidth(forPressure: livePressure),
                  completedFreeWrite: inkWidth(forPressure: nil),
                  retained: retainedInkWidth,
                  lingering: lingeringInkWidth)
    }

    // MARK: Stroke start dots (audit finding 6)

    enum StartDotState: Equatable {
        case done, active, pending
    }

    struct StartDot: Equatable {
        let radius: CGFloat
        let fillHex: UInt32
        /// Paper-coloured ring around the fill (8.6 to 1 on the glyph).
        let outlineWidth: CGFloat
        /// A white tick on the fill: a finished stroke differs in FORM,
        /// not by colour alone.
        let showsTick: Bool
    }

    /// Same precedence as r22: a finished stroke reads as done even when
    /// it is also the active index.
    static func startDotState(isComplete: Bool, isActive: Bool) -> StartDotState {
        if isComplete { return .done }
        return isActive ? .active : .pending
    }

    /// Radius follows `isActive` (as in r22: 18 pt active, 14 pt else);
    /// fill and tick follow the state. Opaque (r22: 75 % opacity).
    static func startDot(isComplete: Bool, isActive: Bool) -> StartDot {
        let state = startDotState(isComplete: isComplete, isActive: isActive)
        let fill: UInt32
        switch state {
        case .done: fill = 0x16A34A
        case .active: fill = 0x2563EB
        case .pending: fill = 0x94A3B8
        }
        return StartDot(radius: isActive ? 18 : 14,
                        fillHex: fill,
                        outlineWidth: 3,
                        showsTick: state == .done)
    }

    // MARK: Phase dots (audit finding 7)

    /// 12 pt (r22: 10). Current and finished phases in brand blue, 5.17 to
    /// 1 on white (r22: 3.62); the pending ring #64748B, 2 pt, 4.76 to 1
    /// (r22: 1.74). The current dot's pulse stops under Reduce Motion.
    static let phaseDotSize: CGFloat = 12
    static let phaseDotFillHex: UInt32 = 0x2563EB
    static let phaseDotPendingHex: UInt32 = 0x64748B
    static let phaseDotPendingLineWidth: CGFloat = 2

    /// Scale of the current phase dot at the small and the enlarged end of
    /// its pulse (`PhaseDotPulse.scale`).
    static let phaseDotRestScale: CGFloat = 1.0
    static let phaseDotPulseScale: CGFloat = 1.18

    // MARK: Status bar (audit finding 11)

    /// The clock, date and battery are hidden on the child's screen.
    static let childScreenHidesStatusBar = true
}
