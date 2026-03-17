//  TracingViewModelShowGhostTests.swift
//  BuchstabenNativeTests
//
//  Regression tests for showGhost state reset behavior in TracingViewModel.
//  Uses Swift Testing framework with @Test macros and #expect() assertions.
//  Validates that ghost guide is properly reset when navigating between letters.

import Testing
@testable import BuchstabenNative

@MainActor
@Suite("TracingViewModel showGhost reset tests")
struct TracingViewModelShowGhostTests {

    @Test("showGhost is reset to false when nextLetter is called")
    func nextLetterResetsGhost() {
        let viewModel = TracingViewModel()
        viewModel.showGhost = true
        viewModel.nextLetter()
        #expect(viewModel.showGhost == false)
    }

    @Test("showGhost is reset to false when previousLetter is called")
    func previousLetterResetsGhost() {
        let viewModel = TracingViewModel()
        // Navigate away first so previousLetter() has room to go back
        viewModel.nextLetter()
        viewModel.showGhost = true
        viewModel.previousLetter()
        #expect(viewModel.showGhost == false)
    }

    @Test("showGhost is reset to false when randomLetter is called")
    func randomLetterResetsGhost() {
        let viewModel = TracingViewModel()
        viewModel.showGhost = true
        viewModel.randomLetter()
        #expect(viewModel.showGhost == false)
    }

    @Test("showGhost survives resetLetter for same letter")
    func resetLetterPreservesGhost() {
        let viewModel = TracingViewModel()
        viewModel.showGhost = true
        viewModel.resetLetter()
        #expect(viewModel.showGhost == true,
                "showGhost should survive resetLetter — user intent was to retry, not navigate")
    }

    @Test("toggleGhost switches showGhost state")
    func toggleGhostSwitchesState() {
        let viewModel = TracingViewModel()
        let initialState = viewModel.showGhost
        viewModel.toggleGhost()
        #expect(viewModel.showGhost == !initialState)
        viewModel.toggleGhost()
        #expect(viewModel.showGhost == initialState)
    }

    @Test("nextAudioVariant does not affect showGhost")
    func nextAudioVariantPreservesGhost() {
        let viewModel = TracingViewModel()
        viewModel.showGhost = true
        viewModel.nextAudioVariant()
        #expect(viewModel.showGhost == true)
    }

    @Test("previousAudioVariant does not affect showGhost")
    func previousAudioVariantPreservesGhost() {
        let viewModel = TracingViewModel()
        viewModel.showGhost = true
        viewModel.previousAudioVariant()
        #expect(viewModel.showGhost == true)
    }

    @Test("showGhost resets for each new letter in navigation sequence")
    func multipleNavigationsResetGhost() {
        let viewModel = TracingViewModel()

        // First letter: enable ghost
        viewModel.showGhost = true
        #expect(viewModel.showGhost == true)

        // Navigate to next: ghost resets
        viewModel.nextLetter()
        #expect(viewModel.showGhost == false)

        // Re-enable ghost
        viewModel.showGhost = true
        #expect(viewModel.showGhost == true)

        // Navigate again: ghost resets again
        viewModel.nextLetter()
        #expect(viewModel.showGhost == false)
    }
}
