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
    // Coordinates are normalized to [0,1] x [0,1] and match the PBM bitmap layout.
    // Letters occupy roughly x=[0.22,0.79], y=[0.17,0.83] of the 2732×2048 canvas.
    static let guides: [String: [Segment]] = [
        "A": [
            // Left diagonal: bottom-left → apex
            .line(CGPoint(x: 0.22, y: 0.83), CGPoint(x: 0.55, y: 0.17)),
            // Right diagonal: apex → bottom-right
            .line(CGPoint(x: 0.55, y: 0.17), CGPoint(x: 0.79, y: 0.83)),
            // Crossbar at ~60% down
            .line(CGPoint(x: 0.35, y: 0.59), CGPoint(x: 0.72, y: 0.59))
        ],
        "F": [
            // Vertical stem at x≈0.41, top-to-bottom
            .line(CGPoint(x: 0.41, y: 0.18), CGPoint(x: 0.41, y: 0.83)),
            // Top horizontal bar
            .line(CGPoint(x: 0.41, y: 0.20), CGPoint(x: 0.66, y: 0.20)),
            // Mid horizontal bar at y≈0.49
            .line(CGPoint(x: 0.41, y: 0.49), CGPoint(x: 0.62, y: 0.49))
        ],
        "I": [
            // Top serif
            .line(CGPoint(x: 0.38, y: 0.20), CGPoint(x: 0.62, y: 0.20)),
            // Vertical stem
            .line(CGPoint(x: 0.50, y: 0.20), CGPoint(x: 0.50, y: 0.82)),
            // Bottom serif
            .line(CGPoint(x: 0.38, y: 0.82), CGPoint(x: 0.62, y: 0.82))
        ],
        "K": [
            // Vertical stem at x≈0.41
            .line(CGPoint(x: 0.41, y: 0.17), CGPoint(x: 0.41, y: 0.83)),
            // Upper diagonal: top-right → stem junction
            .line(CGPoint(x: 0.78, y: 0.17), CGPoint(x: 0.41, y: 0.50)),
            // Lower diagonal: stem junction → bottom-right
            .line(CGPoint(x: 0.41, y: 0.50), CGPoint(x: 0.78, y: 0.83))
        ],
        "L": [
            // Vertical stem at x≈0.44
            .line(CGPoint(x: 0.44, y: 0.17), CGPoint(x: 0.44, y: 0.78)),
            // Baseline
            .line(CGPoint(x: 0.44, y: 0.78), CGPoint(x: 0.70, y: 0.78))
        ],
        "M": [
            .polyline([
                CGPoint(x: 0.13, y: 0.83),
                CGPoint(x: 0.13, y: 0.17),
                CGPoint(x: 0.50, y: 0.52),
                CGPoint(x: 0.87, y: 0.17),
                CGPoint(x: 0.87, y: 0.83)
            ])
        ],
        "O": [
            // Ellipse: center (0.50, 0.50), rx≈0.21, ry≈0.33 — approximated as arc scaled to rect
            .arc(center: CGPoint(x: 0.50, y: 0.50), radius: 0.33, start: 0, end: 360, clockwise: false)
        ]
    ]
}
