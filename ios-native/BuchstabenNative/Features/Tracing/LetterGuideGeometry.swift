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

    static let guides: [String: [Segment]] = [
        "A": [
            .line(CGPoint(x: 0.18, y: 0.88), CGPoint(x: 0.5, y: 0.12)),
            .line(CGPoint(x: 0.82, y: 0.88), CGPoint(x: 0.5, y: 0.12)),
            .line(CGPoint(x: 0.32, y: 0.56), CGPoint(x: 0.68, y: 0.56))
        ],
        "F": [
            .line(CGPoint(x: 0.25, y: 0.12), CGPoint(x: 0.25, y: 0.88)),
            .line(CGPoint(x: 0.25, y: 0.12), CGPoint(x: 0.78, y: 0.12)),
            .line(CGPoint(x: 0.25, y: 0.5), CGPoint(x: 0.68, y: 0.5))
        ],
        "I": [
            .line(CGPoint(x: 0.2, y: 0.12), CGPoint(x: 0.8, y: 0.12)),
            .line(CGPoint(x: 0.5, y: 0.12), CGPoint(x: 0.5, y: 0.88)),
            .line(CGPoint(x: 0.2, y: 0.88), CGPoint(x: 0.8, y: 0.88))
        ],
        "K": [
            .line(CGPoint(x: 0.25, y: 0.12), CGPoint(x: 0.25, y: 0.88)),
            .line(CGPoint(x: 0.75, y: 0.12), CGPoint(x: 0.25, y: 0.52)),
            .line(CGPoint(x: 0.25, y: 0.52), CGPoint(x: 0.78, y: 0.88))
        ],
        "L": [
            .line(CGPoint(x: 0.25, y: 0.12), CGPoint(x: 0.25, y: 0.88)),
            .line(CGPoint(x: 0.25, y: 0.88), CGPoint(x: 0.8, y: 0.88))
        ],
        "M": [
            .polyline([
                CGPoint(x: 0.15, y: 0.88),
                CGPoint(x: 0.15, y: 0.12),
                CGPoint(x: 0.5, y: 0.52),
                CGPoint(x: 0.85, y: 0.12),
                CGPoint(x: 0.85, y: 0.88)
            ])
        ],
        "O": [
            .arc(center: CGPoint(x: 0.5, y: 0.5), radius: 0.36, start: 0, end: 360, clockwise: false)
        ]
    ]
}
