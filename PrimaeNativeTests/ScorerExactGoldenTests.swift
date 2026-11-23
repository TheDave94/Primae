// ScorerExactGoldenTests.swift
// PrimaeNativeTests
//
// Audit R-105 (b): exact-value goldens for the free-write scorer. The
// existing suites (`FreeWriteScorerTests`, `StrokeProcessMeasuresTests`,
// `ScoringR16Tests`) pin PROPERTIES — "above 0.9", "same as forward",
// "monotone in jitter" — so a change that moves every score by a constant
// factor, or re-weights the fit, passes them all. These pin the numbers.
//
// Inputs: fixed literal traces (`ScorerGoldenCases`) against the REAL
// bundled Regular references for L, A, I and M (loaded through
// `LetterRepository(weight: .regular)`, never UserDefaults), in the
// reference's own glyph-bbox frame (checkpointRadius 0.1, so Form's
// tolerance is 0.3). No timestamps and no forces, so the assessment's
// other dimensions are fixed: tempo 1, pressure 1, rhythm 0, and
// overall = 0.4 * form + 0.4.
//
// Also covers the audit's F1-01 (stroke segmentation: L in one stroke, A's
// legs as one Λ stroke, M in four strokes) and F1-02 (bounding-box fit: I
// with 6° extra slant, a stray 2-sample contact, a dropped stroke) cases,
// at today's (r16) numbers. These goldens record current behaviour, not a
// ruling that it is right: R-012 / R-013 are open. A deliberate scoring
// change re-derives them; it must not loosen them.
//
// WHERE THE LITERALS COME FROM (no test run was available to the author):
//   DERIVED analytically —
//     • offset raw = |(0.2, -0.1)| = sqrt(0.05) (a translated copy keeps
//       every coupling at the offset);
//     • L one-stroke raw = 0.94 - 0.09 = 0.85 (the drawn L's end must
//       couple to the vertical's end, (0.94,0.95) to (0.09,0.95));
//     • form = max(0, 1 - dev / 0.3), overall = 0.4 * form + 0.4;
//     • scaled / offset primary == identity primary (r6 fit invariance).
//   COMPUTED by compiling the production FreeWriteScorer.swift and
//   StrokeProcessMeasures.swift (plus these cases) unchanged into a macOS
//   command-line tool, at -O and -Onone (bit-identical): every other value.
//   Those are snapshots of the code at 6729b4de, flagged per case below.
// Every value is printed with the prefix "R105|".

import Testing
import Foundation
import CoreGraphics
@testable import PrimaeNative

@MainActor
@Suite
struct ScorerExactGoldenTests {

    private static let tolerance: CGFloat = 1e-9

    private static let refs: [String: LetterStrokes] = {
        let letters = LetterRepository(resources: BundleLetterResourceProvider(),
                                       cache: NullLetterCache(), weight: .regular).loadLetters()
        var out: [String: LetterStrokes] = [:]
        for name in ["L", "A", "I", "M"] { out[name] = letters.first { $0.name == name }?.strokes }
        return out
    }()

    private struct Golden {
        let dev: CGFloat          // spatialDeviation (primary, after the r6 fit)
        let raw: CGFloat          // spatialDeviationRaw (no fit)
        let strokeCount: Int
        let order: String         // matchedReferenceOrderField
        let reversed: Int
        let form: CGFloat         // WritingAssessment.formAccuracy
    }

    private static func fmt(_ x: CGFloat) -> String { String(format: "%.17g", Double(x)) }
    private static func close(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= tolerance }

    /// Scores `trace` both ways the app does (`analyze` for the recorded
    /// measures, `score` for the assessment) and checks every field.
    private func check(_ label: String, _ letter: String,
                       _ make: (LetterStrokes) -> ScorerGoldenTrace,
                       _ g: Golden, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let ref = try #require(Self.refs[letter], "reference \(letter) not loaded", sourceLocation: sourceLocation)
        #expect(ref.checkpointRadius == 0.1, "\(letter): radius \(ref.checkpointRadius)", sourceLocation: sourceLocation)
        let t = make(ref)
        let m = try #require(StrokeProcessScorer.analyze(points: t.points, strokeStartIndices: t.strokeStartIndices,
                                                         reference: ref),
                             "\(label): analyze returned nil", sourceLocation: sourceLocation)
        let a = FreeWriteScorer.score(tracedPoints: t.points, strokeStartIndices: t.strokeStartIndices, reference: ref)
        print("R105|\(label) dev=\(Self.fmt(m.spatialDeviation)) raw=\(Self.fmt(m.spatialDeviationRaw)) n=\(m.strokeCount) order=\(m.matchedReferenceOrderField) rev=\(m.reversedStrokeCount) form=\(Self.fmt(a.formAccuracy)) overall=\(Self.fmt(a.overallScore))")

        #expect(Self.close(m.spatialDeviation, g.dev),
                "\(label): spatialDeviation \(Self.fmt(m.spatialDeviation)) ≠ \(Self.fmt(g.dev))", sourceLocation: sourceLocation)
        #expect(Self.close(m.spatialDeviationRaw, g.raw),
                "\(label): spatialDeviationRaw \(Self.fmt(m.spatialDeviationRaw)) ≠ \(Self.fmt(g.raw))", sourceLocation: sourceLocation)
        #expect(m.strokeCount == g.strokeCount, "\(label): strokeCount \(m.strokeCount)", sourceLocation: sourceLocation)
        #expect(m.matchedReferenceOrderField == g.order,
                "\(label): order \(m.matchedReferenceOrderField) ≠ \(g.order)", sourceLocation: sourceLocation)
        #expect(m.reversedStrokeCount == g.reversed, "\(label): reversed \(m.reversedStrokeCount)", sourceLocation: sourceLocation)
        #expect(Self.close(a.formAccuracy, g.form),
                "\(label): formAccuracy \(Self.fmt(a.formAccuracy)) ≠ \(Self.fmt(g.form))", sourceLocation: sourceLocation)
        // Analytic relations, independent of the snapshot.
        #expect(Self.close(a.formAccuracy, max(0, 1 - m.spatialDeviation / 0.3)),
                "\(label): form is not 1 - dev/0.3", sourceLocation: sourceLocation)
        #expect(a.tempoConsistency == 1 && a.pressureControl == 1 && a.rhythmScore == 0,
                "\(label): untimed dimensions moved", sourceLocation: sourceLocation)
        #expect(Self.close(a.overallScore, 0.4 * g.form + 0.4),
                "\(label): overall \(Self.fmt(a.overallScore))", sourceLocation: sourceLocation)
    }

    /// sqrt(0.2² + 0.1²): the offset every case below moves the letter by.
    private static let offsetRaw: CGFloat = 0.22360679774997896

    // MARK: L (two strokes)

    @Test("L: the reference, an offset copy and a half-size copy score the same primary; raw pays for place and size")
    func letterL() throws {
        // identity: snapshot
        let id = Golden(dev: 0.00011388017110678483, raw: 0.00011388017110678483, strokeCount: 2,
                        order: "0,1", reversed: 0, form: 0.99962039942964409)
        try check("L.identity", "L", ScorerGoldenCases.identity, id)
        // offset: primary = identity (derived), raw = sqrt(0.05) (derived)
        try check("L.offset", "L", { ScorerGoldenCases.offset($0) },
                  Golden(dev: id.dev, raw: Self.offsetRaw, strokeCount: 2, order: "0,1", reversed: 0, form: id.form))
        // scaled: primary = identity (derived), raw snapshot
        try check("L.scaled", "L", { ScorerGoldenCases.scaled($0) },
                  Golden(dev: id.dev, raw: 0.57267603947176049, strokeCount: 2, order: "0,1", reversed: 0, form: id.form))
    }

    @Test("L: the horizontal stroke missing — the fit stretches the vertical onto the whole L's box (snapshot)")
    func letterLMissingStroke() throws {
        // dev / raw snapshot; form = 0 since 0.37 > 0.3 (derived from dev).
        try check("L.missing1", "L", { ScorerGoldenCases.missing($0, stroke: 1) },
                  Golden(dev: 0.37000000000000005, raw: 0.00022776034221345864, strokeCount: 1,
                         order: "0", reversed: 0, form: 0))
    }

    @Test("F1-01: an exact L drawn in ONE stroke scores Form 0 (segmentation dependence)")
    func letterLOneStroke() throws {
        // raw = 0.85 (derived); dev snapshot, r27 value (the shear fit lowers it
        // from 0.84974219514042704, and it stays far above the 0.3 form cut).
        // order: ONE drawn stroke against TWO reference strokes is paired with
        // whichever reference stroke is cheaper UNDER THE FIT, and the merged L
        // is about equally far (0.85) from the vertical (0) and the horizontal
        // (1) one. Before r27 the vertical was cheaper ("0", dev 0.8497); with
        // the +-15 degree shear in the fit the horizontal is (dev 0.8398), so
        // the pairing is "1". The field is a consequence of the fit, not an
        // independent claim about the letter: measured on the iPad
        // (R105|L.oneStroke ... order=1), the one place it is pinned is here.
        try check("L.oneStroke", "L", { ScorerGoldenCases.merged($0, 0, 1) },
                  Golden(dev: 0.8398469491012498, raw: 0.84999999999999998, strokeCount: 1,
                         order: "1", reversed: 0, form: 0))
    }

    // MARK: A (three strokes)

    @Test("A: the reference, an offset copy and a half-size copy score the same primary")
    func letterA() throws {
        let id = Golden(dev: 0.00026918745388805669, raw: 0.0002691874538880594, strokeCount: 3,
                        order: "0,1,2", reversed: 0, form: 0.99910270848703986)
        try check("A.identity", "A", ScorerGoldenCases.identity, id)
        try check("A.offset", "A", { ScorerGoldenCases.offset($0) },
                  Golden(dev: id.dev, raw: Self.offsetRaw, strokeCount: 3, order: "0,1,2", reversed: 0, form: id.form))
        try check("A.scaled", "A", { ScorerGoldenCases.scaled($0) },
                  Golden(dev: id.dev, raw: 0.54796111683757054, strokeCount: 3, order: "0,1,2", reversed: 0, form: id.form))
    }

    @Test("A: the crossbar missing — the legs still score as the legs (snapshot)")
    func letterAMissingCrossbar() throws {
        try check("A.missing2", "A", { ScorerGoldenCases.missing($0, stroke: 2) },
                  Golden(dev: 0.00019396039149175234, raw: 0.0001939603914917563, strokeCount: 2,
                         order: "0,1", reversed: 0, form: 0.99935346536169412))
    }

    @Test("F1-01: A with both legs drawn as one Λ stroke scores Form 0 (snapshot)")
    func letterALambda() throws {
        try check("A.lambda", "A", { ScorerGoldenCases.merged($0, 0, 1) },
                  Golden(dev: 0.48937549099932315, raw: 0.48939204654984358, strokeCount: 2,
                         order: "1,2", reversed: 1, form: 0))
    }

    @Test("F1-02: a perfect A plus one 2-sample stray contact keeps the perfect A's primary (r16 B11)")
    func letterAStrayContact() throws {
        // dev / raw / form = A.identity's (derived: the stray is unmatched
        // and, since r16, outside the fit).
        try check("A.stray", "A", ScorerGoldenCases.withStray,
                  Golden(dev: 0.00026918745388805669, raw: 0.0002691874538880594, strokeCount: 4,
                         order: "0,1,2,-", reversed: 0, form: 0.99910270848703986))
    }

    // MARK: I (one slanted stroke)

    @Test("I: the reference, an offset copy and a half-size copy score the same primary")
    func letterI() throws {
        let id = Golden(dev: 0.00023179878254129394, raw: 0.00023179878254128789, strokeCount: 1,
                        order: "0", reversed: 0, form: 0.99922733739152902)
        try check("I.identity", "I", ScorerGoldenCases.identity, id)
        try check("I.offset", "I", { ScorerGoldenCases.offset($0) },
                  Golden(dev: id.dev, raw: Self.offsetRaw, strokeCount: 1, order: "0", reversed: 0, form: id.form))
        try check("I.scaled", "I", { ScorerGoldenCases.scaled($0) },
                  Golden(dev: id.dev, raw: 0.5044055907699676, strokeCount: 1, order: "0", reversed: 0, form: id.form))
    }

    @Test("F1-02: I with 6° extra slant (snapshot; r27: the shear fit takes the slant out)")
    func letterISlant() throws {
        // r27: dev was 0.10648054788511097 / form 0.64506484038296352 before
        // the ±15° shear joined the fit; a 6° rotation of a near-vertical
        // stroke is within the shear's reach. raw has no fit and is unchanged.
        try check("I.rot6", "I", { ScorerGoldenCases.rotated($0, degrees: 6) },
                  Golden(dev: 0.001968290180251752, raw: 0.05250316419688307, strokeCount: 1,
                         order: "0", reversed: 0, form: 0.99343903273249412))
    }

    // MARK: M (one 200-checkpoint stroke)

    @Test("M: the reference traced exactly (snapshot; r27 shear fit)")
    func letterM() throws {
        // r27: dev was 0.0046765675264210382 / form 0.9844114415785965 before the shear.
        try check("M.identity", "M", ScorerGoldenCases.identity,
                  Golden(dev: 0.0046133389810544042, raw: 0.0044225747555717921, strokeCount: 1,
                         order: "0", reversed: 0, form: 0.98462220339648532))
    }

    @Test("F1-01: an exact M drawn in four strokes (lifts at its three vertices) scores Form 0 (snapshot)")
    func letterMFourStrokes() throws {
        // Split at checkpoints 49, 98 and 150: M's three interior y-extrema
        // in the Regular strokes.json.
        try check("M.split4", "M", { ScorerGoldenCases.split($0, at: [49, 98, 150]) },
                  // r27: dev was 0.91106954446945454 before the shear.
                  Golden(dev: 0.90746929901341733, raw: 0.91206194965035126, strokeCount: 4,
                         order: "-,0,-,-", reversed: 0, form: 0))
    }
}
