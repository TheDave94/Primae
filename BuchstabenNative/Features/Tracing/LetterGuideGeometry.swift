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
        let hash = abs(letter.unicodeScalars.reduce(0) { ($0 * 31) + Int($1.value) })
        let crossbarY = CGFloat(0.42 + (Double(hash % 20) / 100.0))
        return [
            .line(CGPoint(x: 0.22, y: 0.12), CGPoint(x: 0.22, y: 0.88)),
            .line(CGPoint(x: 0.22, y: crossbarY), CGPoint(x: 0.78, y: crossbarY)),
            .line(CGPoint(x: 0.22, y: 0.88), CGPoint(x: 0.78, y: 0.88))
        ]
    }

    // MARK: - Letter definitions
    // Coordinates measured from real device debug screenshots in the legacy Timestretch build.
    // Stroke order and direction match the strokes.json checkpoint files exactly.
    static let guides: [String: [Segment]] = [
        "A": [
            // Stroke 1: left leg — apex (top-center) DOWN to bottom-left
            .line(CGPoint(x: 0.507, y: 0.240), CGPoint(x: 0.360, y: 0.759)),
            // Stroke 2: right leg — apex (top-center) DOWN to bottom-right
            .line(CGPoint(x: 0.532, y: 0.240), CGPoint(x: 0.678, y: 0.759)),
            // Stroke 3: crossbar — left to right
            .line(CGPoint(x: 0.377, y: 0.597), CGPoint(x: 0.620, y: 0.597))
        ],
        "F": [
            // Stroke 1: vertical spine — top to bottom
            .line(CGPoint(x: 0.444, y: 0.251), CGPoint(x: 0.444, y: 0.759)),
            // Stroke 2: top crossbar — left to right
            .line(CGPoint(x: 0.456, y: 0.268), CGPoint(x: 0.670, y: 0.279)),
            // Stroke 3: mid crossbar — left to right
            .line(CGPoint(x: 0.452, y: 0.508), CGPoint(x: 0.607, y: 0.511))
        ],
        "I": [
            // Stroke 1: straight down (single stroke, no serifs in checkpoint data)
            .line(CGPoint(x: 0.532, y: 0.234), CGPoint(x: 0.532, y: 0.776))
        ],
        "K": [
            // Stroke 1: vertical spine — top to bottom
            .line(CGPoint(x: 0.465, y: 0.223), CGPoint(x: 0.431, y: 0.770)),
            // Stroke 2: upper arm — top-right DOWN-LEFT to junction
            .line(CGPoint(x: 0.637, y: 0.223), CGPoint(x: 0.536, y: 0.480)),
            // Stroke 3: lower arm — junction DOWN-RIGHT to bottom-right
            .line(CGPoint(x: 0.523, y: 0.519), CGPoint(x: 0.653, y: 0.781))
        ],
        "L": [
            // Stroke 1: vertical stroke — top to bottom
            .line(CGPoint(x: 0.448, y: 0.234), CGPoint(x: 0.448, y: 0.731)),
            // Stroke 2: baseline foot — left to right
            .line(CGPoint(x: 0.448, y: 0.748), CGPoint(x: 0.624, y: 0.753))
        ],
        "M": [
            // Stroke 1: left spine — top-left down to bottom-left
            .line(CGPoint(x: 0.302, y: 0.301), CGPoint(x: 0.297, y: 0.759)),
            // Stroke 2: left diagonal — top-left DOWN-RIGHT to valley
            .line(CGPoint(x: 0.369, y: 0.257), CGPoint(x: 0.511, y: 0.625)),
            // Stroke 3: right diagonal — valley UP-RIGHT to top-right
            .line(CGPoint(x: 0.549, y: 0.608), CGPoint(x: 0.670, y: 0.312)),
            // Stroke 4: right spine — top-right down to bottom-right
            .line(CGPoint(x: 0.737, y: 0.240), CGPoint(x: 0.754, y: 0.770))
        ],
        "O": [
            // Stroke 1: clockwise oval starting top-left, all the way around
            .polyline([
                CGPoint(x: 0.436, y: 0.268),
                CGPoint(x: 0.523, y: 0.257),
                CGPoint(x: 0.641, y: 0.268),
                CGPoint(x: 0.720, y: 0.368),
                CGPoint(x: 0.737, y: 0.491),
                CGPoint(x: 0.716, y: 0.625),
                CGPoint(x: 0.657, y: 0.725),
                CGPoint(x: 0.553, y: 0.765),
                CGPoint(x: 0.440, y: 0.725),
                CGPoint(x: 0.356, y: 0.608),
                CGPoint(x: 0.335, y: 0.480),
                CGPoint(x: 0.356, y: 0.357),
                CGPoint(x: 0.436, y: 0.268)
            ])
        ]
    ]
}
