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
import SwiftUI
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

// MARK: - What the canvas is handed (T1.2, audit F2)
//
// The tests above pin `TracingCanvasStyle`'s constants. These pin the VALUES
// the draw closure replays — `CanvasDrawPlan.ghost` and
// `TracingCanvasView.inkDrawOps` — so a view that drew its own literal (a
// hard-coded ghost opacity, a dropped casing) is no longer green.

@MainActor
@Suite struct CanvasDrawnStyleTests {

    private func studyVM() -> TracingViewModel {
        var deps = TracingDependencies.stub
        deps.studyMode = true
        let vm = TracingViewModel(deps)
        vm.canvasSize = CGSize(width: 400, height: 400)
        return vm
    }

    @Test("the ghost line the canvas strokes is the solid r23 style, in every phase")
    func ghostStrokeIsTheStyle() {
        let vm = studyVM()
        for phase in LearningPhase.allCases {
            vm.phaseController.resume(at: phase)
            #expect(vm.canvasDrawPlan.ghost.hex == TracingCanvasStyle.ghostHex, "\(phase)")
            #expect(vm.canvasDrawPlan.ghost.width == TracingCanvasStyle.ghostLineWidth, "\(phase)")
            #expect(vm.canvasDrawPlan.ghost.opacity == 1, "\(phase): solid, not r22's 35 % blue")
        }
    }

    private func layers() -> [TracingCanvasView.InkLayer] {
        var a = Path(); a.move(to: .zero); a.addLine(to: CGPoint(x: 10, y: 0))
        var b = Path(); b.move(to: .zero); b.addLine(to: CGPoint(x: 0, y: 10))
        return [.init(path: a, color: .black, width: 10), .init(path: b, color: .black, width: 14)]
    }

    @Test("the ink is drawn over a casing of its width plus the casing on each side, every casing first")
    func inkIsCased() {
        let ops = TracingCanvasView.inkDrawOps(layers())
        #expect(ops.map(\.kind) == [.casing, .casing, .ink, .ink])
        let side = TracingCanvasStyle.inkCasingPerSide
        #expect(ops.map(\.width) == [10 + 2 * side, 14 + 2 * side, 10, 14])
        #expect(ops.prefix(2).allSatisfy { $0.color == .canvasPaper }, "the casing is paper-coloured")
    }

    @Test("no layers, no strokes")
    func noLayersNoOps() {
        #expect(TracingCanvasView.inkDrawOps([]).isEmpty)
    }
}

// MARK: - The phase dot's pulse (T1.2, audit F3)

@Suite struct PhaseDotPulseTests {

    @Test("on appear: the pulse starts animated unless Reduce Motion is on, then the dot settles enlarged")
    func appearing() {
        #expect(PhaseDotPulse.step(reduceMotion: false, appearing: true)
                == .init(target: true, animated: true))
        #expect(PhaseDotPulse.step(reduceMotion: true, appearing: true)
                == .init(target: true, animated: false))
    }

    @Test("Reduce Motion switched on while shown: stop, settled enlarged; switched off: resume from enlarged")
    func changingWhileShown() {
        #expect(PhaseDotPulse.step(reduceMotion: true, appearing: false)
                == .init(target: true, animated: false))
        #expect(PhaseDotPulse.step(reduceMotion: false, appearing: false)
                == .init(target: false, animated: true))
    }

    @Test("under Reduce Motion no step animates, appearing or not")
    func reduceMotionNeverAnimates() {
        for appearing in [true, false] {
            #expect(!PhaseDotPulse.step(reduceMotion: true, appearing: appearing).animated)
        }
    }

    @Test("only the current dot scales, and only while the pulse flag is set")
    func scale() {
        #expect(PhaseDotPulse.scale(isCurrent: true, pulse: true) == TracingCanvasStyle.phaseDotPulseScale)
        #expect(PhaseDotPulse.scale(isCurrent: true, pulse: false) == TracingCanvasStyle.phaseDotRestScale)
        #expect(PhaseDotPulse.scale(isCurrent: false, pulse: true) == TracingCanvasStyle.phaseDotRestScale)
        #expect(PhaseDotPulse.scale(isCurrent: false, pulse: false) == TracingCanvasStyle.phaseDotRestScale)
        #expect(TracingCanvasStyle.phaseDotPulseScale == 1.18 && TracingCanvasStyle.phaseDotRestScale == 1.0)
    }
}
