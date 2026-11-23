// SlantFitTests.swift
// PrimaeNativeTests
//
// Protocol r27, "Slant is not an error" (David, 2026-11-23: "the font letter
// for I is slightly tilted but the children will most likely draw it vertical
// ... I don't want this to be punished"). The primary `spatialDeviation` now
// fits a horizontal shear within +-15 degrees (besides translate + uniform
// scale) before the distance is measured. These suites pin what that must do
// and what it must NOT forgive.
//
// THE FRAME. The scorer sees the reference in canvas HEIGHTS on both axes
// (`StrokeProcessScorer.heightNormalised`), i.e. with the glyph's true
// proportions, so a stroke's lean in that frame is its real angle (about
// 3.6-3.9 degrees for I, F and L). The bundled strokes.json is per-axis
// glyph-bbox fractions, so the tests rescale x by width/height of the glyph
// (CoreText bbox of Primae-Regular.otf, height 787 units; widths F 433,
// I 120, L 410 — the figures DECISIONS r27 records) to get that frame. In the
// raw JSON frame the I would lean 23.5 degrees, beyond the limit, and the
// tests would be about a different letter.
//
// WHERE THE NUMBERS COME FROM (no device run in the authoring lane): the
// production StrokeProcessMeasures.swift + FreeWriteScorer.swift + Models.swift
// compiled unchanged into a macOS command-line tool, at -O. Measured values,
// deviation after the shear (`post`) against before it (`pre`, shear limit 0):
//   upright (the reference de-sheared by its own lean):
//     I pre 0.0321 post 0.000056 | F pre 0.0209 post 0.00036 | L pre 0.0294 post 0.000081
//   the reference sheared 10 degrees:  post <= 0.00036 for I, F, L
//   the reference sheared 25 degrees:  post I 0.091, F 0.079, L 0.136 (negative: F 0.131, L 0.089)
//   stretched x1.6: F 0.103, L 0.169 | upside down: F 0.323, L 0.451
//   mirrored: F 0.138, L 0.221 | rotated 30 degrees: F 0.240, L 0.221
// The thresholds below sit well inside those, and say where.

import Testing
import CoreGraphics
import Foundation
@testable import PrimaeNative

@MainActor
enum SlantFixtures {
    /// CoreText bbox of `Primae-Regular.otf` (DECISIONS r27): glyph height and widths.
    static let glyphHeight: CGFloat = 787
    static let glyphWidth: [String: CGFloat] = ["F": 433, "I": 120, "L": 410]

    private static let bundled: [String: LetterStrokes] = {
        let letters = LetterRepository(resources: BundleLetterResourceProvider(),
                                       cache: NullLetterCache(), weight: .regular).loadLetters()
        var out: [String: LetterStrokes] = [:]
        for name in glyphWidth.keys { out[name] = letters.first { $0.name == name }?.strokes }
        return out
    }()

    /// The reference as the scorer sees it: x rescaled to glyph heights.
    static func reference(_ letter: String) -> LetterStrokes {
        let raw = bundled[letter]!
        let aspect = glyphWidth[letter]! / glyphHeight
        return LetterStrokes(letter: raw.letter, checkpointRadius: raw.checkpointRadius,
                             strokes: raw.strokes.map { s in
            StrokeDefinition(id: s.id, checkpoints: s.checkpoints.map { Checkpoint(x: $0.x * aspect, y: $0.y) })
        })
    }

    static func strokes(_ ref: LetterStrokes) -> [[CGPoint]] {
        ref.strokes.map { $0.checkpoints.map { CGPoint(x: $0.x, y: $0.y) } }
    }

    /// dx/dy of the reference's first stroke, start to end: its lean as a tangent.
    static func lean(_ ref: LetterStrokes) -> CGFloat {
        let c = ref.strokes[0].checkpoints
        return (c.last!.x - c.first!.x) / (c.last!.y - c.first!.y)
    }

    /// x' = x + tangent * (y - cy), cy the strokes' bounding-box centre.
    static func sheared(_ strokes: [[CGPoint]], tangent: CGFloat) -> [[CGPoint]] {
        let ys = strokes.joined().map(\.y)
        let cy = (ys.min()! + ys.max()!) / 2
        return strokes.map { $0.map { CGPoint(x: $0.x + tangent * ($0.y - cy), y: $0.y) } }
    }

    static func tangent(degrees: Double) -> CGFloat { CGFloat(tan(degrees * Double.pi / 180)) }

    /// The reference drawn exactly upright: de-sheared by its own lean.
    static func upright(_ ref: LetterStrokes) -> [[CGPoint]] { sheared(strokes(ref), tangent: -lean(ref)) }

    static func analyze(_ drawn: [[CGPoint]], against ref: LetterStrokes) -> StrokeProcessMeasures {
        let (points, starts) = flatten(drawn)
        return StrokeProcessScorer.analyze(points: points, strokeStartIndices: starts, reference: ref)!
    }

    static func flatten(_ drawn: [[CGPoint]]) -> ([CGPoint], [Int]) {
        var points: [CGPoint] = [], starts: [Int] = []
        for (i, s) in drawn.enumerated() { if i > 0 { starts.append(points.count) }; points += s }
        return (points, starts)
    }
}

@MainActor
@Suite struct SlantFitTests {

    /// 5x the largest residual measured on an exactly-upright letter (F, 0.00036).
    private static let uprightEpsilon: CGFloat = 0.002

    @Test("r27: a letter drawn exactly upright scores near 0, not the font's lean as error", arguments: ["I", "F", "L"])
    func uprightLetterIsNotCharged(letter: String) {
        let ref = SlantFixtures.reference(letter)
        let m = SlantFixtures.analyze(SlantFixtures.upright(ref), against: ref)
        #expect(m.spatialDeviation < Self.uprightEpsilon,
                "\(letter) drawn upright: \(m.spatialDeviation) (before r27 this was 0.02-0.03)")
        #expect(m.matchedReferenceOrder == Array(0..<ref.strokes.count).map { Optional($0) })
    }

    @Test("r27: a slant of 10 degrees either way is forgiven; 25 degrees is NOT fully forgiven",
          arguments: ["I", "F", "L"])
    func slantIsForgivenOnlyWithinTheLimit(letter: String) {
        let ref = SlantFixtures.reference(letter)
        let base = SlantFixtures.strokes(ref)
        for sign in [1.0, -1.0] {
            let ten = SlantFixtures.analyze(
                SlantFixtures.sheared(base, tangent: SlantFixtures.tangent(degrees: 10 * sign)), against: ref)
            let twentyFive = SlantFixtures.analyze(
                SlantFixtures.sheared(base, tangent: SlantFixtures.tangent(degrees: 25 * sign)), against: ref)
            #expect(ten.spatialDeviation < Self.uprightEpsilon,
                    "\(letter) sheared \(10 * sign) deg: \(ten.spatialDeviation)")
            // 0.05: the lowest measured (I, 0.091; F 0.079; L 0.089) with margin.
            #expect(twentyFive.spatialDeviation > 0.05,
                    "\(letter) sheared \(25 * sign) deg was forgiven: \(twentyFive.spatialDeviation)")
            #expect(twentyFive.spatialDeviation > 20 * ten.spatialDeviation)
        }
    }

    // MARK: - What the shear must NOT forgive (negative controls: also true before r27)

    @Test("r27: a stretched L, an upside-down F or L, a mirrored F or L and a fallen-over (30 degree) F or L still deviate")
    func stretchMirrorFlipAndRotationStayErrors() {
        for letter in ["F", "L"] {
            let ref = SlantFixtures.reference(letter)
            let base = SlantFixtures.strokes(ref)
            let all = Array(base.joined())
            let xs = all.map(\.x), ys = all.map(\.y)
            let minX = xs.min()!, cx = (xs.min()! + xs.max()!) / 2, cy = (ys.min()! + ys.max()!) / 2

            let flipped = base.map { $0.map { CGPoint(x: $0.x, y: 2 * cy - $0.y) } }
            #expect(SlantFixtures.analyze(flipped, against: ref).spatialDeviation > 0.2, "\(letter) upside down")

            let mirrored = base.map { $0.map { CGPoint(x: 2 * cx - $0.x, y: $0.y) } }
            #expect(SlantFixtures.analyze(mirrored, against: ref).spatialDeviation > 0.1, "\(letter) mirrored")

            let a = 30.0 * Double.pi / 180
            let fallen = base.map { $0.map { p in
                CGPoint(x: cx + (p.x - cx) * CGFloat(cos(a)) - (p.y - cy) * CGFloat(sin(a)),
                        y: cy + (p.x - cx) * CGFloat(sin(a)) + (p.y - cy) * CGFloat(cos(a)))
            } }
            #expect(SlantFixtures.analyze(fallen, against: ref).spatialDeviation > 0.15, "\(letter) rotated 30 degrees")

            if letter == "L" {
                let stretched = base.map { $0.map { CGPoint(x: minX + ($0.x - minX) * 1.6, y: $0.y) } }
                #expect(SlantFixtures.analyze(stretched, against: ref).spatialDeviation > 0.1, "L stretched")
            }
        }
    }
}
