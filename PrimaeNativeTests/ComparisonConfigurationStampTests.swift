// ComparisonConfigurationStampTests.swift
// PrimaeNativeTests
//
// A COMPARISON RUN's exported rows and a PILOT run's rows used to be
// INDISTINGUISHABLE (2026-09-18).
//
// WHAT WAS MEASURED. `StudyComparisonSettings` declares twelve researcher
// switches, and ELEVEN of them left no trace in the exported data:
// `grep -c "StudyComparisonSettings"` returned 0 in
// `ParentDashboardExporter.swift`, `ParentDashboardStore.swift`,
// `PhaseTransitionCoordinator.swift` and `ParticipantArchiveStore.swift`.
// Every read was a session-behaviour read or a UI read; none was an
// export read. A pilot row and a comparison row therefore carried the
// same 27 CSV columns, in the same order, with the same names
// (`ParentDashboardExporter`'s literal header). The one exception was
// `allFiveLetters`, which disclosed itself INDIRECTLY through
// `trainedSubset == "AFILM"` (`TrainedLetterSubset.swift`).
//
// So the claim in `StudyComparisonSettings`' header — "any row produced
// under a non-default switch is a comparison run rather than pilot data"
// — was true of what the session WAS and false of what the row SAID.
// Rows merged across sessions could not be partitioned, and the thesis
// cannot report which runs were pilot runs without that partition.
//
// WHAT REPAIRS IT. `PhaseSessionRecord.comparisonConfiguration` — the
// non-default switches this session ran under, `name=value` pairs joined
// by `;`, or nil for a session at every default (the PILOT). Captured
// when the row is CONSTRUCTED (`PhaseTransitionCoordinator`, both write
// sites) from `TracingViewModel.comparisonConfigurationStamp`, which is
// itself resolved once at view-model init from the values the session
// actually resolved.
//
// THE PROPERTY THAT IS EASIEST TO GET WRONG, and the test that would
// fail if someone got it wrong later: the value must NEVER be read at
// export time. An export can happen days after the session, on a device
// whose switches have since been changed, so a read inside the exporter
// would stamp yesterday's rows with today's configuration — and, worse,
// would stamp EVERY row in the file identically, which is exactly the
// conflation this field exists to remove. `exportUsesEachRowsOwnStamp`
// below pins that: it puts two rows with two DIFFERENT stamps into one
// snapshot and requires the export to reproduce each row's own value.
// Reading the device instead of the record cannot pass it.
//
// WE ARE PARALLEL, SO NOTHING HERE WRITES A GLOBAL. `StudyComparison
// SwitchesTests` and `AxisDemonstrationSwitchTests` legitimately own the
// `StudyComparisonSettings` keys and write them without a `defer` in one
// case; a suite that read those keys would sample whatever they had
// written at that instant — the trap this project has already paid for
// once (`LetterWeightFallbackTests`' header). So the session-level tests
// here drive only the five switches that have a `TracingDependencies`
// seam, which `TracingDependencies.stub` pins, and the remaining
// assertions are made on `StudyComparisonConfiguration` as a VALUE with
// no device involved at all.
//
// WHAT THIS FILE CANNOT PIN, stated rather than papered over: a
// view-model-level "an all-defaults session stamps nil" assertion is NOT
// writable deterministically, because seven of the twelve switches have
// no seam and are read from `UserDefaults.standard` inside
// `TracingViewModel` — a concurrent suite's write would leak into it.
// The claim is pinned exactly where it is unambiguous
// (`defaultConfigurationStampsNothing`, on the value type) and
// session-side only for the four seam switches `stub` pins.

import Testing
import Foundation
import CoreGraphics
@testable import PrimaeNative

// MARK: - Capturing store

/// Captures the comparison stamp from every `recordPhaseSession` call.
/// `StubDashboardStore` discards its arguments, so it cannot witness
/// what the write sites actually pass.
@MainActor
private final class StampCapturingStore: ParentDashboardStoring {
    private(set) var stamps: [String?] = []

    var snapshot: DashboardSnapshot { DashboardSnapshot() }

    func recordSession(letter: String, accuracy: Double,
                       durationSeconds: TimeInterval,
                       wallClockSeconds: TimeInterval?,
                       date: Date, condition: ThesisCondition,
                       inputDevice: String?) {}

    func recordPhaseSession(letter: String, phase: String, completed: Bool, score: Double, schedulerPriority: Double, condition: ThesisCondition, audioCondition: PilotAudioCondition, assessment: WritingAssessment?, recognition: RecognitionSample?, inputDevice: String?, rawTraceID: UUID?, trainedSubset: String?, phaseDurationSeconds: Double?, frechetDistance: Double?, checkpointCoverage: Double?, spatialDeviation: Double?, strokeCount: Int?, strokeOrder: String?, reversedStrokeCount: Int?, studyMode: Bool?, probe: String?, comparisonConfiguration: String?) {
        stamps.append(comparisonConfiguration)
    }

    func reset() {}
}

// MARK: - Suite

@Suite @MainActor struct ComparisonConfigurationStampTests {

    private let canvas = CGSize(width: 400, height: 400)

    /// The four switches `TracingDependencies.stub` pins at their
    /// defaults, so a session built from it names none of them however
    /// the rest of the parallel run is behaving. The other eight are
    /// either read from `UserDefaults` inside the view model
    /// (`allFiveLetters` when the seam is nil) or read from it by the
    /// view model's own property initialisers, and cannot be asserted on
    /// from a parallel suite — see this file's header.
    private let pinnedAtDefault = ["cycleAllConditions", "oncePerCondition",
                                   "soundGateRadiusFactor", "soundGateVelocityFloor"]

    private func studyVM(dashboardStore: ParentDashboardStoring? = nil,
                         oncePerCondition: Bool = false) -> TracingViewModel {
        var deps = TracingDependencies.stub
        deps.studyMode = true
        deps.thesisCondition = .threePhase   // freeWrite must be reachable
        deps.oncePerCondition = oncePerCondition
        if let dashboardStore { deps.dashboardStore = dashboardStore }
        let vm = TracingViewModel(deps)
        vm.canvasSize = canvas
        return vm
    }

    // MARK: - 1. The pilot stamps NOTHING (the "byte-identical" property)

    /// The whole point of the field being optional. A pilot row's column
    /// must be empty, so no existing pilot analysis moves because this
    /// column now exists.
    @Test("an all-defaults configuration — the pilot — stamps nothing at all")
    func defaultConfigurationStampsNothing() {
        #expect(StudyComparisonConfiguration.defaults.nonDefaultStamp == nil,
                "the default configuration produced a stamp — every pilot row in every existing export would gain a non-empty column, which is the one thing this change promised not to do")
    }

    /// Session side of the same claim, for the switches that can be
    /// asserted without touching a global: a view model on a default
    /// configuration names none of them. See this file's header for why
    /// the remaining eight cannot be asserted this way.
    @Test("a default-configured session names none of the switch names it pins")
    func defaultSessionNamesNoSwitch() {
        let stamp = studyVM().comparisonConfigurationStamp ?? ""
        for name in pinnedAtDefault {
            #expect(stamp.contains(name) == false,
                    "a session at the default configuration stamped '\(name)' (stamp: '\(stamp)') — a default must never appear in the stamp")
        }
    }

    // MARK: - 2. One non-default switch, named exactly

    /// EXACT string equality, so "names the switch" cannot be satisfied
    /// by a stamp that also names nine others.
    @Test("one non-default switch is named exactly, and nothing else is")
    func oneNonDefaultSwitchIsNamedExactly() {
        var config = StudyComparisonConfiguration.defaults

        config.oncePerCondition = true
        #expect(config.nonDefaultStamp == "oncePerCondition=true",
                "got: \(config.nonDefaultStamp ?? "nil")")

        config = StudyComparisonConfiguration.defaults
        config.observePasses = 2
        #expect(config.nonDefaultStamp == "observePasses=2",
                "got: \(config.nonDefaultStamp ?? "nil")")

        config = StudyComparisonConfiguration.defaults
        config.panningEnabled = false
        #expect(config.nonDefaultStamp == "panningEnabled=false",
                "got: \(config.nonDefaultStamp ?? "nil") — note the default is TRUE here, so 'false' is the non-default value and must be the one named")

        config = StudyComparisonConfiguration.defaults
        config.soundGateRadiusFactor = 6.0
        #expect(config.nonDefaultStamp == "soundGateRadiusFactor=6.0",
                "got: \(config.nonDefaultStamp ?? "nil")")
    }

    /// Two switches, in declaration order, one separator, no commas —
    /// the field has to survive the CSV writer unquoted and be split
    /// unambiguously by a parser.
    @Test("several switches are named in declaration order and stay parseable")
    func severalSwitchesInDeclarationOrder() {
        var config = StudyComparisonConfiguration.defaults
        config.observePasses = 2
        config.panningEnabled = false
        let stamp = config.nonDefaultStamp ?? ""

        #expect(stamp == "observePasses=2;panningEnabled=false", "got: '\(stamp)'")
        #expect(stamp.contains(",") == false,
                "the stamp carries a comma — the CSV writer would have to quote it, and the field would stop being a plain column")
        let entries = stamp.split(separator: ";").map(String.init)
        #expect(entries.count == 2)
        for entry in entries {
            #expect(entry.split(separator: "=").count == 2,
                    "entry '\(entry)' does not split into exactly name=value")
        }
    }

    /// The stamp is a NAME for the configuration, not a log of how it
    /// was assembled: the same configuration must produce the same
    /// string however the fields were set, or two rows of the same run
    /// could disagree.
    @Test("the stamp depends on the values, not on assignment order")
    func stampIsOrderIndependent() {
        var a = StudyComparisonConfiguration.defaults
        a.observePasses = 2
        a.panningEnabled = false
        a.oncePerCondition = true

        var b = StudyComparisonConfiguration.defaults
        b.oncePerCondition = true
        b.panningEnabled = false
        b.observePasses = 2

        #expect(a.nonDefaultStamp == b.nonDefaultStamp)
        #expect(a.nonDefaultStamp == "observePasses=2;panningEnabled=false;oncePerCondition=true",
                "got: \(a.nonDefaultStamp ?? "nil")")
    }

    /// Every switch must be able to appear. A field added to the struct
    /// without a line in `nonDefaultStamp` is silently invisible in the
    /// export — the very defect this file exists to close — and this
    /// loop is the only place that would notice.
    @Test("every switch is representable in the stamp")
    func everySwitchIsRepresentable() {
        func stampAfterOneChange(_ mutate: (inout StudyComparisonConfiguration) -> Void,
                                 expecting name: String) {
            var config = StudyComparisonConfiguration.defaults
            mutate(&config)
            let stamp = config.nonDefaultStamp ?? ""
            #expect(stamp.contains("\(name)="),
                    "changing \(name) produced '\(stamp)' — that switch cannot reach the export, which is the defect this field exists to close")
        }

        stampAfterOneChange({ $0.observePasses = 2 }, expecting: "observePasses")
        stampAfterOneChange({ $0.spokenFeedbackInStudy = true }, expecting: "spokenFeedbackInStudy")
        stampAfterOneChange({ $0.allFiveLetters = true }, expecting: "allFiveLetters")
        stampAfterOneChange({ $0.letterRepeatCount = 3 }, expecting: "letterRepeatCount")
        stampAfterOneChange({ $0.cycleAllConditions = true }, expecting: "cycleAllConditions")
        stampAfterOneChange({ $0.presentationSpacingSeconds = 2.5 }, expecting: "presentationSpacingSeconds")
        stampAfterOneChange({ $0.panningEnabled = false }, expecting: "panningEnabled")
        stampAfterOneChange({ $0.guidedDotsVisible = false }, expecting: "guidedDotsVisible")
        stampAfterOneChange({ $0.spatialAxisDemonstration = true }, expecting: "spatialAxisDemonstration")
        stampAfterOneChange({ $0.soundGateRadiusFactor = 1.0 }, expecting: "soundGateRadiusFactor")
        stampAfterOneChange({ $0.soundGateVelocityFloor = 0.0 }, expecting: "soundGateVelocityFloor")
        stampAfterOneChange({ $0.oncePerCondition = true }, expecting: "oncePerCondition")
    }

    /// COMPLETENESS, enforced rather than promised. A switch added to the
    /// struct without a line in `nonDefaultStamp` is silently invisible in
    /// the export — precisely the defect this whole field exists to close,
    /// reintroduced one field at a time. The doc comment on `nonDefault
    /// Stamp` says a future author has to remember; this test means they
    /// cannot forget, because `Mirror` reports the stored properties the
    /// compiler knows about and the stamp has to name every one of them.
    @Test("the stamp names every stored switch, and the struct has twelve")
    func stampNamesEveryStoredSwitch() {
        let all = StudyComparisonConfiguration(
            observePasses: 2,
            spokenFeedbackInStudy: true,
            allFiveLetters: true,
            letterRepeatCount: 3,
            cycleAllConditions: true,
            presentationSpacingSeconds: 2.5,
            panningEnabled: false,
            guidedDotsVisible: false,
            spatialAxisDemonstration: true,
            soundGateRadiusFactor: 6.0,
            soundGateVelocityFloor: 0.0,
            oncePerCondition: true)

        let storedFields = Mirror(reflecting: all).children.compactMap(\.label)
        #expect(storedFields.count == 12,
                "the configuration struct now has \(storedFields.count) stored switches, not 12 — the twelve-switch claim in StudyComparisonSettings' header, and every count derived from it, has moved")

        let entries = (all.nonDefaultStamp ?? "").split(separator: ";").map(String.init)
        #expect(entries.count == storedFields.count,
                "a configuration with every switch moved produced \(entries.count) stamp entries for \(storedFields.count) stored switches — the missing one is invisible in the export, which is the defect this field exists to close")

        let named = Set(entries.compactMap { $0.split(separator: "=").first.map(String.init) })
        #expect(named == Set(storedFields),
                "the stamp names \(named.sorted()) but the struct stores \(storedFields.sorted()) — a switch whose stamp name differs from its property name cannot be read against StudyComparisonSettings without a lookup")
    }

    // MARK: - 3. The session's stamp reaches the write sites

    /// The view model's stamp is what the coordinator stamps, and it
    /// follows the seam — so the value on the row is the one the session
    /// ran under, not one reconstructed later.
    @Test("the view model stamps the seam it was built with")
    func viewModelStampFollowsTheSeam() {
        let off = studyVM(oncePerCondition: false).comparisonConfigurationStamp ?? ""
        let on  = studyVM(oncePerCondition: true).comparisonConfigurationStamp ?? ""

        #expect(on.contains("oncePerCondition=true"),
                "a session built with the switch on stamped '\(on)' — the switch cannot reach the export")
        #expect(off.contains("oncePerCondition") == false,
                "the control session stamped '\(off)' — a default value must never appear in the stamp")
        #expect(on != off, "both sessions stamped identically: '\(on)'")
    }

    /// THE WRITE SITE, driven end to end: the value that reaches
    /// `recordPhaseSession` is the view model's stamp, on every row.
    @Test("every phase row is written with the session's stamp")
    func everyPhaseRowCarriesTheSessionStamp() async throws {
        let store = StampCapturingStore()
        let vm = studyVM(dashboardStore: store, oncePerCondition: true)
        try await runFullSession(vm, store: store)

        #expect(store.stamps.count == 3,
                "expected 3 phase rows, got \(store.stamps.count)")
        let expected = vm.comparisonConfigurationStamp
        #expect(expected != nil, "precondition: the seam must produce a stamp")
        for stamp in store.stamps {
            #expect(stamp == expected,
                    "a row was written with '\(stamp ?? "nil")' instead of the session's '\(expected ?? "nil")' — the stamp is not being captured at the write site")
        }
    }

    /// The control: the same drive with the seam at its default writes
    /// rows that name none of the pinned switches.
    @Test("rows from a default-configured session name no pinned switch")
    func defaultSessionRowsNameNoSwitch() async throws {
        let store = StampCapturingStore()
        let vm = studyVM(dashboardStore: store, oncePerCondition: false)
        try await runFullSession(vm, store: store)

        #expect(store.stamps.count == 3)
        for stamp in store.stamps {
            let text = stamp ?? ""
            for name in pinnedAtDefault {
                #expect(text.contains(name) == false,
                        "a row stamped '\(name)' (stamp: '\(text)') — a default value must never appear in the stamp")
            }
        }
    }

    // MARK: - 4. The export: per ROW, never per device

    /// THE LOAD-BEARING TEST for the timing property. Two rows with two
    /// different stamps go into ONE snapshot; the export must reproduce
    /// each row's OWN value.
    ///
    /// A read of `StudyComparisonSettings` inside the exporter cannot
    /// pass this: both rows would come out with the same device-derived
    /// value, so at least one of the exact-equality assertions below
    /// fails, and `first != second` fails outright. That is the shape of
    /// the change this test exists to prevent — the export happening
    /// days later, on a device whose switches have since moved.
    @Test("the export carries each row's OWN stamp, not the device's")
    func exportUsesEachRowsOwnStamp() throws {
        let firstStamp  = "observePasses=2"
        let secondStamp = "panningEnabled=false;oncePerCondition=true"

        var snap = DashboardSnapshot()
        snap.phaseSessionRecords.append(PhaseSessionRecord(
            letter: "A", phase: "freeWrite", completed: true, score: 0.6,
            schedulerPriority: 0,
            recordedAt: Date(timeIntervalSince1970: 1_770_000_000),
            comparisonConfiguration: firstStamp))
        snap.phaseSessionRecords.append(PhaseSessionRecord(
            letter: "F", phase: "freeWrite", completed: true, score: 0.6,
            schedulerPriority: 0,
            recordedAt: Date(timeIntervalSince1970: 1_770_000_001),
            comparisonConfiguration: secondStamp))
        // And a PILOT row in the same export: empty column, not a
        // defaulted value.
        snap.phaseSessionRecords.append(PhaseSessionRecord(
            letter: "I", phase: "freeWrite", completed: true, score: 0.6,
            schedulerPriority: 0,
            recordedAt: Date(timeIntervalSince1970: 1_770_000_002)))

        let csv = String(data: ParentDashboardExporter.csvData(
            from: snap, participantId: UUID(), progress: [:], enrolledAt: nil),
                         encoding: .utf8)!
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let header = try #require(lines.first { $0.hasPrefix("letter,phase,completed") },
                                  "no phase-row header in the export")
        let names = header.components(separatedBy: ",")
        let idx = try #require(names.firstIndex(of: "comparisonConfiguration"),
                               "the export has no comparisonConfiguration column — a comparison run's rows are still indistinguishable from pilot rows. Header: \(header)")

        // Appended LAST, so no existing column moved or was renamed.
        #expect(idx == names.count - 1,
                "comparisonConfiguration sits at index \(idx) of \(names.count) — it must be the LAST column so every legacy parser's column order is untouched")

        let rows = lines.filter { $0.hasPrefix("A,freeWrite") || $0.hasPrefix("F,freeWrite") || $0.hasPrefix("I,freeWrite") }
        #expect(rows.count == 3, "expected a row per letter, got \(rows.count)")

        func stampColumn(_ row: String) -> String {
            let fields = row.components(separatedBy: ",")
            #expect(fields.count == names.count,
                    "row and header fell out of alignment — the stamp was inserted somewhere other than the end")
            return fields[idx]
        }

        let first  = stampColumn(try #require(rows.first { $0.hasPrefix("A,") }))
        let second = stampColumn(try #require(rows.first { $0.hasPrefix("F,") }))
        let pilot  = stampColumn(try #require(rows.first { $0.hasPrefix("I,") }))

        #expect(first == firstStamp,
                "the A row exported '\(first)' instead of its own '\(firstStamp)' — the stamp was not read from the record")
        #expect(second == secondStamp,
                "the F row exported '\(second)' instead of its own '\(secondStamp)' — the stamp was not read from the record")
        #expect(first != second,
                "both rows exported the SAME stamp '\(first)' — the export is stamping every row with one configuration instead of each row's own, which is the defect this field exists to remove")
        #expect(pilot.isEmpty,
                "the pilot row exported '\(pilot)' — a session at every default must leave the column EMPTY so existing pilot analysis is unchanged")
    }

    // MARK: - 5. The stamp survives storage

    /// The stamp has to persist with the row, and it has to survive being
    /// merged with rows from other sessions — that merge is the whole
    /// reason the field exists.
    @Test("the stamp round-trips through the record's own encoding")
    func stampRoundTripsThroughCodable() throws {
        var snap = DashboardSnapshot()
        snap.phaseSessionRecords.append(PhaseSessionRecord(
            letter: "A", phase: "freeWrite", completed: true, score: 0.5,
            schedulerPriority: 0, recordedAt: Date(timeIntervalSince1970: 1_770_000_000),
            comparisonConfiguration: "oncePerCondition=true"))
        snap.phaseSessionRecords.append(PhaseSessionRecord(
            letter: "F", phase: "freeWrite", completed: true, score: 0.5,
            schedulerPriority: 0, recordedAt: Date(timeIntervalSince1970: 1_770_000_001)))

        let back = try JSONDecoder().decode(
            DashboardSnapshot.self, from: try JSONEncoder().encode(snap))

        #expect(back.phaseSessionRecords.first?.comparisonConfiguration == "oncePerCondition=true",
                "the stamp did not survive the record's own encoding — a merged export would lose it")
        #expect(back.phaseSessionRecords.last?.comparisonConfiguration == nil,
                "the pilot row came back with a stamp")
    }

    /// A row written before this field existed decodes as nil — which is
    /// the honest value, not a made-up one: those sessions ran the
    /// defaults, because every switch's default IS the behaviour the app
    /// had before that switch existed.
    @Test("a legacy row decodes the stamp as nil, not as a default string")
    func legacyRowDecodesAsNil() throws {
        let legacy = """
        {"letter":"A","phase":"freeWrite","completed":true,"score":0.5,
         "schedulerPriority":0.1,"condition":"threePhase"}
        """.data(using: .utf8)!
        let rec = try JSONDecoder().decode(PhaseSessionRecord.self, from: legacy)
        #expect(rec.comparisonConfiguration == nil,
                "a pre-2026-09-18 row decoded a stamp out of nothing — it would be indistinguishable from a real comparison row with a defaulted value")
    }

    // MARK: - Driver

    /// One full three-phase session, driven from the public entry
    /// (`advanceLearningPhase`), captured at the store seam. Mirrors
    /// `AllFiveLettersRowTruthTests.runFullSession`; the recogniser hop
    /// is a Task, so the wait is on the observable outcome, bounded.
    private func runFullSession(_ vm: TracingViewModel,
                                store: StampCapturingStore) async throws {
        vm.startParkedLetter()
        try #require(vm.learningPhase == .observe,
                     "a study launch should be parked in observe, got \(vm.learningPhase)")
        try #require(vm.strokeTracker.definition != nil,
                     "fixture letter has no stroke definition — the freeWrite branch would bail out and wipe the recorder")

        // TWO advances, not three: `.direct` left the session (2026-09-18),
        // so observe → guided → freeWrite is the whole walk. A third
        // advance would complete the session, and the coordinator's
        // `advance()` returns on `isLetterSessionComplete` — writing no
        // rows at all.
        vm.phaseController.advance(score: 1.0)   // observe
        vm.phaseController.advance(score: 0.8)   // guided
        try #require(vm.phaseController.currentPhase == .freeWrite,
                     "the phase walk did not reach freeWrite, got \(vm.phaseController.currentPhase)")
        try #require(!vm.phaseController.isLetterSessionComplete,
                     "the walk must stop short of completion — a completed session makes the coordinator's advance a no-op")

        vm.freeWriteRecorder.startSession(now: 100.0)
        for i in 0...18 {
            vm.freeWriteRecorder.record(
                point: CGPoint(x: 20 + Double(i) * 20, y: 200),
                timestamp: 100.0 + Double(i) * 0.1,
                force: 0.5,
                canvasSize: vm.canvasSize)
        }

        vm.advanceLearningPhase()

        for _ in 0..<100 where store.stamps.isEmpty {
            try? await Task.sleep(for: .milliseconds(5))
        }
        try #require(!store.stamps.isEmpty,
                     "no recordPhaseSession call within 500 ms — the completion pipeline never ran")
    }
}
