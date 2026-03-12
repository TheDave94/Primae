import CoreGraphics
import Foundation

/// Pure CoreGraphics letter guide geometry.
/// No UIKit, SwiftUI, or AppKit imports — safe to use on Linux CI.
///
/// Returns `CGPath` objects. `LetterGuideRenderer` wraps these in SwiftUI `Path`
/// for rendering. All path math lives here, decoupled from rendering concerns.
public struct LetterGuideGeometry {

    // MARK: - Public API

    /// Returns a `CGPath` for the given letter, scaled to fit `rect`.
    /// Returns `nil` if `rect` is empty.
    public static func cgPath(for letter: String, in rect: CGRect) -> CGPath? {
        guard !rect.isEmpty else { return nil }
        let key = letter.uppercased()
        let segments = guides[key].flatMap { $0.isEmpty ? nil : $0 } ?? fallbackSegments(for: key)
        let path = CGMutablePath()
        for segment in segments {
            apply(segment, to: path, in: rect)
        }
        return path.isEmpty ? nil : path
    }

    // MARK: - Segment model

    public enum Segment: Sendable {
        case line(CGPoint, CGPoint)
        case polyline([CGPoint])
        case arc(center: CGPoint, radius: CGFloat, start: CGFloat, end: CGFloat, clockwise: Bool)
    }

    // MARK: - Private helpers

    static func map(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + point.x * rect.width,
                y: rect.minY + point.y * rect.height)
    }

    private static func apply(_ segment: Segment, to path: CGMutablePath, in rect: CGRect) {
        switch segment {
        case let .line(a, b):
            path.move(to: map(a, in: rect))
            path.addLine(to: map(b, in: rect))

        case let .polyline(points):
            guard let first = points.first else { return }
            path.move(to: map(first, in: rect))
            for point in points.dropFirst() {
                path.addLine(to: map(point, in: rect))
            }

        case let .arc(center, radius, start, end, clockwise):
            let mappedCenter = map(center, in: rect)
            let scaledRadius = radius * min(rect.width, rect.height)
            let startRad = start * .pi / 180
            let endRad = end * .pi / 180
            path.addArc(
                center: mappedCenter,
                radius: scaledRadius,
                startAngle: startRad,
                endAngle: endRad,
                clockwise: clockwise
            )
        }
    }

    static func fallbackSegments(for letter: String) -> [Segment] {
        return [
            .line(CGPoint(x: 0.50, y: 0.20), CGPoint(x: 0.50, y: 0.80))
        ]
    }

    // MARK: - Letter definitions
    // Coordinates computed from PBM pixel centerlines (2732×2048 bitmaps).
    // Each stroke traces the exact center of the ink at measured sample points.
    // Stroke order and direction match strokes.json exactly.
    static let guides: [String: [Segment]] = [
        "A": [
            // Stroke 1: left leg — apex DOWN to bottom-left
            .polyline([
                CGPoint(x: 0.515, y: 0.170), CGPoint(x: 0.514, y: 0.319),
                CGPoint(x: 0.514, y: 0.469), CGPoint(x: 0.400, y: 0.668),
                CGPoint(x: 0.296, y: 0.817)
            ]),
            // Stroke 2: right leg — apex DOWN to bottom-right
            .polyline([
                CGPoint(x: 0.515, y: 0.170), CGPoint(x: 0.514, y: 0.319),
                CGPoint(x: 0.514, y: 0.494), CGPoint(x: 0.762, y: 0.668),
                CGPoint(x: 0.695, y: 0.817)
            ]),
            // Stroke 3: crossbar — left to right
            .line(CGPoint(x: 0.399, y: 0.597), CGPoint(x: 0.624, y: 0.597))
        ],
        "F": [
            // Stroke 1: vertical spine — top to bottom
            .line(CGPoint(x: 0.421, y: 0.180), CGPoint(x: 0.421, y: 0.811)),
            // Stroke 2: top crossbar — left to right
            .line(CGPoint(x: 0.397, y: 0.200), CGPoint(x: 0.664, y: 0.200)),
            // Stroke 3: mid crossbar — left to right
            .line(CGPoint(x: 0.397, y: 0.500), CGPoint(x: 0.630, y: 0.500))
        ],
        "I": [
            // Stroke 1: top serif — left to right
            .line(CGPoint(x: 0.387, y: 0.237), CGPoint(x: 0.602, y: 0.237)),
            // Stroke 2: stem — straight down
            .line(CGPoint(x: 0.579, y: 0.250), CGPoint(x: 0.579, y: 0.764)),
            // Stroke 3: bottom serif — left to right
            .line(CGPoint(x: 0.396, y: 0.771), CGPoint(x: 0.579, y: 0.771))
        ],
        "K": [
            // Stroke 1: vertical spine — top to bottom
            .line(CGPoint(x: 0.417, y: 0.170), CGPoint(x: 0.413, y: 0.801)),
            // Stroke 2: upper arm — top-right DOWN-LEFT to junction
            .polyline([
                CGPoint(x: 0.685, y: 0.170), CGPoint(x: 0.618, y: 0.270),
                CGPoint(x: 0.567, y: 0.419), CGPoint(x: 0.517, y: 0.519)
            ]),
            // Stroke 3: lower arm — junction DOWN-RIGHT to bottom-right
            .polyline([
                CGPoint(x: 0.503, y: 0.480), CGPoint(x: 0.587, y: 0.580),
                CGPoint(x: 0.675, y: 0.729), CGPoint(x: 0.691, y: 0.829)
            ])
        ],
        "L": [
            // Stroke 1: vertical stroke — top to bottom
            .line(CGPoint(x: 0.425, y: 0.170), CGPoint(x: 0.425, y: 0.763)),
            // Stroke 2: baseline foot — left to right
            .line(CGPoint(x: 0.293, y: 0.780), CGPoint(x: 0.657, y: 0.780))
        ],
        "M": [
            // Stroke 1: left spine — top-left down to bottom-left
            .polyline([
                CGPoint(x: 0.384, y: 0.170), CGPoint(x: 0.364, y: 0.340),
                CGPoint(x: 0.324, y: 0.510), CGPoint(x: 0.185, y: 0.668),
                CGPoint(x: 0.209, y: 0.821)
            ]),
            // Stroke 2: left diagonal — top-left DOWN-RIGHT to valley
            .polyline([
                CGPoint(x: 0.384, y: 0.170), CGPoint(x: 0.396, y: 0.319),
                CGPoint(x: 0.413, y: 0.419), CGPoint(x: 0.431, y: 0.519),
                CGPoint(x: 0.450, y: 0.595)
            ]),
            // Stroke 3: right diagonal — valley UP-RIGHT to top-right
            .polyline([
                CGPoint(x: 0.569, y: 0.595), CGPoint(x: 0.601, y: 0.481),
                CGPoint(x: 0.625, y: 0.381), CGPoint(x: 0.645, y: 0.270),
                CGPoint(x: 0.658, y: 0.170)
            ]),
            // Stroke 4: right spine — top-right down to bottom-right
            .polyline([
                CGPoint(x: 0.658, y: 0.170), CGPoint(x: 0.658, y: 0.340),
                CGPoint(x: 0.672, y: 0.510), CGPoint(x: 0.836, y: 0.668),
                CGPoint(x: 0.777, y: 0.821)
            ])
        ],
        "O": [
            // Stroke 1: clockwise oval from top, 16 measured points
            .polyline([
                CGPoint(x: 0.500, y: 0.197), CGPoint(x: 0.606, y: 0.244),
                CGPoint(x: 0.661, y: 0.339), CGPoint(x: 0.680, y: 0.425),
                CGPoint(x: 0.682, y: 0.500), CGPoint(x: 0.680, y: 0.575),
                CGPoint(x: 0.661, y: 0.661), CGPoint(x: 0.606, y: 0.756),
                CGPoint(x: 0.500, y: 0.802), CGPoint(x: 0.395, y: 0.754),
                CGPoint(x: 0.339, y: 0.661), CGPoint(x: 0.320, y: 0.575),
                CGPoint(x: 0.318, y: 0.500), CGPoint(x: 0.320, y: 0.425),
                CGPoint(x: 0.339, y: 0.339), CGPoint(x: 0.394, y: 0.244),
                CGPoint(x: 0.500, y: 0.197)
            ])
        ]
    ]
}
