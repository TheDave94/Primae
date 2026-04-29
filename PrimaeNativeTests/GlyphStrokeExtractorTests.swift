// GlyphStrokeExtractorTests.swift
// PrimaeNativeTests
//
// Direct coverage for the algorithmic core of GlyphStrokeExtractor (path
// flattening, horizontal ray-casting, stroke connection, polyline resampling).
// Drives the helpers with synthetic CGPaths and centers grids — bypasses the
// font-availability requirement that makes the public extractStrokes() bail
// out in the headless test process.

import Testing
import Foundation
import CoreGraphics
@testable import PrimaeNative

@Suite struct GlyphStrokeExtractorTests {

    // MARK: - Public entry-point contract

    @Test func extractStrokes_emptyLetter_returnsNil() {
        #expect(GlyphStrokeExtractor.extractStrokes(for: "") == nil)
    }

    @Test func extractStrokes_inTestEnvironment_returnsNil() {
        // The extractor explicitly bails when XCTestCase is loaded so the
        // unit-test process never exercises CoreText font rendering. This
        // pins that contract — a future change that removes the guard
        // surfaces here so the team can decide intentionally.
        #expect(GlyphStrokeExtractor.extractStrokes(for: "A") == nil)
    }

    // MARK: - flattenPath

    @Test func flattenPath_lineSegment_producesOneSegment() {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 10, y: 20))
        let segments = GlyphStrokeExtractor.flattenPath(path)
        #expect(segments.count == 1, "single move+line → single segment, got \(segments.count)")
        #expect(segments.first?.x1 == 0)
        #expect(segments.first?.x2 == 10)
        #expect(segments.first?.y2 == 20)
    }

    @Test func flattenPath_quadCurve_producesMultipleSegments() {
        // A quadratic Bezier is flattened with 8 sub-segments (per the impl).
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addQuadCurve(to: CGPoint(x: 10, y: 0), control: CGPoint(x: 5, y: 10))
        let segments = GlyphStrokeExtractor.flattenPath(path)
        #expect(segments.count == 8, "quad curve flattens to 8 line approximations, got \(segments.count)")
    }

    @Test func flattenPath_cubicCurve_producesMultipleSegments() {
        // A cubic Bezier is flattened with 12 sub-segments.
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addCurve(to: CGPoint(x: 30, y: 0),
                      control1: CGPoint(x: 10, y: 20),
                      control2: CGPoint(x: 20, y: -20))
        let segments = GlyphStrokeExtractor.flattenPath(path)
        #expect(segments.count == 12, "cubic curve flattens to 12 line approximations, got \(segments.count)")
    }

    @Test func flattenPath_closeSubpath_addsClosingSegment() {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 10, y: 0))
        path.addLine(to: CGPoint(x: 10, y: 10))
        path.closeSubpath()
        let segments = GlyphStrokeExtractor.flattenPath(path)
        // 2 explicit lines + 1 closing line back to (0,0).
        #expect(segments.count == 3)
        let closing = segments.last
        #expect(closing?.x2 == 0 && closing?.y2 == 0,
                "closing segment should return to subpath start, got (\(closing?.x2 ?? -1), \(closing?.y2 ?? -1))")
    }

    // MARK: - findXCrossings

    @Test func findXCrossings_horizontalLine_throughSegment_returnsCrossing() {
        // Vertical segment from (5, 0) to (5, 10). A horizontal ray at y=5
        // should cross at x=5.
        let segments = [GlyphStrokeExtractor.Segment(x1: 5, y1: 0, x2: 5, y2: 10)]
        let crossings = GlyphStrokeExtractor.findXCrossings(segments: segments, y: 5)
        #expect(crossings == [5.0])
    }

    @Test func findXCrossings_diagonal_interpolatesCorrectly() {
        // Diagonal from (0, 0) to (10, 10). Ray at y=5 should cross at x=5.
        let segments = [GlyphStrokeExtractor.Segment(x1: 0, y1: 0, x2: 10, y2: 10)]
        let crossings = GlyphStrokeExtractor.findXCrossings(segments: segments, y: 5)
        #expect(crossings.count == 1)
        #expect(abs((crossings.first ?? -1) - 5.0) < 0.001)
    }

    @Test func findXCrossings_horizontalSegment_notCounted() {
        // A perfectly horizontal segment (zero dy) should be skipped — it
        // contributes ambiguous infinite crossings if treated naively.
        let segments = [GlyphStrokeExtractor.Segment(x1: 0, y1: 5, x2: 10, y2: 5)]
        let crossings = GlyphStrokeExtractor.findXCrossings(segments: segments, y: 5)
        #expect(crossings.isEmpty,
                "horizontal segment must not contribute crossings, got \(crossings)")
    }

    @Test func findXCrossings_multipleStrokes_returnsSorted() {
        // Two parallel verticals at x=2 and x=8. Crossings should come out sorted.
        let segments = [
            GlyphStrokeExtractor.Segment(x1: 8, y1: 0, x2: 8, y2: 10),
            GlyphStrokeExtractor.Segment(x1: 2, y1: 0, x2: 2, y2: 10),
        ]
        let crossings = GlyphStrokeExtractor.findXCrossings(segments: segments, y: 5)
        #expect(crossings == [2.0, 8.0])
    }

    // MARK: - connectCenters

    @Test func connectCenters_singleStrokeAcrossRows_buildsOnePath() {
        // 6 rows, single center per row at x=0.5 → one connected path.
        let centersByRow = Array(repeating: [CGFloat(0.5)], count: 6)
        let paths = GlyphStrokeExtractor.connectCenters(centersByRow: centersByRow, numSamples: 10)
        #expect(paths.count == 1, "expected single connected path, got \(paths.count)")
        #expect(paths.first?.count == 6)
    }

    @Test func connectCenters_filterShortStrokes() {
        // A 3-row blip should be filtered (impl requires ≥5 points per stroke).
        let centersByRow: [[CGFloat]] = [[0.5], [0.5], [0.5]]
        let paths = GlyphStrokeExtractor.connectCenters(centersByRow: centersByRow, numSamples: 10)
        #expect(paths.isEmpty,
                "3-row strokes are below the noise floor, expected 0 paths")
    }

    @Test func connectCenters_twoParallelStrokes_yieldsTwoPaths() {
        // Two stable centers per row → two separate paths.
        let centersByRow = Array(repeating: [CGFloat(0.3), CGFloat(0.7)], count: 8)
        let paths = GlyphStrokeExtractor.connectCenters(centersByRow: centersByRow, numSamples: 10)
        #expect(paths.count == 2, "two parallel stroke columns → two paths, got \(paths.count)")
    }

    // MARK: - resample

    @Test func resample_evenlySpacedPoints_preservesEndpoints() {
        let path = [
            CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0), CGPoint(x: 1.0, y: 0),
        ]
        let result = GlyphStrokeExtractor.resample(path: path, count: 3)
        #expect(result.count == 3)
        #expect(abs(result.first!.x - 0.0) < 0.01, "first point should be the original start")
        #expect(abs(result.last!.x - 1.0) < 0.01,  "last point should be the original end")
    }

    @Test func resample_upsamplesShortPath() {
        // A 2-point path resampled to 5 points should produce 5 evenly spaced.
        let path = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0)]
        let result = GlyphStrokeExtractor.resample(path: path, count: 5)
        #expect(result.count == 5)
        // Quarter-way checkpoints should be approximately at 0.25 and 0.50.
        #expect(abs(result[1].x - 0.25) < 0.01)
        #expect(abs(result[2].x - 0.50) < 0.01)
    }

    @Test func resample_handlesShorterThanTarget() {
        // count=2 with path of 1 point — impl returns the original path.
        let path = [CGPoint(x: 0, y: 0)]
        let result = GlyphStrokeExtractor.resample(path: path, count: 2)
        #expect(result == path)
    }

    @Test func resample_zeroLengthPath_returnsFirstPoint() {
        // All-same-point path has total length 0; resample returns the first.
        let path = [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.5, y: 0.5)]
        let result = GlyphStrokeExtractor.resample(path: path, count: 5)
        #expect(result == [CGPoint(x: 0.5, y: 0.5)])
    }
}
