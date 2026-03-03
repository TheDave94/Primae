import SwiftUI
import CoreGraphics
import Foundation

struct LetterGuideRenderer {
    static func guidePath(for letter: String, in rect: CGRect) -> Path? {
        let key = letter.uppercased()
        guard let segments = guides[key] else { return nil }

        var p = Path()
        for segment in segments {
            switch segment {
            case let .line(a, b):
                p.move(to: map(a, in: rect))
                p.addLine(to: map(b, in: rect))
            case let .polyline(points):
                guard let first = points.first else { continue }
                p.move(to: map(first, in: rect))
                for point in points.dropFirst() {
                    p.addLine(to: map(point, in: rect))
                }
            case let .arc(center, radius, start, end, clockwise):
                p.addArc(
                    center: map(center, in: rect),
                    radius: radius * min(rect.width, rect.height),
                    startAngle: .degrees(start),
                    endAngle: .degrees(end),
                    clockwise: clockwise
                )
            }
        }

        return p
    }
}

private extension LetterGuideRenderer {
    enum Segment {
        case line(CGPoint, CGPoint)
        case polyline([CGPoint])
        case arc(center: CGPoint, radius: CGFloat, start: CGFloat, end: CGFloat, clockwise: Bool)
    }

    static func map(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
    }

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
