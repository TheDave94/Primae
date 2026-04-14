//  LetterGuideSnapshotTests.swift
//  BuchstabenNativeTests

import Testing
import Foundation
import CoreGraphics
#if canImport(UIKit)
import UIKit
#endif
@testable import BuchstabenNative

@MainActor
struct LetterGuideSnapshotTests {

    private let rect = CGRect(x: 0, y: 0, width: 200, height: 200)

    // MARK: - Structural snapshot: path element counts per letter

    private let expectedMinElements: [String: Int] = [
        "A": 6, "F": 6, "I": 6, "K": 6, "L": 4, "M": 5, "O": 1,
    ]

    @Test(.disabled("Stroke data not yet calibrated for demo letters")) func curatedLetters_pathElementCount_isStable() {
        for (letter, minCount) in expectedMinElements {
            let path = LetterGuideRenderer.guidePath(for: letter, in: rect)!
            var count = 0
            path.forEach { _ in count += 1 }
            #expect(count >= minCount,
                "'\(letter)' path element count \(count) is below expected minimum \(minCount)")
        }
    }

    // MARK: - Bounding box ratio snapshot

    @Test(.disabled("Stroke data not yet calibrated for demo letters")) func curatedLetters_boundingBoxRatios_areStable() {
        let expectations: [(String, CGFloat, CGFloat)] = [
            ("A", 0.4, 1.2), ("F", 0.3, 1.2), ("I", 0.5, 2.0),
            ("K", 0.3, 1.2), ("L", 0.3, 1.2), ("M", 0.5, 1.5), ("O", 0.6, 1.4),
        ]
        for (letter, minA, maxA) in expectations {
            let path = LetterGuideRenderer.guidePath(for: letter, in: rect)!
            let b = path.boundingRect
            guard b.height > 0 else { Issue.record("\(letter) path has zero height"); continue }
            let aspect = b.width / b.height
            #expect(Double(aspect) >= Double(minA),
                "'\(letter)' aspect ratio \(aspect) below minimum \(minA)")
            #expect(Double(aspect) <= Double(maxA),
                "'\(letter)' aspect ratio \(aspect) above maximum \(maxA)")
        }
    }

    // MARK: - Determinism snapshot

    @Test func allCuratedLetters_pathIsDeterministic() {
        for letter in ["A", "F", "I", "K", "L", "M", "O"] {
            let p1 = LetterGuideRenderer.guidePath(for: letter, in: rect)!
            let p2 = LetterGuideRenderer.guidePath(for: letter, in: rect)!
            #expect(p1.boundingRect == p2.boundingRect,
                "'\(letter)' path bounding rect is non-deterministic")
            var c1 = 0, c2 = 0
            p1.forEach { _ in c1 += 1 }
            p2.forEach { _ in c2 += 1 }
            #expect(c1 == c2, "'\(letter)' path element count is non-deterministic")
        }
    }

    // MARK: - Scale invariance

    @Test func pathElementCount_invariantUnderScaling() {
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
            #expect(counts.allSatisfy { $0 == counts[0] },
                "'\(letter)' element count changes with rect size: \(counts)")
        }
    }

    // MARK: - Pixel rendering snapshot (UIKit only)

#if canImport(UIKit)
    @Test func rendering_isNonEmptyAndDeterministic() {
        for letter in ["A", "F", "I", "K", "L", "M", "O"] {
            let size = CGSize(width: 100, height: 100)
            let r1 = renderLetter(letter, size: size)
            let r2 = renderLetter(letter, size: size)
            #expect(r1 != nil, "'\(letter)' render returned nil")
            #expect(r2 != nil, "'\(letter)' render returned nil on second call")
            guard let d1 = r1, let d2 = r2 else { continue }
            #expect(d1.contains(where: { $0 != 255 }), "'\(letter)' render produced blank image")
            #expect(crc32(d1) == crc32(d2), "'\(letter)' render CRC32 differs — non-deterministic")
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
            ctx.cgContext.addPath(path.cgPath)
            ctx.cgContext.setLineWidth(3.0)
            ctx.cgContext.strokePath()
        }
        guard let cgImage = image.cgImage,
              let data = cgImage.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return nil }
        return Array(UnsafeBufferPointer(start: ptr, count: CFDataGetLength(data)))
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

    // MARK: - Fallback letter snapshot

    @Test func fallbackLetters_crossbarY_isInRange() {
        let knownLetters: Set<String> = ["A","F","I","K","L","M","O"]
        for ascii in 65...90 {
            let letter = String(UnicodeScalar(ascii)!)
            if knownLetters.contains(letter) { continue }
            let path = LetterGuideRenderer.guidePath(for: letter, in: rect)!
            let b = path.boundingRect
            let crossbarNorm = (b.midY - rect.minY) / rect.height
            #expect(Double(crossbarNorm) > 0.30,
                "'\(letter)' fallback crossbar too high: \(crossbarNorm)")
            #expect(Double(crossbarNorm) < 0.80,
                "'\(letter)' fallback crossbar too low: \(crossbarNorm)")
        }
    }
}
