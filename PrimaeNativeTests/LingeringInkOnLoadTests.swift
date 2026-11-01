// LingeringInkOnLoadTests.swift
// PrimaeNativeTests
//
// R-075: `load(letter:)` did not clear `lingeringInk`, so the faded snapshot
// of the previous letter's ink could still be on screen on the next letter
// (up to its 5 s timer). Loading a letter must start with empty lingering ink.

import Testing
import CoreGraphics
@testable import PrimaeNative

@MainActor
@Suite struct LingeringInkOnLoadTests {

    @Test func loadingALetterClearsLingeringInk() throws {
        let vm = TracingViewModel(.stub)
        vm.lingeringInk = [CGPoint(x: 10, y: 10), CGPoint(x: 50, y: 60)]
        #expect(!vm.lingeringInk.isEmpty)

        let target = try #require(vm.letters.first, "stub repository supplies letters")
        vm.loadLetter(name: target.name)

        #expect(vm.lingeringInk.isEmpty,
                "the previous letter's ink snapshot must not survive a letter load")
    }
}
