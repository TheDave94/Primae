// ProbeAttemptTests.swift
// R-032 (audit 2026-10-13, H2-14, D1 reconstruction #9): nothing sequenced
// the cold probes or caught a repeat. A second pretest of a letter was a
// second row with the same `probe`, told apart only by its timestamp, and
// the derived post-test takes the LAST row. Now each probe row carries its
// attempt index (n-th row of this kind for this letter, this participant),
// and the proctor is warned — never blocked (H2-14) — before a repeat or a
// post-test while the child's training set is unfinished.

import Testing
import Foundation
@testable import PrimaeNative

@Suite(.serialized) @MainActor struct ProbeAttemptTests {

    private func makeAsset(_ name: String) -> LetterAsset {
        LetterAsset(id: name, name: name, baseLetter: name, letterCase: .upper, audioFiles: [],
                    strokes: LetterStrokes(letter: name, checkpointRadius: 0.1, strokes: []),
                    phonemeAudioFiles: ["\(name)_phoneme1.mp3"])
    }

    /// Study VM over a real dashboard store (probe history lives there).
    /// Stub subset AFI: A trained, L untrained.
    private func makeVM(store: JSONParentDashboardStore) -> TracingViewModel {
        var deps = TracingDependencies.stub
        deps.studyMode = true
        deps.thesisCondition = .threePhase
        deps.dashboardStore = store
        let vm = TracingViewModel(deps)
        vm.letters = TrainedLetterSubset.studyLetters.map(makeAsset)
        return vm
    }

    private func priorProbeRow(_ store: JSONParentDashboardStore, letter: String, probe: StudyProbe) {
        store.recordPhaseSession(
            letter: letter, phase: "freeWrite", completed: true, score: 0.5, schedulerPriority: 0,
            condition: .threePhase, audioCondition: .phoneme, assessment: nil, recognition: nil,
            inputDevice: nil, rawTraceID: nil, trainedSubset: "AFI", phaseDurationSeconds: nil,
            frechetDistance: nil, checkpointCoverage: nil, spatialDeviation: nil, strokeCount: nil,
            strokeOrder: nil, reversedStrokeCount: nil, studyMode: true, probe: probe.rawValue,
            comparisonConfiguration: nil, spatialDeviationRaw: nil, context: PhaseRowContext())
    }

    private func withStore(_ body: (JSONParentDashboardStore) throws -> Void) rethrows {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("probes-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try body(JSONParentDashboardStore(fileURL: url))
    }

    @Test("R-032: a probe row carries its attempt index; a training row carries none")
    func attemptIndexOnTheRow() throws {
        try withStore { store in
            let vm = makeVM(store: store)
            #expect(vm.startColdProbe(letter: "A", kind: .pretest) == nil)
            #expect(vm.currentProbeAttempt == 1)
            #expect(vm.phaseRowContext(for: .freeWrite, finalizedBy: .child).probeAttempt == 1)

            priorProbeRow(store, letter: "A", probe: .pretest)
            #expect(vm.startColdProbe(letter: "A", kind: .pretest) == nil, "a repeat is warned, never blocked")
            #expect(vm.currentProbeAttempt == 2, "the repeat is not counted: \(String(describing: vm.currentProbeAttempt))")
            #expect(vm.phaseRowContext(for: .freeWrite, finalizedBy: .child).probeAttempt == 2)

            #expect(vm.startColdProbe(letter: "L", kind: .pretest) == nil)
            #expect(vm.currentProbeAttempt == 1, "another letter's attempts leaked")
            vm.loadLetter(name: "A")
            #expect(vm.currentProbe == nil)
            #expect(vm.phaseRowContext(for: .observe, finalizedBy: .child).probeAttempt == nil,
                    "a training row carries a probe attempt")
        }
    }

    @Test("R-032: the proctor is warned before a repeat, and before a post-test while training is unfinished")
    func warnings() throws {
        try withStore { store in
            let vm = makeVM(store: store)
            #expect(vm.probeWarning(letter: "A", kind: .pretest) == nil, "a first pretest needs no warning")
            priorProbeRow(store, letter: "A", probe: .pretest)
            let repeatWarning = try #require(vm.probeWarning(letter: "A", kind: .pretest))
            #expect(repeatWarning.contains("Versuch 2"), "\(repeatWarning)")

            let early = try #require(vm.probeWarning(letter: "L", kind: .posttest),
                                     "a post-test before the training set is complete was not warned")
            #expect(early.contains("Training"), "\(early)")
            vm.finishSetAwaitingNextParticipant()
            #expect(vm.probeWarning(letter: "L", kind: .posttest) == nil,
                    "a post-test after the set is complete is the protocol, not a warning")
        }
    }

    @Test("R-032: the attempt index reaches the CSV")
    func attemptReachesTheExport() throws {
        var snap = DashboardSnapshot()
        snap.phaseSessionRecords.append(PhaseSessionRecord(
            letter: "A", phase: "freeWrite", completed: true, score: 0.5, schedulerPriority: 0,
            probe: "pretest", context: PhaseRowContext(probeAttempt: 2)))
        let text = String(data: ParentDashboardExporter.csvData(from: snap, participantId: UUID(), progress: [:], enrolledAt: nil),
                          encoding: .utf8)!
        let block = try #require(DelimitedExport.block(in: text, headerPrefix: "letter,phase,completed"))
        #expect(block.value("probeAttempt") == "2")
        #expect(block.value("probe") == "pretest")
    }
}
