// GlyphStrokeExtractor.swift
// BuchstabenNative
//
// Extracts stroke centerline checkpoints directly from font glyph outlines
// at runtime. Works on any screen size — coordinates are glyph-relative (0–1).
// Falls back to bundled strokes.json if extraction fails.

import CoreGraphics
import CoreText
import UIKit

struct GlyphStrokeExtractor {

    /// Extract glyph-relative stroke checkpoints from the Primae font.
    /// Returns nil if extraction fails (e.g. font not available, test environment).
    static func extractStrokes(
        for letter: String,
        samplesPerStroke: Int = 7,
        checkpointRadius: CGFloat = 0.05
    ) -> LetterStrokes? {
        guard !letter.isEmpty else { return nil }
        // Skip in test environments
        guard NSClassFromString("XCTestCase") == nil else { return nil }

        guard let font = PrimaeLetterRenderer.makeFont(size: 800),
              let glyph = PrimaeLetterRenderer.getGlyph(for: letter, in: font) else {
            return nil
        }

        guard let cgPath = CTFontCreatePathForGlyph(font, glyph, nil) else {
            return nil
        }

        // 1. Flatten the path into line segments
        let segments = flattenPath(cgPath)
        guard !segments.isEmpty else { return nil }

        // 2. Compute glyph bounding box
        let bbox = cgPath.boundingBox
        guard bbox.width > 0, bbox.height > 0 else { return nil }

        // 3. Sample horizontal cross-sections to find stroke centers
        let numSamples = 40
        var centersByRow: [[CGFloat]] = []

        for i in 1..<numSamples {
            let t = CGFloat(i) / CGFloat(numSamples)
            // Font coords: y=0 is baseline, increases upward
            let fontY = bbox.minY + bbox.height * (1.0 - t) // t=0 → top, t=1 → bottom
            let crossings = findXCrossings(segments: segments, y: fontY)
            // Normalize x to glyph-relative
            let normX = crossings.map { ($0 - bbox.minX) / bbox.width }
            // Pair crossings into stroke centers
            var centers: [CGFloat] = []
            var j = 0
            while j + 1 < normX.count {
                centers.append((normX[j] + normX[j + 1]) / 2)
                j += 2
            }
            centersByRow.append(centers)
        }

        // 4. Build stroke paths by connecting centers across rows
        let strokePaths = connectCenters(centersByRow: centersByRow, numSamples: numSamples)
        guard !strokePaths.isEmpty else { return nil }

        // 5. Resample each stroke path to evenly-spaced checkpoints
        let strokes = strokePaths.enumerated().map { (idx, path) in
            let resampled = resample(path: path, count: samplesPerStroke)
            return StrokeDefinition(
                id: idx + 1,
                checkpoints: resampled.map { Checkpoint(x: $0.x, y: $0.y) }
            )
        }

        return LetterStrokes(
            letter: letter,
            checkpointRadius: checkpointRadius,
            strokes: strokes
        )
    }

    // MARK: - Path Flattening

    private struct Segment {
        let x1: CGFloat, y1: CGFloat
        let x2: CGFloat, y2: CGFloat
    }

    private static func flattenPath(_ path: CGPath) -> [Segment] {
        var segments: [Segment] = []
        var currentPoint = CGPoint.zero
        var subpathStart = CGPoint.zero

        path.applyWithBlock { elementPtr in
            let element = elementPtr.pointee
            switch element.type {
            case .moveToPoint:
                currentPoint = element.points[0]
                subpathStart = currentPoint
            case .addLineToPoint:
                let p = element.points[0]
                segments.append(Segment(x1: currentPoint.x, y1: currentPoint.y,
                                        x2: p.x, y2: p.y))
                currentPoint = p
            case .addQuadCurveToPoint:
                let p1 = element.points[0]
                let p2 = element.points[1]
                // Flatten quadratic bezier
                let steps = 8
                for s in 1...steps {
                    let t = CGFloat(s) / CGFloat(steps)
                    let x = (1-t)*(1-t)*currentPoint.x + 2*(1-t)*t*p1.x + t*t*p2.x
                    let y = (1-t)*(1-t)*currentPoint.y + 2*(1-t)*t*p1.y + t*t*p2.y
                    segments.append(Segment(x1: currentPoint.x, y1: currentPoint.y,
                                            x2: x, y2: y))
                    currentPoint = CGPoint(x: x, y: y)
                }
                currentPoint = p2
            case .addCurveToPoint:
                let p1 = element.points[0]
                let p2 = element.points[1]
                let p3 = element.points[2]
                // Flatten cubic bezier
                let steps = 12
                for s in 1...steps {
                    let t = CGFloat(s) / CGFloat(steps)
                    let mt = 1 - t
                    let x = mt*mt*mt*currentPoint.x + 3*mt*mt*t*p1.x +
                            3*mt*t*t*p2.x + t*t*t*p3.x
                    let y = mt*mt*mt*currentPoint.y + 3*mt*mt*t*p1.y +
                            3*mt*t*t*p2.y + t*t*t*p3.y
                    segments.append(Segment(x1: currentPoint.x, y1: currentPoint.y,
                                            x2: x, y2: y))
                    currentPoint = CGPoint(x: x, y: y)
                }
                currentPoint = p3
            case .closeSubpath:
                if currentPoint != subpathStart {
                    segments.append(Segment(x1: currentPoint.x, y1: currentPoint.y,
                                            x2: subpathStart.x, y2: subpathStart.y))
                }
                currentPoint = subpathStart
            @unknown default:
                break
            }
        }
        return segments
    }

    // MARK: - Horizontal Ray Casting

    private static func findXCrossings(segments: [Segment], y: CGFloat) -> [CGFloat] {
        var crossings: [CGFloat] = []
        for seg in segments {
            let y1 = seg.y1, y2 = seg.y2
            guard (y1 <= y && y < y2) || (y2 <= y && y < y1) else { continue }
            let dy = y2 - y1
            guard abs(dy) > 0.001 else { continue }
            let t = (y - y1) / dy
            let x = seg.x1 + t * (seg.x2 - seg.x1)
            crossings.append(x)
        }
        crossings.sort()
        return crossings
    }

    // MARK: - Stroke Path Connection

    private static func connectCenters(
        centersByRow: [[CGFloat]],
        numSamples: Int
    ) -> [[CGPoint]] {
        // Track active strokes and build paths
        var activePaths: [[CGPoint]] = []
        var activeX: [CGFloat] = []

        for (rowIdx, centers) in centersByRow.enumerated() {
            let y = CGFloat(rowIdx + 1) / CGFloat(numSamples)
            var used = Array(repeating: false, count: centers.count)

            // Match existing strokes to closest center
            for pathIdx in 0..<activePaths.count {
                let lastX = activeX[pathIdx]
                var bestCIdx = -1
                var bestDist: CGFloat = 0.15 // Max distance to consider a match
                for cIdx in 0..<centers.count where !used[cIdx] {
                    let d = abs(centers[cIdx] - lastX)
                    if d < bestDist {
                        bestDist = d
                        bestCIdx = cIdx
                    }
                }
                if bestCIdx >= 0 {
                    activePaths[pathIdx].append(CGPoint(x: centers[bestCIdx], y: y))
                    activeX[pathIdx] = centers[bestCIdx]
                    used[bestCIdx] = true
                }
            }

            // Start new strokes for unmatched centers
            for cIdx in 0..<centers.count where !used[cIdx] {
                activePaths.append([CGPoint(x: centers[cIdx], y: y)])
                activeX.append(centers[cIdx])
            }
        }

        // Filter out very short strokes (noise)
        return activePaths.filter { $0.count >= 5 }
    }

    // MARK: - Resampling

    private static func resample(path: [CGPoint], count: Int) -> [CGPoint] {
        guard path.count >= 2, count >= 2 else { return path }
        var lengths: [CGFloat] = [0]
        for i in 1..<path.count {
            lengths.append(lengths.last! + hypot(path[i].x - path[i-1].x,
                                                   path[i].y - path[i-1].y))
        }
        let total = lengths.last!
        guard total > 0 else { return [path[0]] }

        var result: [CGPoint] = []
        for i in 0..<count {
            let target = total * CGFloat(i) / CGFloat(count - 1)
            for j in 1..<lengths.count {
                if lengths[j] >= target {
                    let segLen = lengths[j] - lengths[j-1]
                    let t = segLen > 0 ? (target - lengths[j-1]) / segLen : 0
                    let x = path[j-1].x + t * (path[j].x - path[j-1].x)
                    let y = path[j-1].y + t * (path[j].y - path[j-1].y)
                    result.append(CGPoint(
                        x: (x * 100).rounded() / 100,
                        y: (y * 100).rounded() / 100
                    ))
                    break
                }
            }
        }
        return result
    }
}
