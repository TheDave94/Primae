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

    // MARK: Ink (audit finding 10)

    /// A paper-coloured casing drawn under every ink stroke, this wide on
    /// each side. The ink colour itself is unchanged (2.40 to 1 on the
    /// glyph); the casing gives the stroke an edge of 8.6 to 1 against
    /// the glyph. On the paper the casing is invisible (same colour).
    static let inkCasingPerSide: CGFloat = 3

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

    // MARK: Status bar (audit finding 11)

    /// The clock, date and battery are hidden on the child's screen.
    static let childScreenHidesStatusBar = true
}
