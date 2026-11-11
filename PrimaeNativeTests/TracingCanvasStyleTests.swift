// TracingCanvasStyleTests.swift
//
// Pins the guide marks of the child's tracing screen as decided in
// protocol revision 23 (design audit 2026-11-10, docs/DECISIONS.md r23).
// The Canvas draw closure cannot be called from a test (CLAUDE.md, Test
// Infrastructure 3), so the decisions live in `TracingCanvasStyle` as
// values and are read here. The contrast checks use the WCAG 2 formula
// against the glyph and paper colours measured on the study iPad.

import Testing
import CoreGraphics
import Foundation
@testable import PrimaeNative

@Suite struct TracingCanvasStyleTests {

    /// Reference glyph and paper as measured on the study iPad.
    static let glyph: UInt32 = 0x424958
    static let paper: UInt32 = 0xF8FAFC
    static let white: UInt32 = 0xFFFFFF

    static func luminance(_ hex: UInt32) -> Double {
        func channel(_ v: UInt32) -> Double {
            let c = Double(v & 0xFF) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(hex >> 16) + 0.7152 * channel(hex >> 8) + 0.0722 * channel(hex)
    }

    static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    @Test("the ghost line stands out on the glyph (3 to 1 for a graphic; r22 was 1.17)")
    func ghostLineContrast() {
        #expect(Self.contrast(TracingCanvasStyle.ghostHex, Self.glyph) >= 3.0)
        #expect(TracingCanvasStyle.ghostLineWidth == 6)
    }

    @Test("the ink has a paper-coloured casing on each side")
    func inkCasing() {
        #expect(TracingCanvasStyle.inkCasingPerSide == 3)
    }

    @Test("a finished stroke reads as done even when it is also the active index")
    func startDotPrecedence() {
        #expect(TracingCanvasStyle.startDotState(isComplete: true, isActive: true) == .done)
        #expect(TracingCanvasStyle.startDotState(isComplete: true, isActive: false) == .done)
        #expect(TracingCanvasStyle.startDotState(isComplete: false, isActive: true) == .active)
        #expect(TracingCanvasStyle.startDotState(isComplete: false, isActive: false) == .pending)
    }

    @Test("the three start-dot states differ in form, not by colour alone")
    func startDotStatesDifferInForm() {
        let done = TracingCanvasStyle.startDot(isComplete: true, isActive: false)
        let active = TracingCanvasStyle.startDot(isComplete: false, isActive: true)
        let pending = TracingCanvasStyle.startDot(isComplete: false, isActive: false)
        #expect(done.showsTick)
        #expect(!active.showsTick && !pending.showsTick)
        #expect(active.radius > pending.radius, "active is the larger dot")
        #expect(Set([done.fillHex, active.fillHex, pending.fillHex]).count == 3)
    }

    @Test("every start dot has a paper outline that stands out on the glyph")
    func startDotOutline() {
        for (c, a) in [(true, false), (false, true), (false, false), (true, true)] {
            let dot = TracingCanvasStyle.startDot(isComplete: c, isActive: a)
            #expect(dot.outlineWidth >= 2)
        }
        #expect(Self.contrast(Self.paper, Self.glyph) >= 3.0)
    }

    @Test("phase dots: the filled dot and the pending ring reach 3 to 1 on white")
    func phaseDots() {
        #expect(TracingCanvasStyle.phaseDotSize == 12)
        #expect(Self.contrast(TracingCanvasStyle.phaseDotFillHex, Self.white) >= 3.0)
        #expect(Self.contrast(TracingCanvasStyle.phaseDotPendingHex, Self.white) >= 3.0)
        #expect(TracingCanvasStyle.phaseDotPendingLineWidth >= 2)
    }

    @Test("the child's screen hides the status bar")
    func statusBarHidden() {
        #expect(TracingCanvasStyle.childScreenHidesStatusBar)
    }
}
