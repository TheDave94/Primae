// TracingDirectTouchTests.swift
// PrimaeNativeTests
//
// Audit R-091: a VoiceOver user must be able to TRACE. The canvas set
// `accessibilityElement(children: .ignore)` + label + value + actions and
// nothing else, so VoiceOver could read the canvas and run its actions, but
// the drag that draws never reached the canvas overlays.
//
// The fix is `accessibilityDirectTouch` on the canvas. SwiftUI does not
// expose the resulting accessibility tree to the test target (there is no
// public API that reads a view's `AccessibilityDirectTouchOptions` back), so
// these tests pin the value `TracingCanvasAccessibility` hands to the
// modifier — the same shape as `NextChildGesturePolicyTests` for R-043.
// They do NOT prove that VoiceOver renders a direct-touch area; only a UI
// test on hardware can observe that. What they do prove is that the canvas
// asks for direct touch, requires activation, and is silent while touched,
// so a regression that drops the modifier or one of its options goes RED
// here.

import Testing
import SwiftUI
@testable import PrimaeNative

@Suite struct TracingDirectTouchTests {

    @Test func canvasIsaDirectTouchArea() {
        #expect(TracingDirectTouchPolicy.isDirectTouchArea)
    }

    @Test func directTouchRequiresActivationSoExplorationLeavesNoInk() {
        #expect(TracingDirectTouchPolicy.requiresActivation)
    }

    @Test func directTouchIsSilentWhileTheFingerIsDown() {
        #expect(TracingDirectTouchPolicy.isSilentOnTouch)
    }

    @Test func canvasAsksForExactlyTheseTwoOptions() {
        // Not a restatement of the two tests above: it fails if a THIRD
        // option is added, which is what turns `.requiresActivation` into
        // an accidental "drawing also speaks every element".
        #expect(TracingDirectTouchPolicy.options == [.requiresActivation, .silentOnTouch])
    }
}
