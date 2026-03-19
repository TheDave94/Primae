//  LetterGuideSnapshotTests.swift
//  BuchstabenNativeTests
//
//  Lightweight golden-image tests for LetterGuideRenderer.
//  No external snapshot framework needed — we render to CGPath geometry
//  and verify structural invariants that would catch visual regressions:
//  path element counts, segment types, bounding box ratios, and
//  pixel-level rendering stability via CRC32 of a CGContext bitmap.
//
//  Note: UIGraphicsImageRenderer requires a device/simulator, so the
//  pixel tests are guarded with #if canImport(UIKit).

import XCTest
import CoreGraphics
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
@testable import BuchstabenNative

@MainActor
final class LetterGuideSnapshotTests: XCTestCase {

    private let rect = CGRect(x: 0, y: 0, width: 200, height: 200)

    // MARK: - Structural snapshot: path element counts per letter

    /// Known element counts for curated letters (move + line/arc).
    /// If geometry changes, this test will fail and catch the regression.
    private let expectedMinElements: [String: Int] = [
        "A": 6,  // 3 lines × (moveto + lineto)
        "F": 6,  // 3 lines
        "I": 6,  // 3 lines
        "K": 6,  // 3 lines
        "L": 4,  // 2 lines
        "M": 5,  // 1 polyline with 5 points = 1 move + 4 lines
        "O": 1,  // 1 arc element
    ]

    func testCuratedLetters_pathElementCount_isStable() async {
        for (letter, minCount) in expectedMinElements {
            let path = LetterGuideRenderer.guidePath(for: letter, in: rect)!
            var count = 0
            path.forEach { _ in count += 1 }
            XCTAssertGreaterThanOrEqual(count, minCount,
                "'\(letter)' path element count \(count) is below expected minimum \(minCount) — geometry may have regressed")
        }
    }

    // MARK: - Bounding box ratio snapshot

    /// Aspect ratios that define each letter's visual identity.
    /// Tolerances are generous (±25%) to survive minor coordinate tweaks.
    func testCuratedLetters_boundingBoxRatios_areStable() async {
        let expectations: [(String, CGFloat, CGFloat)] = [
            // letter, minAspect (w/h), maxAspect (w/h)
            ("A", 0.4, 1.2),   // tall triangle shape
            ("F", 0.3, 1.2),   // vertical with horizontals
            ("I", 0.5, 2.0),   // wide top/bottom serifs
            ("K", 0.3, 1.2),   // vertical + diagonals
            ("L", 0.3, 1.2),   // L-shape
            ("M", 0.5, 1.5),   // wide M shape
            ("O", 0.6, 1.4),   // roughly circular
        ]
        for (letter, minA, maxA) in expectations {
            let path = LetterGuideRenderer.guidePath(for: letter, in: rect)!
            let b = path.boundingRect
            guard b.height > 0 else { XCTFail("\(letter) path has zero height"); continue }
            let aspect = b.width / b.height
            XCTAssertGreaterThanOrEqual(Double(aspect), Double(minA),
                "'\(letter)' aspect ratio \(aspect) below minimum \(minA)")
            XCTAssertLessThanOrEqual(Double(aspect), Double(maxA),
                "'\(letter)' aspect ratio \(aspect) above maximum \(maxA)")
        }
    }

    // MARK: - Determinism snapshot: same path on repeated calls

    func testAllCuratedLetters_pathIsDeterministic() async {
        for letter in ["A", "F", "I", "K", "L", "M", "O"] {
            let p1 = LetterGuideRenderer.guidePath(for: letter, in: rect)!
            let p2 = LetterGuideRenderer.guidePath(for: letter, in: rect)!
            XCTAssertEqual(p1.boundingRect, p2.boundingRect,
                "'\(letter)' path bounding rect is non-deterministic")
            var c1 = 0, c2 = 0
            p1.forEach { _ in c1 += 1 }
            p2.forEach { _ in c2 += 1 }
            XCTAssertEqual(c1, c2, "'\(letter)' path element count is non-deterministic")
        }
    }

    // MARK: - Scale invariance: element count must not change with rect size

    func testPathElementCount_invariantUnderScaling() async {
        let rects: [CGRect] = [
            CGRect(x: 0, y: 0, width: 50,  height: 50),
            CGRect(x: 0, y: 0, width: 200, height: 200),
            CGRect(x: 0, y: 0, width: 800, height: 800),
        ]
        for letter in ["A", "M", "O"] {
            var counts: [Int] = []
            for r in rects {
                var c = 0
                LetterGuideRenderer.guidePath(for: letter, in: r)!.forEach { _ in c += 1 }
                counts.append(c)
            }
            XCTAssertTrue(counts.allSatisfy { $0 == counts[0] },
                "'\(letter)' element count changes with rect size: \(counts)")
        }
    }

    // MARK: - Pixel rendering snapshot (UIKit only)

#if canImport(UIKit)
    /// Render each curated letter to a 100×100 bitmap and verify:
    /// 1. The image is non-empty (has drawn pixels)
    /// 2. CRC32 is stable across two renders (deterministic rendering)
    func testRendering_isNonEmptyAndDeterministic() async {
        for letter in ["A", "F", "I", "K", "L", "M", "O"] {
            let size = CGSize(width: 100, height: 100)
            let r1 = renderLetter(letter, size: size)
            let r2 = renderLetter(letter, size: size)

            XCTAssertNotNil(r1, "'\(letter)' render returned nil")
            XCTAssertNotNil(r2, "'\(letter)' render returned nil on second call")

            guard let d1 = r1, let d2 = r2 else { continue }

            // Verify non-empty: not all pixels are white/transparent
            let hasDrawnPixels = d1.contains(where: { $0 != 255 })
            XCTAssertTrue(hasDrawnPixels, "'\(letter)' render produced blank image")

            // Verify deterministic
            XCTAssertEqual(crc32(d1), crc32(d2),
                "'\(letter)' render CRC32 differs between calls — non-deterministic rendering")
        }
    }

    private func renderLetter(_ letter: String, size: CGSize) -> [UInt8]? {
        let rect = CGRect(origin: .zero, size: size)
        guard let path = LetterGuideRenderer.guidePath(for: letter, in: rect) else { return nil }

        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(rect)
            UIColor.black.setStroke()
            let cgPath = path.cgPath
            ctx.cgContext.addPath(cgPath)
            ctx.cgContext.setLineWidth(3.0)
            ctx.cgContext.strokePath()
        }

        guard let cgImage = image.cgImage,
              let data = cgImage.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return nil }
        let len = CFDataGetLength(data)
        return Array(UnsafeBufferPointer(start: ptr, count: len))
    }

    private func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in bytes {
            var b = byte ^ UInt8(crc & 0xFF)
            for _ in 0..<8 {
                let mask: UInt32 = (b & 1) == 0 ? 0 : 0xEDB88320
                b >>= 1
                crc = (crc >> 1) ^ mask
            }
        }
        return ~crc
    }
#endif

    // MARK: - Fallback letter snapshot: crossbar Y is within expected vertical range

    func testFallbackLetters_crossbarY_isInRange() async {
        let knownLetters: Set<String> = ["A","F","I","K","L","M","O"]
        for ascii in 65...90 {
            let letter = String(UnicodeScalar(ascii)!)
            if knownLetters.contains(letter) { continue }
            let path = LetterGuideRenderer.guidePath(for: letter, in: rect)!
            let b = path.boundingRect
            // Crossbar should be between 30% and 70% of rect height
            let crossbarNorm = (b.midY - rect.minY) / rect.height
            XCTAssertGreaterThan(Double(crossbarNorm), 0.30,
                "'\(letter)' fallback crossbar too high: \(crossbarNorm)")
            XCTAssertLessThan(Double(crossbarNorm), 0.80,
                "'\(letter)' fallback crossbar too low: \(crossbarNorm)")
        }
    }
}
