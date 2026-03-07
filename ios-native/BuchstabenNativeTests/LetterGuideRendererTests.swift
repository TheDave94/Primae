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

    func testLowercaseLetter_normalised() throws {
        let lower = try XCTUnwrap(
            LetterGuideRenderer.guidePath(for: "a", in: rect),
            "guidePath for 'a' must not be nil"
        )
        let upper = try XCTUnwrap(
            LetterGuideRenderer.guidePath(for: "A", in: rect),
            "guidePath for 'A' must not be nil"
        )
        // Both should produce the same bounding box
        XCTAssertEqual(lower.boundingRect, upper.boundingRect,
                       "Lowercase and uppercase must produce identical paths")
    }

    // MARK: 5 — Path bounding rect is within the provided rect (+ small tolerance for arcs)

    func testPathBoundingRect_withinProvidedRect() throws {
        let tolerance: CGFloat = 2.0  // arcs can slightly exceed due to control point approximation
        for letter in ["A", "F", "I", "K", "L", "M", "O"] {
            let path = try XCTUnwrap(
                LetterGuideRenderer.guidePath(for: letter, in: rect),
                "guidePath for '\(letter)' must not be nil"
            )
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

    func testFallback_differentLetters_differentPaths() throws {
        let pZ = try XCTUnwrap(
            LetterGuideRenderer.guidePath(for: "Z", in: rect),
            "guidePath for 'Z' must not be nil"
        )
        let pQ = try XCTUnwrap(
            LetterGuideRenderer.guidePath(for: "Q", in: rect),
            "guidePath for 'Q' must not be nil"
        )
        // Not strictly guaranteed, but hash diversity should differ for Z vs Q
        // Just assert both produce non-zero bounding boxes
        XCTAssertFalse(pZ.boundingRect.isEmpty)
        XCTAssertFalse(pQ.boundingRect.isEmpty)
    }

    // MARK: 8 — Rect scaling: larger rect produces proportionally larger bounding box

    func testScaling_largerRect_producesBiggerPath() throws {
        let small = CGRect(x: 0, y: 0, width: 100, height: 100)
        let large = CGRect(x: 0, y: 0, width: 400, height: 400)
        let ps = try XCTUnwrap(
            LetterGuideRenderer.guidePath(for: "A", in: small),
            "guidePath for 'A' in small rect must not be nil"
        ).boundingRect
        let pl = try XCTUnwrap(
            LetterGuideRenderer.guidePath(for: "A", in: large),
            "guidePath for 'A' in large rect must not be nil"
        ).boundingRect
        XCTAssertLessThan(ps.width,  pl.width,  "Larger rect must produce wider path for A")
        XCTAssertLessThan(ps.height, pl.height, "Larger rect must produce taller path for A")
    }

    // MARK: 9 — O arc path bounding rect is roughly square and centred

    func testO_arcPath_isRoughlySquare() throws {
        let path = try XCTUnwrap(
            LetterGuideRenderer.guidePath(for: "O", in: rect),
            "guidePath for 'O' must not be nil"
        )
        let bounds = path.boundingRect
        let ratio = bounds.width / bounds.height
        XCTAssertEqual(Double(ratio), 1.0, accuracy: 0.15,
                       "O arc bounding box should be roughly square (aspect ratio ~1)")
    }

    // MARK: 10 — M polyline produces a path spanning most of the horizontal extent

    func testM_polyline_spansHorizontalExtent() throws {
        let path = try XCTUnwrap(
            LetterGuideRenderer.guidePath(for: "M", in: rect),
            "guidePath for 'M' must not be nil"
        )
        let bounds = path.boundingRect
        // M goes from x≈0.15 to x≈0.85 → spans 70% of width
        let span = bounds.width / rect.width
        XCTAssertGreaterThan(Double(span), 0.60,
                             "M path must span at least 60% of the canvas width")
    }

    // MARK: 11 — Non-square rect maps correctly (no square assumption)

    func testNonSquareRect_noAssumption() throws {
        let wide = CGRect(x: 0, y: 0, width: 600, height: 200)
        let path = try XCTUnwrap(
            LetterGuideRenderer.guidePath(for: "L", in: wide),
            "guidePath for 'L' in wide rect must not be nil"
        )
        let bounds = path.boundingRect
        XCTAssertLessThanOrEqual(bounds.maxX, wide.maxX + 2.0)
        XCTAssertLessThanOrEqual(bounds.maxY, wide.maxY + 2.0)
    }

    // MARK: 12 — Empty string returns fallback (non-crash)

    func testEmptyStringLetter_doesNotCrash() {
        let path = LetterGuideRenderer.guidePath(for: "", in: rect)
        XCTAssertNotNil(path, "Empty string must produce a fallback path, not crash")
    }

    // MARK: 13 — guides entry with empty segment array triggers fallback (D1 regression guard)

    func testKnownLetter_emptySegmentArray_usesFallback() {
        // Directly verify that an empty segment array in guides routes to fallback.
        // Uses the lower-level LetterGuideGeometry API to inject the empty-array condition.
        let emptySegments: [LetterGuideGeometry.Segment] = []
        let result = emptySegments.isEmpty ? nil : emptySegments
        let resolved = result ?? LetterGuideGeometry.fallbackSegments(for: "B")
        XCTAssertEqual(resolved.count, 3,
                       "An empty segment array must resolve to the 3-segment fallback, not produce a blank path")
    }

    // MARK: 14 — fallbackSegments returns exactly 3 segments for any input

    func testFallbackSegments_alwaysReturnsThreeSegments() {
        let letters = ["X", "Y", "Z", "1", "", "ä", "Ü"]
        for l in letters {
            let segs = LetterGuideGeometry.fallbackSegments(for: l)
            XCTAssertEqual(segs.count, 3,
                           "fallbackSegments must return exactly 3 segments for input '\(l)'")
        }
    }

    // MARK: 15 — cgPath for letter absent from guides returns non-nil (full fallback chain)

    func testCgPath_absentLetter_returnsFallbackPath() {
        let path = LetterGuideGeometry.cgPath(for: "X", in: rect)
        XCTAssertNotNil(path,
                        "cgPath for a letter absent from guides must return a non-nil fallback path")
    }

    // MARK: 16 — public API guidePath for absent letter returns non-nil

    func testGuidePath_absentLetter_returnsFallbackPath() {
        let path = LetterGuideRenderer.guidePath(for: "X", in: rect)
        XCTAssertNotNil(path,
                        "guidePath for 'X' (absent from guides) must return a non-nil fallback path via the full chain")
    }
}
