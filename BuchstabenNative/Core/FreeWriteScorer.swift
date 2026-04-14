// FreeWriteScorer.swift
// BuchstabenNative
//
// Scores a freehand drawn path against a reference letter definition
// using discrete Fréchet distance. Used in the free-write learning phase
// where the child draws without checkpoint rails.
//
// The Fréchet distance measures the maximum deviation between two curves
// under optimal reparametrisation — intuitively, the shortest leash needed
// for a person walking along one curve and a dog walking along the other.
//
// References:
// - Eiter & Mannila (1994) "Computing Discrete Fréchet Distance"
// - Alt & Godau (1995) "Computing the Fréchet Distance Between Two Polygonal Curves"

import CoreGraphics
import Foundation

struct FreeWriteScorer {

    // MARK: - Public API

    /// Scores a traced path against reference strokes.
    ///
    /// - Parameters:
    ///   - tracedPoints: The child's freehand path, normalised to 0–1.
    ///   - reference: The canonical stroke definition for the letter.
    /// - Returns: A score from 0.0 (no resemblance) to 1.0 (perfect trace).
    static func score(
        tracedPoints: [CGPoint],
        reference: LetterStrokes
    ) -> CGFloat {
        let refPoints = referencePolyline(from: reference)
        guard refPoints.count >= 2, tracedPoints.count >= 2 else { return 0 }

        // Resample both curves to comparable density for fair comparison.
        let targetCount = max(refPoints.count, 20)
        let resampledTrace = resample(tracedPoints, targetCount: targetCount)
        let resampledRef   = resample(refPoints, targetCount: targetCount)

        let distance = discreteFrechetDistance(resampledTrace, resampledRef)

        // Scale: checkpointRadius is the "on path" tolerance for guided tracing.
        // Use 3× as the maximum acceptable Fréchet distance for a passing score.
        let maxAcceptable = reference.checkpointRadius * 3.0
        guard maxAcceptable > 0 else { return 0 }

        return CGFloat(max(0, min(1, 1.0 - distance / maxAcceptable)))
    }

    /// Raw Fréchet distance (exposed for debug overlay and testing).
    static func rawDistance(
        tracedPoints: [CGPoint],
        reference: LetterStrokes
    ) -> CGFloat {
        let refPoints = referencePolyline(from: reference)
        guard refPoints.count >= 2, tracedPoints.count >= 2 else { return .greatestFiniteMagnitude }
        let targetCount = max(refPoints.count, 20)
        return discreteFrechetDistance(
            resample(tracedPoints, targetCount: targetCount),
            resample(refPoints, targetCount: targetCount)
        )
    }

    // MARK: - Discrete Fréchet Distance

    /// O(nm) dynamic programming computation of discrete Fréchet distance.
    ///
    /// Uses a flat array instead of 2D for cache-line efficiency.
    /// Iterative bottom-up to avoid stack overflow on large inputs.
    static func discreteFrechetDistance(
        _ p: [CGPoint], _ q: [CGPoint]
    ) -> CGFloat {
        let n = p.count, m = q.count
        guard n > 0, m > 0 else { return .greatestFiniteMagnitude }

        // Flat 2D array: dp[i * m + j]
        var dp = [CGFloat](repeating: 0, count: n * m)

        for i in 0..<n {
            for j in 0..<m {
                let d = dist(p[i], q[j])
                let idx = i * m + j
                if i == 0 && j == 0 {
                    dp[idx] = d
                } else if i == 0 {
                    dp[idx] = max(d, dp[j - 1])           // dp[0, j-1]
                } else if j == 0 {
                    dp[idx] = max(d, dp[(i - 1) * m])     // dp[i-1, 0]
                } else {
                    let prev = min(
                        dp[(i - 1) * m + j],           // dp[i-1, j]
                        min(dp[i * m + (j - 1)],       // dp[i, j-1]
                            dp[(i - 1) * m + (j - 1)]) // dp[i-1, j-1]
                    )
                    dp[idx] = max(d, prev)
                }
            }
        }

        return dp[n * m - 1]
    }

    // MARK: - Helpers

    /// Converts a LetterStrokes definition into a single polyline of normalised points.
    private static func referencePolyline(from strokes: LetterStrokes) -> [CGPoint] {
        strokes.strokes.flatMap { stroke in
            stroke.checkpoints.map { CGPoint(x: $0.x, y: $0.y) }
        }
    }

    /// Euclidean distance between two points.
    private static func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    /// Resamples a polyline to approximately `targetCount` equidistant points.
    ///
    /// This normalises the point density between the child's traced path
    /// (which may have hundreds of touch samples) and the reference
    /// (which typically has 5–16 checkpoints).
    static func resample(_ points: [CGPoint], targetCount: Int) -> [CGPoint] {
        guard points.count >= 2, targetCount >= 2 else { return points }

        // Compute cumulative arc lengths.
        var cumLengths = [CGFloat](repeating: 0, count: points.count)
        for i in 1..<points.count {
            cumLengths[i] = cumLengths[i - 1] + dist(points[i - 1], points[i])
        }

        let totalLength = cumLengths.last ?? 0
        guard totalLength > 0 else { return [points[0]] }

        var result = [CGPoint]()
        result.reserveCapacity(targetCount)
        result.append(points[0])

        var cursor = 1 // index into original points
        for step in 1..<(targetCount - 1) {
            let targetDist = totalLength * CGFloat(step) / CGFloat(targetCount - 1)
            while cursor < points.count - 1 && cumLengths[cursor] < targetDist {
                cursor += 1
            }
            // Linearly interpolate between points[cursor-1] and points[cursor].
            let prevDist = cumLengths[cursor - 1]
            let segLen   = cumLengths[cursor] - prevDist
            let t: CGFloat = segLen > 0 ? (targetDist - prevDist) / segLen : 0
            let interp = CGPoint(
                x: points[cursor - 1].x + t * (points[cursor].x - points[cursor - 1].x),
                y: points[cursor - 1].y + t * (points[cursor].y - points[cursor - 1].y)
            )
            result.append(interp)
        }

        result.append(points.last!)
        return result
    }
}
