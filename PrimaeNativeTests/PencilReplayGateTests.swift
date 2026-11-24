// PencilReplayGateTests.swift
// PrimaeNativeTests
//
// U5 (audit R-096): the Apple Pencil squeeze is wired next to the
// double-tap, and both go through ONE decision, `PencilReplayGate`. A
// `UIPencilInteraction` delegate callback cannot be driven from a test
// (`UIPencilInteraction.Tap`/`.Squeeze` have no public initialiser), so the
// decision is extracted and pinned here; the coordinator only forwards
// `.tap` / `.squeeze(phase)`. A squeeze-capable Pencil on the iPad is still
// the only instrument that shows the system delivers the callback.

import Testing
import UIKit
@testable import PrimaeNative

@Suite struct PencilReplayGateTests {

    private static let squeezePhases: [UIPencilInteraction.Phase] =
        [.began, .changed, .ended, .cancelled]
    private static let preferredActions: [UIPencilPreferredAction] =
        [.ignore, .switchEraser, .switchPrevious, .showColorPalette,
         .showInkAttributes, .showContextualPalette, .runSystemShortcut]

    @Test func squeezeEndedReplays() {
        #expect(PencilReplayGate.shouldReplay(.squeeze(.ended),
                                              preferredAction: .showContextualPalette,
                                              studyMode: false))
    }

    @Test("squeeze phases other than .ended do nothing",
          arguments: [UIPencilInteraction.Phase.began, .changed, .cancelled])
    func squeezeNonEndedPhasesDoNothing(phase: UIPencilInteraction.Phase) {
        #expect(!PencilReplayGate.shouldReplay(.squeeze(phase),
                                               preferredAction: .showContextualPalette,
                                               studyMode: false))
    }

    /// One physical squeeze delivers began, changed..., ended: exactly one
    /// replay decision comes out of it.
    @Test func oneSqueezeFiresOnce() {
        let sequence: [UIPencilInteraction.Phase] = [.began, .changed, .changed, .changed, .ended]
        let fired = sequence.filter {
            PencilReplayGate.shouldReplay(.squeeze($0),
                                          preferredAction: .switchEraser,
                                          studyMode: false)
        }
        #expect(fired.count == 1)
    }

    @Test func preferredIgnoreDoesNothing() {
        #expect(!PencilReplayGate.shouldReplay(.squeeze(.ended), preferredAction: .ignore, studyMode: false))
        #expect(!PencilReplayGate.shouldReplay(.tap, preferredAction: .ignore, studyMode: false))
    }

    @Test func systemShortcutIsLeftToTheSystem() {
        #expect(!PencilReplayGate.shouldReplay(.squeeze(.ended), preferredAction: .runSystemShortcut, studyMode: false))
        #expect(!PencilReplayGate.shouldReplay(.tap, preferredAction: .runSystemShortcut, studyMode: false))
    }

    @Test func studyModeIsANoOp() {
        for action in Self.preferredActions {
            #expect(!PencilReplayGate.shouldReplay(.tap, preferredAction: action, studyMode: true))
            for phase in Self.squeezePhases {
                #expect(!PencilReplayGate.shouldReplay(.squeeze(phase), preferredAction: action, studyMode: true))
            }
        }
    }

    /// A completed squeeze and a double-tap reach the same decision under
    /// every preference and both study settings.
    @Test func squeezeEndedDecidesLikeTap() {
        for action in Self.preferredActions {
            for study in [false, true] {
                #expect(PencilReplayGate.shouldReplay(.squeeze(.ended), preferredAction: action, studyMode: study)
                        == PencilReplayGate.shouldReplay(.tap, preferredAction: action, studyMode: study),
                        "action \(action.rawValue), study \(study)")
            }
        }
    }

    @Test func tapReplaysUnderAnAppActionPreference() {
        #expect(PencilReplayGate.shouldReplay(.tap, preferredAction: .switchEraser, studyMode: false))
    }

    @Test func debounceAdmitsOncePerBurst() {
        var d = ReplayDebounce()
        let first = d.admit(now: 100)
        let soon = d.admit(now: 100.1)
        let justBefore = d.admit(now: 100 + ReplayDebounce.minimumInterval - 0.001)
        let after = d.admit(now: 100 + ReplayDebounce.minimumInterval)
        #expect(first)
        #expect(!soon)
        #expect(!justBefore)
        #expect(after)
    }
}
