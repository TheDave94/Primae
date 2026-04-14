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
            .line(CGPoint(x: 0.50, y: 0.20), CGPoint(x: 0.50, y: 0.80)),
            .line(CGPoint(x: 0.30, y: 0.40), CGPoint(x: 0.70, y: 0.40)),
            .line(CGPoint(x: 0.30, y: 0.65), CGPoint(x: 0.70, y: 0.65))
        ]
    }

    // MARK: - Letter definitions
    // Coordinates hand-calibrated against PBM bitmaps using the ghost calibration tool.
    // Only A, F, I, K, L, M, O are active (the only letters with audio assets).
    static let guides: [String: [Segment]] = [
        "A": [
            .line(CGPoint(x: 0.225, y: 0.875), CGPoint(x: 0.523, y: 0.127)),
            .line(CGPoint(x: 0.525, y: 0.131), CGPoint(x: 0.727, y: 0.875)),
            .line(CGPoint(x: 0.348, y: 0.575), CGPoint(x: 0.646, y: 0.577)),
        ],
        "F": [
            .line(CGPoint(x: 0.396, y: 0.135), CGPoint(x: 0.346, y: 0.892)),
            .line(CGPoint(x: 0.396, y: 0.138), CGPoint(x: 0.740, y: 0.138)),
            .line(CGPoint(x: 0.379, y: 0.483), CGPoint(x: 0.656, y: 0.483)),
        ],
        "I": [
            .line(CGPoint(x: 0.527, y: 0.119), CGPoint(x: 0.475, y: 0.890)),
        ],
        "K": [
            .line(CGPoint(x: 0.352, y: 0.115), CGPoint(x: 0.300, y: 0.892)),
            .line(CGPoint(x: 0.404, y: 0.477), CGPoint(x: 0.769, y: 0.123)),
            .line(CGPoint(x: 0.404, y: 0.483), CGPoint(x: 0.721, y: 0.877)),
        ],
        "L": [
            .line(CGPoint(x: 0.394, y: 0.123), CGPoint(x: 0.346, y: 0.856)),
            .line(CGPoint(x: 0.348, y: 0.860), CGPoint(x: 0.717, y: 0.860)),
        ],
        "M": [
            .line(CGPoint(x: 0.267, y: 0.156), CGPoint(x: 0.169, y: 0.850)),
            .line(CGPoint(x: 0.277, y: 0.160), CGPoint(x: 0.467, y: 0.804)),
            .line(CGPoint(x: 0.471, y: 0.806), CGPoint(x: 0.748, y: 0.154)),
            .line(CGPoint(x: 0.750, y: 0.154), CGPoint(x: 0.779, y: 0.846)),
        ],
        "O": [
            .polyline([
                CGPoint(x: 0.538, y: 0.131), CGPoint(x: 0.583, y: 0.140),
                CGPoint(x: 0.629, y: 0.167), CGPoint(x: 0.667, y: 0.200),
                CGPoint(x: 0.696, y: 0.235), CGPoint(x: 0.715, y: 0.275),
                CGPoint(x: 0.729, y: 0.317), CGPoint(x: 0.738, y: 0.367),
                CGPoint(x: 0.746, y: 0.413), CGPoint(x: 0.746, y: 0.452),
                CGPoint(x: 0.746, y: 0.492), CGPoint(x: 0.742, y: 0.533),
                CGPoint(x: 0.738, y: 0.575), CGPoint(x: 0.729, y: 0.608),
                CGPoint(x: 0.723, y: 0.635), CGPoint(x: 0.715, y: 0.667),
                CGPoint(x: 0.698, y: 0.700), CGPoint(x: 0.685, y: 0.725),
                CGPoint(x: 0.671, y: 0.750), CGPoint(x: 0.654, y: 0.769),
                CGPoint(x: 0.629, y: 0.798), CGPoint(x: 0.604, y: 0.821),
                CGPoint(x: 0.577, y: 0.844), CGPoint(x: 0.540, y: 0.863),
                CGPoint(x: 0.510, y: 0.869), CGPoint(x: 0.479, y: 0.871),
                CGPoint(x: 0.450, y: 0.871), CGPoint(x: 0.413, y: 0.860),
                CGPoint(x: 0.373, y: 0.848), CGPoint(x: 0.352, y: 0.829),
                CGPoint(x: 0.325, y: 0.804), CGPoint(x: 0.308, y: 0.775),
                CGPoint(x: 0.298, y: 0.744), CGPoint(x: 0.283, y: 0.708),
                CGPoint(x: 0.271, y: 0.667), CGPoint(x: 0.263, y: 0.615),
                CGPoint(x: 0.256, y: 0.560), CGPoint(x: 0.258, y: 0.508),
                CGPoint(x: 0.263, y: 0.460), CGPoint(x: 0.273, y: 0.413),
                CGPoint(x: 0.285, y: 0.369), CGPoint(x: 0.298, y: 0.325),
                CGPoint(x: 0.319, y: 0.288), CGPoint(x: 0.342, y: 0.246),
                CGPoint(x: 0.377, y: 0.206), CGPoint(x: 0.408, y: 0.183),
                CGPoint(x: 0.448, y: 0.158), CGPoint(x: 0.481, y: 0.142),
                CGPoint(x: 0.508, y: 0.135), CGPoint(x: 0.542, y: 0.133),
            ]),
        ],
    ]
}
