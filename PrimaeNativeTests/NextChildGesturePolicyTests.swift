// NextChildGesturePolicyTests.swift
// PrimaeNativeTests
//
// Audit R-043: the rail double-tap that reveals the proctor's "Nächstes
// Kind" control must accept direct finger touch only. The child's Apple
// Pencil is the tracing instrument, so a pencil (or any non-finger input)
// must not be able to reach the enrolment path. `WorldSwitcherRail` hands
// `NextChildGesturePolicy.inputKinds` straight to
// `onTapGesture(count: 2, inputKinds:)`, so pinning the policy pins the
// gesture's input filter.

import Testing
import SwiftUI
@testable import PrimaeNative

@Suite struct NextChildGesturePolicyTests {

    @Test func fingerTouchEnablesEnrolment() {
        #expect(NextChildGesturePolicy.enablesEnrolment(.directTouch))
    }

    @Test func pencilIsRefused() {
        #expect(!NextChildGesturePolicy.enablesEnrolment(.pencil))
    }

    @Test func indirectTouchIsRefused() {
        #expect(!NextChildGesturePolicy.enablesEnrolment(.indirectTouch))
    }

    @Test func pointerIsRefused() {
        #expect(!NextChildGesturePolicy.enablesEnrolment(.pointer))
    }

    @Test func everyInputKindTogetherIsRefused() {
        #expect(!NextChildGesturePolicy.enablesEnrolment(.all))
    }

    /// The gesture is handed exactly this set; anything wider lets a
    /// non-finger input through, anything narrower disables the gesture.
    @Test func gestureIsGivenDirectTouchExactly() {
        #expect(NextChildGesturePolicy.inputKinds == .directTouch)
    }
}
