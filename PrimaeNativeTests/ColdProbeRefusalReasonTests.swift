// ColdProbeRefusalReasonTests.swift
// PrimaeNativeTests
//
// The research-dashboard probe buttons ("Vortest starten: X", "Post-Test
// starten: X", "Nachtest starten: X") used to call `startColdProbe`
// silently — a refusal (wrong studyMode, wrong letter for the kind, or a
// stale participant identity after a reset/restore) looked identical, from
// the proctor's seat, to the dismissal doing nothing. `startColdProbe` and
// `startPostTest` now return a short German proctor-facing reason string
// on refusal (nil on success) so the dashboard can surface it in an
// alert instead of swallowing it. This file pins that contract at the VM
// level; it does not touch the SwiftUI alert wiring, which cannot be
// exercised headlessly.

import Testing
import Foundation
import CoreGraphics
@testable import PrimaeNative

@Suite(.serialized) @MainActor struct ColdProbeRefusalReasonTests {

    private func makeAsset(_ name: String,
                           base: String,
                           letterCase: LetterAsset.LetterCase) -> LetterAsset {
        LetterAsset(id: name, name: name, baseLetter: base, letterCase: letterCase,
                    audioFiles: [],
                    strokes: LetterStrokes(letter: name, checkpointRadius: 0.1, strokes: []))
    }

    /// Stub subset is AFI ("A" trained, "L" untrained) — mirrors
    /// StudyLetterSetTests.makeVM.
    private func makeVM(studyMode: Bool) -> TracingViewModel {
        var deps = TracingDependencies.stub
        deps.studyMode = studyMode
        deps.thesisCondition = .threePhase
        let vm = TracingViewModel(deps)
        vm.letters = TrainedLetterSubset.studyLetters.map {
            makeAsset($0, base: $0, letterCase: .upper)
        }
        return vm
    }

    @Test("a permitted probe returns nil and lands in freeWrite")
    func success_returnsNil_landsInFreeWrite() {
        let vm = makeVM(studyMode: true)
        let reason = vm.startColdProbe(letter: "A", kind: .pretest)
        #expect(reason == nil)
        #expect(vm.currentLetterName == "A")
        #expect(vm.learningPhase == .freeWrite)
        #expect(vm.currentProbe == .pretest)
    }

    @Test("a post-test of a TRAINED letter returns a non-nil reason and leaves state unchanged")
    func postTestOfTrainedLetter_returnsReason_stateUnchanged() {
        let vm = makeVM(studyMode: true)
        let letterBefore = vm.currentLetterName
        let phaseBefore = vm.learningPhase
        let reason = vm.startColdProbe(letter: "A", kind: .posttest)   // A is trained (stub AFI)
        #expect(reason != nil, "a trained letter must be refused for .posttest")
        #expect(vm.currentLetterName == letterBefore)
        #expect(vm.learningPhase == phaseBefore)

        // startPostTest is a thin wrapper over the same guard and must
        // propagate the same reason.
        let wrapperReason = vm.startPostTest(letter: "A")
        #expect(wrapperReason != nil)
        #expect(vm.currentLetterName == letterBefore)
        #expect(vm.learningPhase == phaseBefore)
    }

    @Test("after markParticipantRestored, every probe kind returns a non-nil reason")
    func afterParticipantRestored_everyProbeReturnsReason() {
        let vm = makeVM(studyMode: true)
        vm.markParticipantRestored()
        #expect(vm.sessionBlockReason != nil, "precondition: a restore genuinely blocks the session")

        let pretestReason = vm.startColdProbe(letter: "A", kind: .pretest)
        #expect(pretestReason != nil)
        #expect(vm.currentProbe == nil)

        let posttestReason = vm.startColdProbe(letter: "L", kind: .posttest)
        #expect(posttestReason != nil)
        #expect(vm.currentProbe == nil)

        let delayedReason = vm.startColdProbe(letter: "A", kind: .delayed)
        #expect(delayedReason != nil)
        #expect(vm.currentProbe == nil)
    }
}
