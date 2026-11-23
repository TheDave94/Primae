// SlantFitAngleTests.swift
// PrimaeNativeTests
//
// The r27 shear fit's own surface (`SlantFitTests` pins its effect on the
// deviation; this pins the exported angle and the seam). Fixtures and the
// provenance of the numbers: see `SlantFitTests.swift`.
//
// Measured values (production scorer on macOS, -O): the angle found for the
// upright letters is the reference's own lean to 0.01 degree (I -3.789 vs
// -3.793, F -3.870 vs -3.878, L -3.638 vs -3.643); for the reference sheared
// 25 degrees it is the limit, -15.

import Testing
import CoreGraphics
import Foundation
@testable import PrimaeNative

extension SlantFixtures {
    /// `analyze` with the shear limit set (0 = the pre-r27 fit).
    static func analyze(_ drawn: [[CGPoint]], against ref: LetterStrokes,
                        shearLimitDegrees: CGFloat) -> StrokeProcessMeasures {
        let (points, starts) = flatten(drawn)
        return StrokeProcessScorer.analyze(points: points, strokeStartIndices: starts, reference: ref,
                                           shearLimitDegrees: shearLimitDegrees)!
    }
}

@MainActor
@Suite struct SlantFitAngleTests {

    private static func leanDegrees(_ ref: LetterStrokes) -> Double {
        atan(Double(SlantFixtures.lean(ref))) * 180 / Double.pi
    }

    @Test("r27: the exported shear of an upright letter is the font's own lean, found to 0.2 degree",
          arguments: ["I", "F", "L"])
    func exportedAngleIsTheLean(letter: String) {
        let ref = SlantFixtures.reference(letter)
        let m = SlantFixtures.analyze(SlantFixtures.upright(ref), against: ref)
        #expect(abs(Double(m.spatialFitShearDegrees) - Self.leanDegrees(ref)) < 0.2,
                "\(letter): fitted \(m.spatialFitShearDegrees) deg, lean \(Self.leanDegrees(ref)) deg")
    }

    @Test("r27: the shear limit 0 is the pre-r27 fit — the upright letter is charged the lean, and no angle is applied",
          arguments: ["I", "F", "L"])
    func limitZeroIsThePreR27Fit(letter: String) {
        let ref = SlantFixtures.reference(letter)
        let drawn = SlantFixtures.upright(ref)
        let before = SlantFixtures.analyze(drawn, against: ref, shearLimitDegrees: 0)
        let after = SlantFixtures.analyze(drawn, against: ref)
        #expect(before.spatialFitShearDegrees == 0)
        // 0.015: the lowest measured pre-r27 value is F's 0.0209.
        #expect(before.spatialDeviation > 0.015, "\(letter) pre-r27: \(before.spatialDeviation)")
        #expect(after.spatialDeviation < before.spatialDeviation / 10)
        #expect(before.spatialDeviationRaw == after.spatialDeviationRaw, "the unfitted secondary must not move")
    }

    @Test("r27: the exact reference needs no shear, and the angle never leaves +-15", arguments: ["I", "F", "L"])
    func angleStaysInsideTheLimit(letter: String) {
        let ref = SlantFixtures.reference(letter)
        let exact = SlantFixtures.analyze(SlantFixtures.strokes(ref), against: ref)
        #expect(abs(exact.spatialFitShearDegrees) < 0.2, "\(letter) exact: \(exact.spatialFitShearDegrees)")
        for degrees in [25.0, -25.0, 60.0] {
            let m = SlantFixtures.analyze(
                SlantFixtures.sheared(SlantFixtures.strokes(ref), tangent: SlantFixtures.tangent(degrees: degrees)),
                against: ref)
            #expect(abs(m.spatialFitShearDegrees) <= StrokeProcessScorer.shearLimitDegrees,
                    "\(letter) sheared \(degrees): angle \(m.spatialFitShearDegrees)")
        }
        // Past the limit the search stops AT the limit, on the side that helps.
        let over = SlantFixtures.analyze(
            SlantFixtures.sheared(SlantFixtures.strokes(ref), tangent: SlantFixtures.tangent(degrees: 25)), against: ref)
        #expect(over.spatialFitShearDegrees == -StrokeProcessScorer.shearLimitDegrees,
                "\(letter): \(over.spatialFitShearDegrees)")
    }

    @Test("r27: a shear can only lower the deviation, never raise it (the pre-r27 fit is one of the candidates)",
          arguments: ["I", "F", "L"])
    func theShearNeverWorsensTheDeviation(letter: String) {
        let ref = SlantFixtures.reference(letter)
        let base = SlantFixtures.strokes(ref)
        for degrees in [0.0, 6.0, -12.0, 25.0] {
            let drawn = SlantFixtures.sheared(base, tangent: SlantFixtures.tangent(degrees: degrees))
            let before = SlantFixtures.analyze(drawn, against: ref, shearLimitDegrees: 0)
            let after = SlantFixtures.analyze(drawn, against: ref)
            #expect(after.spatialDeviation <= before.spatialDeviation,
                    "\(letter) sheared \(degrees): \(before.spatialDeviation) -> \(after.spatialDeviation)")
        }
    }

    @Test("r27: the search is deterministic — the same drawing gives the same angle, bit for bit")
    func theSearchIsDeterministic() {
        let ref = SlantFixtures.reference("F")
        let drawn = SlantFixtures.sheared(SlantFixtures.strokes(ref), tangent: SlantFixtures.tangent(degrees: 7))
        let a = SlantFixtures.analyze(drawn, against: ref)
        let b = SlantFixtures.analyze(drawn, against: ref)
        #expect(a == b)
    }
}
