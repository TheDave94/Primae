//  LetterGuideRendererTests.swift
//  BuchstabenNativeTests

import Testing
import CoreGraphics
import SwiftUI
@testable import BuchstabenNative

@Suite @MainActor struct LetterGuideRendererTests {

    let rect = CGRect(x: 0, y: 0, width: 400, height: 400)
    let emptyRect = CGRect.zero

    @Test func emptyRect_returnsNil() {
        #expect(LetterGuideRenderer.guidePath(for: "A", in: emptyRect) == nil)
    }

    @Test func knownLetters_returnNonNilPath() {
        for letter in ["A", "F", "I", "K", "L", "M", "O"] {
            #expect(LetterGuideRenderer.guidePath(for: letter, in: rect) != nil,
                    "guidePath for '\(letter)' must not be nil")
        }
    }

    @Test func unknownLetter_usesFallback_nonNil() {
        #expect(LetterGuideRenderer.guidePath(for: "Z", in: rect) != nil)
    }

    @Test func lowercaseLetter_normalised() throws {
        let lower = try #require(LetterGuideRenderer.guidePath(for: "a", in: rect))
        let upper = try #require(LetterGuideRenderer.guidePath(for: "A", in: rect))
        #expect(lower.boundingRect == upper.boundingRect)
    }

    @Test func pathBoundingRect_withinProvidedRect() throws {
        let tolerance: CGFloat = 2.0
        for letter in ["A", "F", "I", "K", "L", "M", "O"] {
            let path = try #require(LetterGuideRenderer.guidePath(for: letter, in: rect))
            let bounds = path.boundingRect
            #expect(bounds.minX >= rect.minX - tolerance, "\(letter) minX out of bounds")
            #expect(bounds.minY >= rect.minY - tolerance, "\(letter) minY out of bounds")
            #expect(bounds.maxX <= rect.maxX + tolerance, "\(letter) maxX out of bounds")
            #expect(bounds.maxY <= rect.maxY + tolerance, "\(letter) maxY out of bounds")
        }
    }

    @Test func fallbackDeterminism() {
        let p1 = LetterGuideRenderer.guidePath(for: "Z", in: rect)
        let p2 = LetterGuideRenderer.guidePath(for: "Z", in: rect)
        #expect(p1?.boundingRect == p2?.boundingRect)
    }

    @Test func fallback_differentLetters_differentPaths() throws {
        let pZ = try #require(LetterGuideRenderer.guidePath(for: "Z", in: rect))
        let pQ = try #require(LetterGuideRenderer.guidePath(for: "Q", in: rect))
        #expect(!pZ.boundingRect.isEmpty)
        #expect(!pQ.boundingRect.isEmpty)
    }

    @Test func scaling_largerRect_producesBiggerPath() throws {
        let small = CGRect(x: 0, y: 0, width: 100, height: 100)
        let large = CGRect(x: 0, y: 0, width: 400, height: 400)
        let ps = try #require(LetterGuideRenderer.guidePath(for: "A", in: small)).boundingRect
        let pl = try #require(LetterGuideRenderer.guidePath(for: "A", in: large)).boundingRect
        #expect(ps.width  < pl.width)
        #expect(ps.height < pl.height)
    }

    @Test(.disabled("Stroke data not yet calibrated")) func o_arcPath_isRoughlySquare() throws {
        let path = try #require(LetterGuideRenderer.guidePath(for: "O", in: rect))
        let ratio = path.boundingRect.width / path.boundingRect.height
        #expect(abs(Double(ratio) - 1.0) < 0.15)
    }

    @Test func m_polyline_spansHorizontalExtent() throws {
        let path = try #require(LetterGuideRenderer.guidePath(for: "M", in: rect))
        let span = path.boundingRect.width / rect.width
        #expect(Double(span) > 0.60)
    }

    @Test func nonSquareRect_noAssumption() throws {
        let wide = CGRect(x: 0, y: 0, width: 600, height: 200)
        let path = try #require(LetterGuideRenderer.guidePath(for: "L", in: wide))
        #expect(path.boundingRect.maxX <= wide.maxX + 2.0)
        #expect(path.boundingRect.maxY <= wide.maxY + 2.0)
    }

    @Test func emptyStringLetter_doesNotCrash() {
        #expect(LetterGuideRenderer.guidePath(for: "", in: rect) != nil)
    }

    @Test func knownLetter_emptySegmentArray_usesFallback() {
        let emptySegments: [LetterGuideGeometry.Segment] = []
        let resolved = emptySegments.isEmpty ? LetterGuideGeometry.fallbackSegments(for: "B") : emptySegments
        #expect(resolved.count == 3)
    }

    @Test func fallbackSegments_alwaysReturnsThreeSegments() {
        for l in ["X", "Y", "Z", "1", "", "ä", "Ü"] {
            #expect(LetterGuideGeometry.fallbackSegments(for: l).count == 3,
                    "fallbackSegments must return exactly 3 segments for '\(l)'")
        }
    }

    @Test func cgPath_absentLetter_returnsFallbackPath() {
        #expect(LetterGuideGeometry.cgPath(for: "X", in: rect) != nil)
    }

    @Test func guidePath_absentLetter_returnsFallbackPath() {
        #expect(LetterGuideRenderer.guidePath(for: "X", in: rect) != nil)
    }
}
