// AllFiveLettersRowTruthTests.swift
// PrimaeNativeTests
//
// The `allFiveLetters` comparison switch, and the DATA-INTEGRITY defect it
// hid (2026-09-17).
//
// WHY THIS FILE EXISTS. `StudyComparisonSettings.allFiveLetters` widened
// the practice pool to all five study letters and nothing else. Three
// readers kept answering "which letters were trained?" from the
// participant's ASSIGNMENT axis (`trainedSubset`, a 3-subset from UUID
// byte 9), so on a switch-ON run the record said the child had trained
// three letters and was untrained on two — while the child had traced all
// five:
//
//   1. `PhaseTransitionCoordinator` stamped `trainedSubset.rawValue` on
//      EVERY exported row, at both `:226` (incomplete row) and `:433`
//      (completed phase row). That column is what analysis partitions
//      trained from untrained with.
//   2. `startColdProbe` gated `.posttest` on
//      `trainedSubset.untrainedLetters`, so the two letters the child HAD
//      trained were offered — and ACCEPTED — as the "untrained" probe.
//   3. `ParentDashboardExporter.derivedTrainedPostTestIndices`
//      re-derived "was this letter trained" from the same column, so the
//      post-test tag was withheld from the letters that were trained.
//
// The within-child contrast the study's design rests on was therefore
// FABRICATED by the bookkeeping rather than measured, and any analysis
// that partitions on the exported column would have been wrong for those
// rows. `StudyComparisonSwitchesTests:179` claims "each of these drives a
// production consumer" — `allFiveLetters` had no behavioural consumer
// test at all, which is part of what this file repairs.
//
// THE REPRESENTATION, and why it can be distinguished from a 3-subset
// run. The row's `trainedSubset` column now carries the SESSION's trained
// set (`TracingViewModel.effectiveTrainedSubset`), not the assignment:
// the assigned value normally, and `TrainedLetterSubset.allFive`
// ("AFILM") under the switch. Every assigned value is exactly 3
// characters drawn from the ten assignment buckets; "AFILM" is 5 and is
// in no bucket, and its `untrainedLetters` is EMPTY — so the naive
// partition an analyst writes first (`studyLetters - set(row.trainedSubset)`)
// returns zero untrained letters, which is the truth, instead of a
// fabricated pair that looks like a real baseline.
//
// WE ARE PARALLEL, SO NOTHING HERE WRITES A GLOBAL. The switch changes
// `visibleLetterNames`, so driving it through
// `StudyComparisonSettings.allFiveLetters` would present a five-letter
// practice pool to every other suite running concurrently — the exact
// trap `LetterWeightFallbackTests`' header records ("a test must not
// mutate global state — Swift Testing runs suites in PARALLEL, and the
// failure shows up in someone else's test"). This file therefore never
// writes that key; the switch is injected through
// `TracingDependencies.allFiveLetters`, which exists for this. The
// default-path tests inject `false`/`nil` rather than clearing the key,
// so they cannot disturb a suite that legitimately owns it either.

import Testing
import Foundation
import CoreGraphics
@testable import PrimaeNative

// MARK: - Capturing store

/// Captures the fields this file reasons about from every
/// `recordPhaseSession` call. `StubDashboardStore` discards them.
@MainActor
private final class RowCapturingStore: ParentDashboardStoring {
    struct Call {
        let letter: String
        let phase: String
        let trainedSubset: String?
        let probe: String?
        let studyMode: Bool?
    }

    private(set) var calls: [Call] = []

    var snapshot: DashboardSnapshot { DashboardSnapshot() }

    func recordSession(letter: String, accuracy: Double,
                       durationSeconds: TimeInterval,
                       wallClockSeconds: TimeInterval?,
                       date: Date, condition: ThesisCondition,
                       inputDevice: String?) {}

    func recordPhaseSession(letter: String, phase: String, completed: Bool, score: Double, schedulerPriority: Double, condition: ThesisCondition, audioCondition: PilotAudioCondition, assessment: WritingAssessment?, recognition: RecognitionSample?, inputDevice: String?, rawTraceID: UUID?, trainedSubset: String?, phaseDurationSeconds: Double?, frechetDistance: Double?, checkpointCoverage: Double?, spatialDeviation: Double?, strokeCount: Int?, strokeOrder: String?, reversedStrokeCount: Int?, studyMode: Bool?, probe: String?, comparisonConfiguration: String?) {
        calls.append(Call(letter: letter, phase: phase,
                          trainedSubset: trainedSubset, probe: probe,
                          studyMode: studyMode))
    }

    func reset() {}
}

// MARK: - Suite

@Suite @MainActor struct AllFiveLettersRowTruthTests {

    private let canvas = CGSize(width: 400, height: 400)

    /// A study VM with the switch INJECTED — never written to
    /// `UserDefaults` (see this file's header). `studyMode` is on because
    /// that is the only configuration in which the switch, the practice
    /// pool and the post-test gate exist at all.
    private func studyVM(allFiveLetters: Bool?,
                         dashboardStore: ParentDashboardStoring? = nil) -> TracingViewModel {
        var deps = TracingDependencies.stub
        deps.studyMode = true
        deps.thesisCondition = .threePhase   // freeWrite must be reachable
        deps.allFiveLetters = allFiveLetters
        if let dashboardStore { deps.dashboardStore = dashboardStore }
        let vm = TracingViewModel(deps)
        vm.canvasSize = canvas
        return vm
    }

    /// All five study letters present in the bundle, so the post-test
    /// gate is reachable for any of them. The stub bundle ships "A"
    /// only; without this, a post-test of "L" is refused by the
    /// LETTER-MISSING check rather than by the rule under test, and the
    /// test would pass for the wrong reason. Same idiom as
    /// `ColdProbeRefusalReasonTests.makeVM`.
    private func withAllFiveLettersLoaded(_ vm: TracingViewModel) {
        vm.letters = TrainedLetterSubset.studyLetters.map { name in
            LetterAsset(id: name, name: name, baseLetter: name, letterCase: .upper,
                        audioFiles: [],
                        strokes: LetterStrokes(letter: name, checkpointRadius: 0.1,
                                               strokes: []))
        }
    }

    // MARK: - 1. The type: all five is a representable, non-assignable set

    /// The all-five case must never become an assignment bucket. If it
    /// ever joined `allSubsets`, `assign`'s `byte % count` would not
    /// merely add an eleventh option — it would change which subset EVERY
    /// participant is assigned, invalidating the counterbalancing for
    /// runs already collected. This is the one invariant of that array.
    @Test("all five is not one of the ten assignment buckets, and is never assigned")
    func allFiveIsNotAssignable() {
        #expect(TrainedLetterSubset.allSubsets.count == 10,
                "the assignment bucket list changed size — `assign` indexes it by modulo, so this moves every participant's subset")
        #expect(TrainedLetterSubset.allSubsets.contains(.allFive) == false,
                "the all-five comparison case joined the assignment buckets")

        for _ in 0..<2_000 {
            let assigned = TrainedLetterSubset.assign(participantId: UUID())
            #expect(assigned.isAllFive == false,
                    "`assign` returned the all-five case — a participant was assigned the comparison configuration as their training axis")
        }
    }

    /// The property the whole fix rests on: on the all-five set there is
    /// no untrained letter, so the naive partition returns ONE group, not
    /// a fabricated pair.
    @Test("the all-five set has no untrained complement")
    func allFiveHasNoUntrainedComplement() {
        #expect(TrainedLetterSubset.allFive.letters == Set(TrainedLetterSubset.studyLetters),
                "the all-five case does not name all five study letters")
        #expect(TrainedLetterSubset.allFive.untrainedLetters.isEmpty,
                "the all-five case reports untrained letters — that is the fabricated baseline this fix removes")
        #expect(TrainedLetterSubset.allFive.isAllFive)

        // And an assigned subset still reports its genuine pair.
        let afi = TrainedLetterSubset.allSubsets[0]
        #expect(afi.rawValue == "AFI")
        #expect(afi.untrainedLetters == ["L", "M"])
    }

    /// The export distinguishes the two run types IN THE COLUMN ITSELF:
    /// every assigned value is 3 characters, the all-five value is 5, and
    /// no assigned value collides with it.
    @Test("the all-five value is distinguishable from every assignment bucket")
    func allFiveIsDistinguishableInTheExportedColumn() {
        let allFiveRaw = TrainedLetterSubset.allFive.rawValue
        #expect(allFiveRaw == "AFILM")
        #expect(allFiveRaw.count == 5)
        for bucket in TrainedLetterSubset.allSubsets {
            #expect(bucket.rawValue.count == 3,
                    "assignment bucket \(bucket.rawValue) is not 3 letters — the size is how an analyst tells a pilot row from a comparison row")
            #expect(bucket.rawValue != allFiveRaw)
        }
        // Round-trips through the type, which is what the exporter's
        // derived-post-test pass needs (a nil here would drop the
        // post-test tag from every letter of an all-five run).
        #expect(TrainedLetterSubset(rawValue: allFiveRaw)?.isAllFive == true)
        // The size guard on the canonical form still holds.
        #expect(TrainedLetterSubset(rawValue: "AFIL") == nil)
        #expect(TrainedLetterSubset(rawValue: "ABC") == nil)
    }

    // MARK: - 2. The default path is unchanged (switch OFF)

    /// Production reads the device key; nothing in this file writes it.
    @Test("the dependency seam defaults to nil, so production still reads the device key")
    func seamDefaultsToReadingTheDeviceKey() {
        #expect(TracingDependencies.stub.allFiveLetters == nil,
                "the stub pins the seam — production leaves it nil and reads StudyComparisonSettings")
    }

    /// Switch OFF: the session's trained set IS the assignment, the
    /// untrained pair is real, and the stamped column is the assigned
    /// 3-subset. This is the "byte-identical to today" assertion, made
    /// through the same property the rows are stamped from.
    @Test("with the switch off the session trains the assignment and stamps it")
    func switchOffKeepsTheAssignedThree() {
        let vm = studyVM(allFiveLetters: false)

        #expect(vm.trainedSubset.rawValue == "AFI", "precondition: the stub pins AFI")
        #expect(vm.effectiveTrainedSubset == vm.trainedSubset,
                "the switch is off — the session's trained set must be the assignment itself")
        #expect(vm.effectiveTrainedSubset.rawValue == "AFI")
        #expect(vm.effectiveTrainedSubset.untrainedLetters == ["L", "M"],
                "the off path must keep the genuine within-child baseline")
        #expect(vm.effectiveTrainedSubset.isAllFive == false)
    }

    // MARK: - 3. The gate: no post-test of an "untrained" letter that was trained

    /// Switch OFF, control: the post-test of a genuinely untrained letter
    /// is permitted and lands in freeWrite. Without this control, the
    /// refusal assertion below could pass for any reason at all.
    @Test("with the switch off an untrained letter's post-test is permitted")
    func switchOffPermitsTheUntrainedPostTest() {
        let vm = studyVM(allFiveLetters: false)
        withAllFiveLettersLoaded(vm)

        let reason = vm.startColdProbe(letter: "L", kind: .posttest)
        #expect(reason == nil, "L is untrained under AFI — the post-test must be permitted, got: \(reason ?? "nil")")
        #expect(vm.currentLetterName == "L")
        #expect(vm.learningPhase == .freeWrite)
        #expect(vm.currentProbe == .posttest)
    }

    /// Switch ON: the same letter — now TRAINED — must be refused, and
    /// the reason must say why. Before the fix this returned nil and
    /// started a probe on a letter the child had practised, which the
    /// analysis would read as the untrained baseline.
    @Test("with the switch on the post-test is refused, and says the contrast is unavailable")
    func switchOnRefusesThePostTestWithItsOwnReason() {
        let vm = studyVM(allFiveLetters: true)
        withAllFiveLettersLoaded(vm)

        for letter in TrainedLetterSubset.studyLetters {
            let reason = vm.startColdProbe(letter: letter, kind: .posttest)
            let text = try? #require(reason)
            #expect(text != nil,
                    "\(letter) was accepted for the post-test — under all-five every letter is TRAINED, so this is the fabricated untrained probe back again")
            #expect(text?.contains("alle fünf") == true,
                    "the refusal does not say that all five were trained — a proctor reading it sees a per-letter refusal and assumes a bug. Got: \(text ?? "nil")")
            #expect(vm.currentProbe == nil, "no probe may appear to have started")
        }
    }

    /// The state the researcher UI branches on. It used to read the
    /// assignment axis, so the screen printed "Diese 2 Buchstaben hat das
    /// Kind NICHT geübt" and offered exactly those two trained letters.
    @Test("the post-test population is empty under the switch and a real pair without it")
    func postTestPopulationFollowsTheSessionNotTheAssignment() {
        let off = studyVM(allFiveLetters: false)
        #expect(off.effectiveTrainedSubset.untrainedLetters == ["L", "M"])

        let on = studyVM(allFiveLetters: true)
        #expect(on.effectiveTrainedSubset.untrainedLetters.isEmpty,
                "the researcher UI's post-test section reads this — a non-empty set here re-offers trained letters as untrained")
        // The assignment axis it used to read is still a 3-subset: that
        // is exactly why the two must be read from different properties.
        #expect(on.trainedSubset.untrainedLetters == ["L", "M"],
                "precondition: the assignment axis is unchanged and would still name a fabricated pair")
    }

    // MARK: - 4. The row: what the export actually carries

    /// THE load-bearing test. Drives a real four-phase session through the
    /// coordinator and reads the `trainedSubset` argument off every
    /// `recordPhaseSession` call — i.e. the column, not a view-model
    /// property that merely ought to reach it.
    @Test("every row written under the switch names all five as trained")
    func rowsUnderTheSwitchCarryAllFive() async throws {
        let store = RowCapturingStore()
        let vm = studyVM(allFiveLetters: true, dashboardStore: store)
        try await runFullSession(vm, store: store)

        #expect(store.calls.count == 4,
                "expected 4 phase rows, got \(store.calls.count): \(store.calls.map(\.phase))")
        for call in store.calls {
            #expect(call.trainedSubset == "AFILM",
                    "the \(call.phase) row of an all-five session stamps '\(call.trainedSubset ?? "nil")' — anything 3-lettered makes the export assert the child was untrained on two letters it practised")
        }
    }

    /// The control, driven through the identical path: switch OFF stamps
    /// the assigned 3-subset on every row, unchanged.
    @Test("every row written with the switch off still names the assigned three")
    func rowsWithTheSwitchOffCarryTheAssignment() async throws {
        let store = RowCapturingStore()
        let vm = studyVM(allFiveLetters: false, dashboardStore: store)
        try await runFullSession(vm, store: store)

        #expect(store.calls.count == 4)
        for call in store.calls {
            #expect(call.trainedSubset == "AFI",
                    "the \(call.phase) row stamped '\(call.trainedSubset ?? "nil")' — the default path must be byte-identical to the behaviour before the fix")
        }
    }

    /// The assignment axis survives the switch — it still decides the
    /// counterbalancing and the researcher screen still shows it — while
    /// the stamped value does not follow it. This pair is what makes an
    /// all-five run tellable apart from a real 3-subset run.
    @Test("under the switch the assignment and the stamped set differ")
    func assignmentAndStampedSetDiverge() async throws {
        let store = RowCapturingStore()
        let vm = studyVM(allFiveLetters: true, dashboardStore: store)
        try await runFullSession(vm, store: store)

        #expect(vm.trainedSubset.rawValue == "AFI", "the assignment axis must not move with the switch")
        #expect(vm.effectiveTrainedSubset.rawValue == "AFILM")
        #expect(store.calls.allSatisfy { $0.trainedSubset == "AFILM" },
                "a row followed the assignment axis instead of the session")
        #expect(store.calls.allSatisfy { $0.trainedSubset != vm.trainedSubset.rawValue },
                "the stamped value still equals the assignment — the defect is back")
    }

    // MARK: - 5. The export's derived post-test tag

    /// The third reader of the same lie. `probe == "posttest"` is how the
    /// analysis finds the post-test measurement of a TRAINED letter (the
    /// freeWrite of its final training pass). Under all-five every letter
    /// is trained, so all five must be tagged; before the fix the column
    /// said "AFI" and the tag was derived for three.
    @Test("the export tags every letter's post-test under the switch")
    func exporterDerivesPostTestForAllFive() {
        func probeColumn(trainedSubset: String) -> [String: String] {
            var snap = DashboardSnapshot()
            for (i, letter) in TrainedLetterSubset.studyLetters.enumerated() {
                snap.phaseSessionRecords.append(PhaseSessionRecord(
                    letter: letter, phase: "freeWrite", completed: true, score: 0.6,
                    schedulerPriority: 0,
                    recordedAt: Date(timeIntervalSince1970: 1_770_000_000 + Double(i)),
                    trainedSubset: trainedSubset))
            }
            let csv = String(data: ParentDashboardExporter.csvData(
                from: snap, participantId: UUID(), progress: [:], enrolledAt: nil),
                             encoding: .utf8)!
            let lines = csv.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let header = lines.first { $0.hasPrefix("letter,phase,") }
            let cols = (header ?? "").split(separator: ",").map(String.init)
            guard let subsetIdx = cols.firstIndex(of: "trainedSubset"),
                  let probeIdx = cols.firstIndex(of: "probe") else { return [:] }
            var out: [String: String] = [:]
            for line in lines where line.hasPrefix("A,freeWrite") || line.hasPrefix("F,freeWrite")
                || line.hasPrefix("I,freeWrite") || line.hasPrefix("L,freeWrite")
                || line.hasPrefix("M,freeWrite") {
                let f = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
                guard f.count > max(subsetIdx, probeIdx) else { continue }
                #expect(f[subsetIdx] == trainedSubset,
                        "the row's trainedSubset column is not what was stamped")
                out[f[0]] = f[probeIdx]
            }
            return out
        }

        let allFive = probeColumn(trainedSubset: "AFILM")
        #expect(allFive.count == 5, "expected a row per study letter, got \(allFive.sorted(by: { $0.key < $1.key }))")
        #expect(allFive.values.allSatisfy { $0 == "posttest" },
                "under all-five every letter is trained, so every letter's final freeWrite IS its post-test — the export withheld the tag from the letters that were trained: \(allFive.sorted(by: { $0.key < $1.key }))")

        // Control: the same fixture stamped with a real 3-subset tags only
        // the three assigned letters — the untrained pair's post-test is
        // its own cold probe, tagged live at record time.
        let three = probeColumn(trainedSubset: "AFI")
        #expect(three.filter { $0.value == "posttest" }.keys.sorted() == ["A", "F", "I"],
                "the 3-subset control's derived tags moved: \(three.sorted(by: { $0.key < $1.key }))")
    }

    // MARK: - Driver

    /// One full four-phase session, driven from the public entry
    /// (`advanceLearningPhase`), captured at the store seam. Mirrors
    /// `PhaseRecordAttachmentTests.runSession`; the recogniser hop is a
    /// Task, so the wait is on the observable outcome, bounded.
    private func runFullSession(_ vm: TracingViewModel,
                                store: RowCapturingStore) async throws {
        vm.startParkedLetter()
        try #require(vm.learningPhase == .observe,
                     "a study launch should be parked in observe, got \(vm.learningPhase)")
        try #require(vm.strokeTracker.definition != nil,
                     "fixture letter has no stroke definition — the freeWrite branch would bail out and wipe the recorder")

        vm.phaseController.advance(score: 1.0)   // observe
        vm.phaseController.advance(score: 1.0)   // direct
        vm.phaseController.advance(score: 0.8)   // guided
        try #require(vm.phaseController.currentPhase == .freeWrite,
                     "the phase walk did not reach freeWrite, got \(vm.phaseController.currentPhase)")

        vm.freeWriteRecorder.startSession(now: 100.0)
        for i in 0...18 {
            vm.freeWriteRecorder.record(
                point: CGPoint(x: 20 + Double(i) * 20, y: 200),
                timestamp: 100.0 + Double(i) * 0.1,
                force: 0.5,
                canvasSize: vm.canvasSize)
        }

        vm.advanceLearningPhase()

        for _ in 0..<100 where store.calls.isEmpty {
            try? await Task.sleep(for: .milliseconds(5))
        }
        try #require(!store.calls.isEmpty,
                     "no recordPhaseSession call within 500 ms — the completion pipeline never ran")
    }
}
