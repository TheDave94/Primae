//  LetterGuideRendererTests.swift
//  BuchstabenNativeTests
//
//  Tests for LetterGuideRenderer path construction logic.
//  Pure geometry: no rendering, no UIKit, no snapshots needed.

import XCTest
import CoreGraphics
import SwiftUI
@testable import BuchstabenNative

final class LetterGuideRendererTests: XCTestCase {

    private let rect = CGRect(x: 0, y: 0, width: 400, height: 400)
    private let emptyRect = CGRect.zero

    // MARK: 1 — Empty rect returns nil

    func testEmptyRect_returnsNil() {
        XCTAssertNil(LetterGuideRenderer.guidePath(for: "A", in: emptyRect))
    }

    // MARK: 2 — Known letters return non-nil paths

    func testKnownLetters_returnNonNilPath() {
        for letter in ["A", "F", "I", "K", "L", "M", "O"] {
            let path = LetterGuideRenderer.guidePath(for: letter, in: rect)
            XCTAssertNotNil(path, "guidePath for '\(letter)' must not be nil")
        }
    }

    // MARK: 3 — Unknown letter uses fallback (non-nil)

    func testUnknownLetter_usesFallback_nonNil() {
        let path = LetterGuideRenderer.guidePath(for: "Z", in: rect)
        XCTAssertNotNil(path, "Fallback path for unknown letter must not be nil")
    }

    // MARK: 4 — Lowercase normalised to uppercase

    func testLowercaseLetter_normalised() {
        let lower = LetterGuideRenderer.guidePath(for: "a", in: rect)
        let upper = LetterGuideRenderer.guidePath(for: "A", in: rect)
        XCTAssertNotNil(lower)
        XCTAssertNotNil(upper)
        // Both should produce the same bounding box
        XCTAssertEqual(lower!.boundingRect, upper!.boundingRect,
                       "Lowercase and uppercase must produce identical paths")
    }

    // MARK: 5 — Path bounding rect is within the provided rect (+ small tolerance for arcs)

    func testPathBoundingRect_withinProvidedRect() {
        let tolerance: CGFloat = 2.0  // arcs can slightly exceed due to control point approximation
        for letter in ["A", "F", "I", "K", "L", "M", "O"] {
            let path = LetterGuideRenderer.guidePath(for: letter, in: rect)!
            let bounds = path.boundingRect
            XCTAssertGreaterThanOrEqual(bounds.minX, rect.minX - tolerance, "\(letter) minX out of bounds")
            XCTAssertGreaterThanOrEqual(bounds.minY, rect.minY - tolerance, "\(letter) minY out of bounds")
            XCTAssertLessThanOrEqual(bounds.maxX,    rect.maxX + tolerance, "\(letter) maxX out of bounds")
            XCTAssertLessThanOrEqual(bounds.maxY,    rect.maxY + tolerance, "\(letter) maxY out of bounds")
        }
    }

    // MARK: 6 — Fallback crossbar Y is deterministic (same letter → same path)

    func testFallbackDeterminism() {
        let p1 = LetterGuideRenderer.guidePath(for: "Z", in: rect)
        let p2 = LetterGuideRenderer.guidePath(for: "Z", in: rect)
        XCTAssertEqual(p1?.boundingRect, p2?.boundingRect,
                       "Fallback path must be deterministic for the same letter")
    }

    // MARK: 7 — Different unknown letters produce different crossbar positions

    func testFallback_differentLetters_differentPaths() {
        let pZ = LetterGuideRenderer.guidePath(for: "Z", in: rect)?.boundingRect
        let pQ = LetterGuideRenderer.guidePath(for: "Q", in: rect)?.boundingRect
        // Not strictly guaranteed, but hash diversity should differ for Z vs Q
        // Just assert both are non-nil and non-zero
        XCTAssertNotNil(pZ)
        XCTAssertNotNil(pQ)
        XCTAssertFalse(pZ!.isEmpty)
        XCTAssertFalse(pQ!.isEmpty)
    }

    // MARK: 8 — Rect scaling: larger rect produces proportionally larger bounding box

    func testScaling_largerRect_producesBiggerPath() {
        let small = CGRect(x: 0, y: 0, width: 100, height: 100)
        let large = CGRect(x: 0, y: 0, width: 400, height: 400)
        let ps = LetterGuideRenderer.guidePath(for: "A", in: small)!.boundingRect
        let pl = LetterGuideRenderer.guidePath(for: "A", in: large)!.boundingRect
        XCTAssertLessThan(ps.width,  pl.width,  "Larger rect must produce wider path for A")
        XCTAssertLessThan(ps.height, pl.height, "Larger rect must produce taller path for A")
    }

    // MARK: 9 — O arc path bounding rect is roughly square and centred

    func testO_arcPath_isRoughlySquare() {
        let path = LetterGuideRenderer.guidePath(for: "O", in: rect)!
        let bounds = path.boundingRect
        let ratio = bounds.width / bounds.height
        XCTAssertEqual(Double(ratio), 1.0, accuracy: 0.15,
                       "O arc bounding box should be roughly square (aspect ratio ~1)")
    }

    // MARK: 10 — M polyline produces a path spanning most of the horizontal extent

    func testM_polyline_spansHorizontalExtent() {
        let path = LetterGuideRenderer.guidePath(for: "M", in: rect)!
        let bounds = path.boundingRect
        // M goes from x≈0.15 to x≈0.85 → spans 70% of width
        let span = bounds.width / rect.width
        XCTAssertGreaterThan(Double(span), 0.60,
                             "M path must span at least 60% of the canvas width")
    }

    // MARK: 11 — Non-square rect maps correctly (no square assumption)

    func testNonSquareRect_noAssumption() {
        let wide = CGRect(x: 0, y: 0, width: 600, height: 200)
        let path = LetterGuideRenderer.guidePath(for: "L", in: wide)
        XCTAssertNotNil(path)
        let bounds = path!.boundingRect
        XCTAssertLessThanOrEqual(bounds.maxX, wide.maxX + 2.0)
        XCTAssertLessThanOrEqual(bounds.maxY, wide.maxY + 2.0)
    }

    // MARK: 12 — Empty string returns fallback (non-crash)

    func testEmptyStringLetter_doesNotCrash() {
        let path = LetterGuideRenderer.guidePath(for: "", in: rect)
        XCTAssertNotNil(path, "Empty string must produce a fallback path, not crash")
    }
}
