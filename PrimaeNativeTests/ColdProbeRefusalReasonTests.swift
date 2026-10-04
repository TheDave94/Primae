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

/// A `LetterResourceProviding` that finds nothing — simulates a study
/// device whose bundle scan genuinely turned up zero letters (2026-09-15,
/// second pass: `startColdProbe` used to check its own guards only, not
/// `sessionBlockReason`, so this exact scenario returned "success" while
/// silently doing nothing underneath).
private struct EmptyResourceProvider: LetterResourceProviding {
    let bundle: Bundle = .main
    var searchBundles: [Bundle] { [bundle] }
    func allResourceURLs() -> [URL] { [] }
    func resourceURL(for relativePath: String) -> URL? { nil }
}

@Suite(.serialized) @MainActor struct ColdProbeRefusalReasonTests {

    /// Every fixture letter carries a phoneme take: the stub arm is
    /// phoneme, and since P2 (2026-10-04) a probe in a sound arm is refused
    /// without its recording — see the `armAudioMissing` tests below.
    private func makeAsset(_ name: String,
                           base: String,
                           letterCase: LetterAsset.LetterCase,
                           phonemeFiles: [String]? = nil) -> LetterAsset {
        LetterAsset(id: name, name: name, baseLetter: base, letterCase: letterCase,
                    audioFiles: [],
                    strokes: LetterStrokes(letter: name, checkpointRadius: 0.1, strokes: []),
                    phonemeAudioFiles: phonemeFiles ?? ["\(name)_phoneme1.mp3"])
    }

    /// Stub subset is AFI ("A" trained, "L" untrained) — mirrors
    /// StudyLetterSetTests.makeVM.
    private func makeVM(studyMode: Bool, arm: PilotAudioCondition = .phoneme) -> TracingViewModel {
        var deps = TracingDependencies.stub
        deps.studyMode = studyMode
        deps.thesisCondition = .threePhase
        deps.audioCondition = arm
        let vm = TracingViewModel(deps)
        vm.letters = TrainedLetterSubset.studyLetters.map {
            makeAsset($0, base: $0, letterCase: .upper)
        }
        return vm
    }

    /// Replace A with a copy that has NO phoneme take.
    private func dropPhonemeTake(ofA vm: TracingViewModel) {
        vm.letters = vm.letters.map {
            $0.name == "A" ? makeAsset("A", base: "A", letterCase: .upper, phonemeFiles: []) : $0
        }
    }

    // MARK: - P2: a probe must sound in a sound arm (2026-10-04)
    //
    // Mutation check: delete the `probeArmAudioMissingReason` call in
    // `startColdProbe` → `phonemeProbeWithoutRecordingIsRefused` goes RED
    // (the probe starts and lands in freeWrite). The other two are the
    // controls that keep the refusal from over-reaching.

    @Test("P2: a phoneme-arm probe of a letter with no phoneme take is refused, every kind")
    func phonemeProbeWithoutRecordingIsRefused() {
        for kind in [StudyProbe.pretest, .delayed] {
            let vm = makeVM(studyMode: true, arm: .phoneme)
            dropPhonemeTake(ofA: vm)
            let reason = vm.startColdProbe(letter: "A", kind: kind)
            #expect(reason?.contains("Phonem-Aufnahme") == true,
                    "\(kind): a probe that would be written in silence in a sound arm was not refused: \(String(describing: reason))")
            #expect(vm.currentProbe == nil, "\(kind): the refused probe still started")
        }
    }

    @Test("P2 control: the same letter is probed in the silent arm, which needs no recording")
    func silentArmProbeNeedsNoRecording() {
        let vm = makeVM(studyMode: true, arm: .silent)
        dropPhonemeTake(ofA: vm)
        #expect(vm.startColdProbe(letter: "A", kind: .pretest) == nil)
        #expect(vm.currentProbe == .pretest)
    }

    @Test("P2 control: a phoneme-arm probe WITH its recording starts")
    func phonemeProbeWithRecordingStarts() {
        let vm = makeVM(studyMode: true, arm: .phoneme)
        #expect(vm.probeArmAudioMissingReason(for: vm.letters.first { $0.name == "A" }!) == nil)
        #expect(vm.startColdProbe(letter: "A", kind: .pretest) == nil)
        #expect(vm.currentProbe == .pretest)
    }

    @Test("P2: the spatial arm's probe needs the bundled carrier, and this bundle has it")
    func spatialProbeChecksTheCarrier() {
        // The missing-carrier branch cannot be driven: `carrierToneURL()`
        // reads the bundle and has no seam. This pins the present half
        // — with the carrier bundled, a spatial probe is not refused.
        let vm = makeVM(studyMode: true, arm: .spatial)
        #expect(SpatialSonification.carrierToneURL() != nil, "precondition: the carrier is bundled")
        #expect(vm.startColdProbe(letter: "A", kind: .pretest) == nil)
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

    /// The exact scenario this second pass closes: a study device whose
    /// bundle scan found zero letters. Goes through the REAL init path
    /// (unlike `makeVM` above, which pokes `vm.letters` directly after
    /// construction) — `EmptyResourceProvider` drives
    /// `LetterRepository.loadBundledLettersOnly()` to genuinely fail, so
    /// `studyLetterSourceFailure` and `sessionBlockReason` are set by the
    /// production code path, not by the test.
    @Test("a probe on a device with zero bundled letters is refused, not silently no-op'd")
    func zeroLettersFromBundleScan_refusesLoudly() {
        var deps = TracingDependencies.stub
        deps.studyMode = true
        deps.thesisCondition = .threePhase
        deps.repo = LetterRepository(resources: EmptyResourceProvider(), cache: NullLetterCache())
        let vm = TracingViewModel(deps)

        #expect(vm.letters.isEmpty, "precondition: the bundle scan found nothing")
        #expect(vm.sessionBlockReason != nil,
                "precondition: the existing studyPreconditionFailure mechanism must catch this")

        let reason = vm.startColdProbe(letter: "A", kind: .pretest)
        #expect(reason != nil, "a probe on an empty-letters device must return a refusal, not nil")
        #expect(vm.currentProbe == nil, "no probe may appear to have started")
    }
}
