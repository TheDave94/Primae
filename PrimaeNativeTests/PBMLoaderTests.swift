// PBMLoaderTests.swift
// PrimaeNativeTests
//
// Regression tests for PBMLoader.decode — a parser bug here would silently
// break every letter bitmap in the app.

import Foundation
import Testing
import UIKit
@testable import PrimaeNative

@Suite struct PBMLoaderTests {

    // MARK: - P1 (ASCII)

    @Test("P1 2x2 all-white decodes to 2x2 image")
    func p1_allWhite() {
        let pbm = "P1\n2 2\n0 0\n0 0\n"
        let data = Data(pbm.utf8)
        let img  = PBMLoader.decode(data: data)
        #expect(img != nil)
        #expect(img?.size == CGSize(width: 2, height: 2))
    }

    @Test("P1 2x2 with single black pixel decodes")
    func p1_singleBlackPixel() {
        let pbm = "P1\n2 2\n1 0\n0 0\n"
        let data = Data(pbm.utf8)
        let img = PBMLoader.decode(data: data)
        #expect(img != nil)
    }

    @Test("P1 with comment lines parses correctly")
    func p1_comments() {
        let pbm = "P1\n# a comment\n3 1\n# another\n1 0 1\n"
        let data = Data(pbm.utf8)
        let img = PBMLoader.decode(data: data)
        #expect(img != nil)
        #expect(img?.size == CGSize(width: 3, height: 1))
    }

    // MARK: - P4 (binary)

    @Test("P4 8x1 row decodes to correct width")
    func p4_single_row() {
        var data = Data("P4\n8 1\n".utf8)
        data.append(0b10101010)  // 8 bits = 8 pixels
        let img = PBMLoader.decode(data: data)
        #expect(img != nil)
        #expect(img?.size == CGSize(width: 8, height: 1))
    }

    // MARK: - Robustness / malformed input

    @Test("Empty data returns nil")
    func empty_returns_nil() {
        #expect(PBMLoader.decode(data: Data()) == nil)
    }

    @Test("Non-PBM magic returns nil")
    func wrong_magic_returns_nil() {
        let data = Data("P2\n2 2\n255\n0 0 0 0\n".utf8)  // P2 = PGM, unsupported
        #expect(PBMLoader.decode(data: data) == nil)
    }

    @Test("Zero width returns nil")
    func zero_width_returns_nil() {
        let data = Data("P1\n0 5\n".utf8)
        #expect(PBMLoader.decode(data: data) == nil)
    }

    @Test("Truncated header returns nil")
    func truncated_header_returns_nil() {
        let data = Data("P1\n".utf8)
        #expect(PBMLoader.decode(data: data) == nil)
    }

    @Test("Garbage bytes do not crash")
    func garbage_does_not_crash() {
        let data = Data([0xFF, 0xFE, 0xFD, 0x00, 0x01, 0x02])
        _ = PBMLoader.decode(data: data)  // must not crash
    }
}
