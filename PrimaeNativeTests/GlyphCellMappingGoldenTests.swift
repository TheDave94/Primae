// GlyphCellMappingGoldenTests.swift
// PrimaeNativeTests
//
// Audit R-105 (a): pins the glyph-rect → cell mapping the SCORED
// checkpoints are projected through. Until now only the font's hash was
// pinned (`ResourceResolutionTests.bundledFontMatchesBakeMeta`), and
// `StrokeGeometryGoldenTests` pins the glyph-bbox-relative strokes.json
// values — but the step between them, where the app turns those values
// into cell fractions after layout, had no exact pin:
//
//   PrimaeLetterRenderer.computeNormalizedGlyphRect   (glyph ink rect as a
//       fraction of the cell: em-height scale, 10 % pad, baseline, centred)
//   StrokeTracker.cellDefinition(from:glyphRect:)     (checkpoints through
//       that rect; radius × glyph HEIGHT, r16 B-2)
//
// exactly the chain `TracingViewModel.reloadStrokeCheckpoints` runs before
// `cell.tracker.load(...)`. `normalizedGlyphRect` returns nil under the test
// host, so this calls the guard-free `computeNormalizedGlyphRect` (the same
// seam `FreeWriteAttemptCheckTests` uses). Strokes come from
// `LetterRepository(weight: .regular)` — injected, never UserDefaults.
//
// WHERE THE LITERALS COME FROM. The rect depends only on font metrics in
// the bundled Primae-Regular.otf (sha pinned in _meta.json): UPM 1024,
// ascent 1000, descent 350 (em height 1350), every study capital's ink
// box y from -6 to 800 units. So, independent of the canvas size,
//     y = 0.1 + 0.8 * (1000 - 800) / 1350 = 0.1 + 3.2/27 = 0.218518518…
//     h = 0.8 * 806 / 1350                              = 0.477629629…
// and x = 0.5 - w/2 with w = inkWidth * 0.8 * H / (1350 * W). The widths
// were read with CoreText from the same .otf on macOS (a standalone
// reimplementation of the formula, not this module) and every value is
// printed below. Cross-check against the field: study-iPad exports on the
// 1270 x 874 canvas carry radius 0.047762962962962965 and I's first
// checkpoint at (0.5105, 0.2376) (`FreeWriteAttemptCheckTests`), which
// these literals reproduce.
//
// A drift failing here means the ghost glyph and the scored checkpoints
// moved for every child: re-derive deliberately, never loosen.

import Testing
import Foundation
import CoreGraphics
@testable import PrimaeNative

@MainActor
@Suite
struct GlyphCellMappingGoldenTests {

    private static let tolerance: CGFloat = 1e-9
    /// The A16 test cell (`R16Geo.canvas`) and the study iPad's exported canvas.
    private static let a16 = CGSize(width: 1084, height: 626)
    private static let studyIPad = CGSize(width: 1270, height: 874)

    /// Canvas-independent: see the header derivation.
    private static let rectY: CGFloat = 0.21851851851851853
    private static let rectH: CGFloat = 0.47762962962962957

    /// (x, width) of the glyph rect per study letter, per canvas.
    private static let rectXW: [(canvas: CGSize, rects: [String: (x: CGFloat, w: CGFloat)])] = [
        (a16, [
            "A": (0.40204045373787073, 0.19591909252425857),
            "F": (0.42402788027880278, 0.15194423944239444),
            "I": (0.47895366953669533, 0.042092660926609266),
            "L": (0.42787781877818776, 0.14424436244362443),
            "M": (0.37303758370917039, 0.25392483258165915),
        ]),
        (studyIPad, [
            "A": (0.38326275882181393, 0.23347448235637211),
            "F": (0.40946491688538933, 0.18107016622922137),
            "I": (0.47491933508311457, 0.050161329833770779),
            "L": (0.41405284339457565, 0.17189431321084866),
            "M": (0.34870037911927676, 0.30259924176144648),
        ]),
    ]

    /// On the A16 cell: per stroke, (first checkpoint, last checkpoint)
    /// after `cellDefinition`, in cell fractions. Computed as
    /// `rect.minX + cp.x * rect.width`, `rect.minY + cp.y * rect.height`
    /// from the literals above and the strokes.json values.
    private static let mappedEnds: [String: [(first: CGPoint, last: CGPoint)]] = [
        "A": [
            (CGPoint(x: 0.41340376110427773, y: 0.6765653333333332), CGPoint(x: 0.5162612846795135, y: 0.23332503703703705)),
            (CGPoint(x: 0.5170449610496105, y: 0.2371460740740741), CGPoint(x: 0.5854207243405768, y: 0.6736995555555555)),
            (CGPoint(x: 0.4580733141998087, y: 0.49936474074074066), CGPoint(x: 0.5583838895722291, y: 0.49936474074074066)),
        ],
        "F": [
            (CGPoint(x: 0.4528972857728577, y: 0.23762370370370373), CGPoint(x: 0.43587953095530957, y: 0.671789037037037)),
            (CGPoint(x: 0.4528972857728577, y: 0.23810133333333333), CGPoint(x: 0.5668554653546536, y: 0.23762370370370373)),
            (CGPoint(x: 0.44681951619516197, y: 0.4477807407407407), CGPoint(x: 0.5425443870438704, y: 0.4477807407407407)),
        ],
        "I": [
            (CGPoint(x: 0.5088394587945879, y: 0.23762370370370373), CGPoint(x: 0.4920023944239442, y: 0.6770429629629628)),
        ],
        "L": [
            (CGPoint(x: 0.4567266912669126, y: 0.2424), CGPoint(x: 0.440859811398114, y: 0.6722666666666666)),
            (CGPoint(x: 0.440859811398114, y: 0.6722666666666666), CGPoint(x: 0.5634675194751947, y: 0.6722666666666666)),
        ],
        "M": [
            (CGPoint(x: 0.38573382533825334, y: 0.675610074074074), CGPoint(x: 0.6140122498291649, y: 0.6727442962962963)),
        ],
    ]
    /// `checkpointRadius (0.1) × rectH` — the tracker's radius in cell heights.
    private static let mappedRadius: CGFloat = 0.04776296296296296

    private static func close(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= tolerance }
    private static func fmt(_ x: CGFloat) -> String { String(format: "%.17g", Double(x)) }

    @Test("the glyph ink rect of each study letter is pinned on the A16 cell and the study iPad canvas")
    func glyphRectIsPinned() throws {
        for (canvas, table) in Self.rectXW {
            for name in TrainedLetterSubset.studyLetters {
                let expected = try #require(table[name], "no literal for \(name)")
                let rect = try #require(PrimaeLetterRenderer.computeNormalizedGlyphRect(for: name, canvasSize: canvas),
                                        "no glyph rect for \(name) — font failed to load?")
                print("R105|rect \(Int(canvas.width))x\(Int(canvas.height)) \(name) x=\(Self.fmt(rect.minX)) y=\(Self.fmt(rect.minY)) w=\(Self.fmt(rect.width)) h=\(Self.fmt(rect.height))")
                #expect(Self.close(rect.minX, expected.x), "\(name) @\(canvas): x \(Self.fmt(rect.minX)) ≠ \(Self.fmt(expected.x))")
                #expect(Self.close(rect.width, expected.w), "\(name) @\(canvas): w \(Self.fmt(rect.width)) ≠ \(Self.fmt(expected.w))")
                #expect(Self.close(rect.minY, Self.rectY), "\(name) @\(canvas): y \(Self.fmt(rect.minY)) ≠ \(Self.fmt(Self.rectY))")
                #expect(Self.close(rect.height, Self.rectH), "\(name) @\(canvas): h \(Self.fmt(rect.height)) ≠ \(Self.fmt(Self.rectH))")
                // Centred horizontally, by construction.
                #expect(Self.close(rect.midX, 0.5), "\(name) @\(canvas): midX \(Self.fmt(rect.midX))")
            }
        }
    }

    @Test("cellDefinition maps the Regular strokes of each study letter to pinned cell fractions and radius")
    func scoredCheckpointsArePinned() throws {
        let letters = LetterRepository(resources: BundleLetterResourceProvider(),
                                       cache: NullLetterCache(), weight: .regular).loadLetters()
        for name in TrainedLetterSubset.studyLetters {
            let asset = try #require(letters.first { $0.name == name }, "study letter \(name) not loaded")
            let rect = try #require(PrimaeLetterRenderer.computeNormalizedGlyphRect(for: name, canvasSize: Self.a16))
            let cell = StrokeTracker.cellDefinition(from: asset.strokes, glyphRect: rect)
            let expected = try #require(Self.mappedEnds[name])

            print("R105|cell \(name) radius=\(Self.fmt(cell.checkpointRadius))")
            #expect(Self.close(cell.checkpointRadius, Self.mappedRadius),
                    "\(name): radius \(Self.fmt(cell.checkpointRadius)) ≠ \(Self.fmt(Self.mappedRadius))")
            #expect(cell.strokes.count == expected.count, "\(name): \(cell.strokes.count) strokes")
            #expect(cell.strokes.map(\.id) == asset.strokes.strokes.map(\.id), "\(name): stroke ids changed")
            #expect(cell.strokes.map(\.checkpoints.count) == asset.strokes.strokes.map(\.checkpoints.count),
                    "\(name): checkpoint counts changed")
            for (i, (stroke, ends)) in zip(cell.strokes, expected).enumerated() {
                let first = try #require(stroke.checkpoints.first)
                let last = try #require(stroke.checkpoints.last)
                print("R105|cell \(name) s\(i) first=(\(Self.fmt(first.x)), \(Self.fmt(first.y))) last=(\(Self.fmt(last.x)), \(Self.fmt(last.y)))")
                #expect(Self.close(first.x, ends.first.x) && Self.close(first.y, ends.first.y),
                        "\(name) s\(i) first (\(Self.fmt(first.x)), \(Self.fmt(first.y))) ≠ \(ends.first)")
                #expect(Self.close(last.x, ends.last.x) && Self.close(last.y, ends.last.y),
                        "\(name) s\(i) last (\(Self.fmt(last.x)), \(Self.fmt(last.y))) ≠ \(ends.last)")
            }
        }
    }
}
