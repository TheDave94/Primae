// Participant hand-over fixes (fix lane L2, 2026-11-02): FIXPLAN A4-A7.
// Pins, each mutation-checked on the physical iPad:
//   A4  C-3/VERIFY-1  the outgoing child's prompt and queued retry stop at
//                     "Nächstes Kind" and at a restore
//   A5  DATA-6        a restore with no enrolment record takes the arm from
//                     the child's archived rows; conflicting rows refuse
//   A6  DATA-7        probe attempts count the child's sealed sessions
//   A7  VERIFY-2/3    an arm/subset override after the child's first row
//                     does not split the child at the next launch
//   B2  STATE-3       an enrolment with no activity is dropped from the
//                     enrolment log at the next enrolment (r16)
//   B5  DATA-9        per-arm child tally; the confirm text names a
//                     pending override (VERIFY-4)
//
// An EXTENSION of `NewParticipantResetTests`, like
// `ParticipantIdentityDurabilityTests`: these tests mutate the
// process-wide `ParticipantStore` keys, and only membership in that
// `.serialized` suite keeps them from interleaving with its tests.

import Testing
import Foundation
@testable import PrimaeNative

@MainActor
fileprivate final class HandoverFakeSound: RecordedSounding {
    let name: String
    private let log: (String) -> Void
    private(set) var stopped = false
    var onFinish: ((Bool) -> Void)?
    var duration: TimeInterval { 1.0 }
    init(name: String, log: @escaping (String) -> Void) { self.name = name; self.log = log }
    func play() { log("play:\(name)") }
    func stop() { stopped = true; log("stop:\(name)") }
}

@MainActor
fileprivate enum Handover {
    /// Snapshot and restore every participant-scoped key these tests move.
    static func withIdentity(_ body: () async throws -> Void) async rethrows {
        let d = UserDefaults.standard
        let keys = ["de.flamingistan.primae.participantId", "de.flamingistan.primae.thesisEnrolled",
                    "de.flamingistan.primae.thesisEnrolledAt", "de.flamingistan.primae.thesisConditionOverride",
                    "de.flamingistan.primae.audioConditionOverride", "de.flamingistan.primae.trainedSubsetOverride",
                    RetrievalScheduler.counterKey, UserDefaultsSetCompletionLedger.key,
                    "de.flamingistan.primae.participantActivity"]
        let saved = keys.map { d.object(forKey: $0) }
        defer { for (k, v) in zip(keys, saved) { if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) } } }
        try await body()
    }

    static func temp() -> URL {
        let u = FileManager.default.temporaryDirectory
            .appendingPathComponent("HANDOVER-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    struct Stores {
        let dir: URL
        let center = PersistenceFailureCenter()
        let dash: JSONParentDashboardStore
        let arch: JSONParticipantArchiveStore
        let logDir: URL
        let log: JSONEnrolmentLog
        let ledger = StubSetCompletionLedger()
        init() {
            dir = Handover.temp()
            dash = JSONParentDashboardStore(fileURL: dir.appendingPathComponent("dash.json"), failureCenter: center)
            arch = JSONParticipantArchiveStore(directoryURL: dir.appendingPathComponent("arch"), failureCenter: center)
            logDir = dir.appendingPathComponent("enrol")
            log = JSONEnrolmentLog(directoryURL: logDir, failureCenter: center)
        }
    }

    /// A "launch": a fresh view model over the same on-disk stores, the
    /// arms read from the device defaults as `TracingDependencies()` does.
    static func launch(_ s: Stores, log: EnrolmentLogging? = nil) -> TracingViewModel {
        var deps = TracingDependencies.stub
            .with(dashboardStore: s.dash)
            .with(participantArchive: s.arch)
            .with(studyMode: true)
            .with(participantEnrolled: ParticipantStore.isEnrolled)
            .with(audioCondition: PilotAudioCondition.defaultForInstall)
            .with(trainedSubset: TrainedLetterSubset.defaultForInstall)
        deps.enrolmentLog = log ?? s.log
        deps.setCompletion = s.ledger
        return TracingViewModel(deps)
    }

    static func row(_ s: Stores, _ vm: TracingViewModel, letter: String, phase: String, probe: String? = nil) {
        s.dash.recordPhaseSession(letter: letter, phase: phase, completed: true, score: 0.7, schedulerPriority: 0,
                                  condition: .threePhase, audioCondition: vm.audioCondition, assessment: nil,
                                  recognition: nil, trainedSubset: vm.trainedSubset.rawValue, probe: probe)
    }
}

extension NewParticipantResetTests {

    // MARK: - A4 (C-3 / VERIFY-1): the prompt pipeline stops at the hand-over

    /// Mutation check: delete `silenceOutgoingChildsVoice()` from
    /// `resetForNewParticipant` — RED in both arms.
    @Test("next child: the outgoing child's prompt is stopped and its queued retry never reaches the incoming child",
          arguments: [PilotAudioCondition.phoneme, .silent])
    func promptPipelineIsStoppedAtNextChild(arm: PilotAudioCondition) async {
        await Handover.withIdentity {
            var log: [String] = []
            var sounds: [HandoverFakeSound] = []
            var deps = TracingDependencies.stub.with(studyMode: true)
            deps.audioCondition = arm
            deps.spokenFeedbackInStudy = true
            deps.participantArchive = StubParticipantArchive()
            deps.enrolmentLog = StubEnrolmentLog()
            deps.makePromptPlayer = { speech in
                PromptPlayer(fallbackSpeech: speech, speechFallback: false,
                             makeSound: { url in
                                 let s = HandoverFakeSound(name: url.lastPathComponent) { log.append($0) }
                                 sounds.append(s)
                                 return s
                             },
                             locate: { key in URL(fileURLWithPath: "/handover/\(key.rawValue).mp3") },
                             watchdogSleep: { _ in try? await Task.sleep(for: .seconds(3600)) })
            }
            let vm = TracingViewModel(deps)
            // The outgoing child: an instruction playing, a retry queued behind it.
            vm.prompts.play(.phaseGuided, fallbackText: "Jetzt du.")
            vm.prompts.play(.retryCue, fallbackText: "Probier's nochmal")
            #expect(log == ["play:phase_guided.mp3"], "precondition: the retry waits for the instruction: \(log)")
            let mark = log.count

            _ = vm.resetForNewParticipant()
            // The instruction's recording reaches its end, now under the incoming child.
            sounds.first?.onFinish?(true)

            let afterReset = Array(log.dropFirst(mark))
            #expect(sounds.first?.stopped == true,
                    "\(arm): the outgoing child's instruction was not stopped at 'Nächstes Kind': \(afterReset)")
            #expect(!afterReset.contains("play:retry_cue.mp3"),
                    "\(arm): the outgoing child's queued 'Probier's nochmal' played to the INCOMING child: \(afterReset)")
        }
    }

    /// The restore hands the device over the same way. Mutation check:
    /// delete `silenceOutgoingChildsVoice()` from `restoreParticipant` — RED.
    @Test("restore: the live child's prompt is stopped when another child is restored")
    func promptPipelineIsStoppedAtRestore() async {
        await Handover.withIdentity {
            var sounds: [HandoverFakeSound] = []
            var deps = TracingDependencies.stub.with(studyMode: true)
            deps.audioCondition = .phoneme
            deps.spokenFeedbackInStudy = true
            deps.participantArchive = StubParticipantArchive()
            deps.enrolmentLog = StubEnrolmentLog()
            deps.makePromptPlayer = { speech in
                PromptPlayer(fallbackSpeech: speech, speechFallback: false,
                             makeSound: { url in
                                 let s = HandoverFakeSound(name: url.lastPathComponent) { _ in }
                                 sounds.append(s)
                                 return s
                             },
                             locate: { key in URL(fileURLWithPath: "/handover/\(key.rawValue).mp3") },
                             watchdogSleep: { _ in try? await Task.sleep(for: .seconds(3600)) })
            }
            let vm = TracingViewModel(deps)
            let x = vm.resetForNewParticipant()
            ParticipantStore.markCurrentParticipantActive()   // a real child (r16 drops one with no activity, B2)
            _ = vm.resetForNewParticipant()            // Y is on the device; X is known
            vm.prompts.play(.phaseGuided, fallbackText: "Jetzt du.")
            #expect(sounds.count == 1, "precondition: one instruction playing")
            let result = vm.restoreParticipant(uuidString: x.uuidString)
            #expect(result == .restored(x), "precondition: \(result)")
            #expect(sounds.last?.stopped == true, "the live child's instruction played on through the restore")
        }
    }

    // MARK: - A5 (DATA-6): restore without an enrolment record

    /// Round-1 H6. Mutation check: make `recordedAssignment(for:)` return
    /// the derivation (nil, nil) when the record is missing — RED.
    @Test("a restored child gets the arm their rows were recorded under, even if the enrolment file was lost")
    func restoreWithLostEnrolmentRecordUsesArchivedArm() async throws {
        try await Handover.withIdentity {
            let s = Handover.Stores(); defer { try? FileManager.default.removeItem(at: s.dir) }
            var vm = Handover.launch(s)
            let x = vm.resetForNewParticipant()
            // The documented dry-run: enrol, override (before any row), relaunch.
            let override = PilotAudioCondition.assign(participantId: x).nextInCycle
            ParticipantStore.audioConditionOverride = override
            vm = Handover.launch(s)
            #expect(vm.audioCondition == override, "precondition: the override applied")
            Handover.row(s, vm, letter: "F", phase: "freeWrite")
            _ = vm.resetForNewParticipant()   // seal X, enrol Y
            await s.log.flush()
            // X's enrolment file is lost (corrupt -> quarantined at the next launch).
            try Data("{".utf8).write(to: s.logDir.appendingPathComponent("\(x.uuidString).json"))
            let log2 = JSONEnrolmentLog(directoryURL: s.logDir, failureCenter: PersistenceFailureCenter())
            vm = Handover.launch(s, log: log2)
            #expect(!log2.enrolments.contains { $0.participantId == x }, "precondition: X's record is gone")
            let result = vm.restoreParticipant(uuidString: x.uuidString)
            #expect(result == .restored(x), "restore result \(result)")
            let relaunched = Handover.launch(s, log: log2)
            #expect(relaunched.audioCondition == override,
                    "restored X runs the delayed test in \(relaunched.audioCondition) but trained in \(override)")
            await s.dash.flush(); await s.arch.flush()
        }
    }

    /// Mutation check: drop the `arms.count <= 1` guard — RED (restored).
    @Test("a restore with no enrolment record and archived rows in two arms is refused and changes nothing")
    func restoreWithConflictingArchivedArmsIsRefused() async {
        await Handover.withIdentity {
            let archive = StubParticipantArchive()
            let vm = TracingViewModel(.stub
                .with(studyMode: true)
                .with(participantArchive: archive))
            let x = UUID()
            for arm in [PilotAudioCondition.phoneme, .silent] {
                var snap = DashboardSnapshot()
                snap.phaseSessionRecords = [PhaseSessionRecord(letter: "F", phase: "freeWrite", completed: true,
                                                               score: 0.5, schedulerPriority: 0, audioCondition: arm)]
                archive.archive(ArchivedParticipant(participantId: x, enrolledAt: Date(), archivedAt: Date(),
                                                         snapshot: snap, progress: [:], rawTraces: []))
            }
            let live = ParticipantStore.participantId
            let result = vm.restoreParticipant(uuidString: x.uuidString)
            guard case .assignmentConflict(let message) = result else {
                Issue.record("rows in two arms were restored without a refusal: \(result)"); return
            }
            #expect(message.contains("nicht eindeutig"))
            #expect(ParticipantStore.participantId == live, "a refused restore switched the identity")
            #expect(!vm.participantIdentityChanged, "a refused restore blocked the session")
        }
    }

    // MARK: - A6 (DATA-7): probe attempts across a restore

    /// Round-1 H7. Mutation check: count only the live store again — RED.
    @Test("a repeated post-test after a restore is numbered after the archived attempt")
    func probeAttemptCountsArchivedSessions() async throws {
        await Handover.withIdentity {
            let s = Handover.Stores(); defer { try? FileManager.default.removeItem(at: s.dir) }
            let vm = Handover.launch(s)
            let x = vm.resetForNewParticipant()
            Handover.row(s, vm, letter: "A", phase: "freeWrite", probe: StudyProbe.posttest.rawValue)
            #expect(vm.priorProbeAttempts(letter: "A", kind: .posttest) == 1)
            _ = vm.resetForNewParticipant()
            #expect(vm.restoreParticipant(uuidString: x.uuidString) == .restored(x))
            let prior = vm.priorProbeAttempts(letter: "A", kind: .posttest)
            #expect(prior == 1, "after restoring X the app counts \(prior) prior post-tests of A (archive holds 1)")
            #expect(vm.probeWarning(letter: "A", kind: .posttest)?.contains("schon 1×") == true,
                    "the repeat warning does not fire after the restore")
            await s.dash.flush(); await s.arch.flush()
        }
    }

    // MARK: - A7 (VERIFY-2/3): an override after the first row

    /// Round-2 V1. Mutation check: remove the `assignmentOverrideAllowed`
    /// guard from `syncEnrolmentRecordToAppliedAssignment` — RED.
    @Test("an arm override set after the child has rows does not move that child to a second arm")
    func armOverrideAfterRowsKeepsOneArm() async throws {
        await Handover.withIdentity {
            let s = Handover.Stores(); defer { try? FileManager.default.removeItem(at: s.dir) }
            var vm = Handover.launch(s)
            let x = vm.resetForNewParticipant()
            vm = Handover.launch(s)
            let trainedArm = vm.audioCondition
            #expect(vm.assignmentOverrideAllowed, "no row yet: an override may still apply")
            Handover.row(s, vm, letter: "F", phase: "observe")
            #expect(!vm.assignmentOverrideAllowed, "the child has a row: no override may apply")
            ParticipantStore.audioConditionOverride = trainedArm.nextInCycle
            vm.markAssignmentOverrideChanged()
            vm = Handover.launch(s)   // the relaunch the block asks for
            Handover.row(s, vm, letter: "F", phase: "guided")
            let arms = Set(s.dash.snapshot.phaseSessionRecords.map(\.audioCondition))
            let record = vm.enrolmentRecords.last { $0.participantId == x }
            #expect(arms == [trainedArm], "one child, rows in \(arms)")
            #expect(record?.audioCondition == trainedArm, "the enrolment record was rewritten to \(String(describing: record?.audioCondition))")
            #expect(vm.assignmentOverrideRefusal != nil, "the proctor was not told the override was refused")
            #expect(PilotAudioCondition.defaultForInstall == trainedArm, "the refused override still stands for the next launch")
            await s.dash.flush(); await s.log.flush()
        }
    }

    /// Round-2 V2. Same mutation as above — RED.
    @Test("a subset override after training rows does not change the child's trained letters")
    func subsetOverrideAfterRowsKeepsSubset() async throws {
        await Handover.withIdentity {
            let s = Handover.Stores(); defer { try? FileManager.default.removeItem(at: s.dir) }
            var vm = Handover.launch(s)
            _ = vm.resetForNewParticipant()
            vm = Handover.launch(s)
            let before = vm.trainedSubset
            let first = before.letters.first!
            Handover.row(s, vm, letter: String(first), phase: "freeWrite")
            let other = TrainedLetterSubset.allSubsets.first { $0 != before && !$0.letters.contains(first) }!
            ParticipantStore.trainedSubsetOverride = other
            vm.markAssignmentOverrideChanged()
            vm = Handover.launch(s)
            #expect(vm.trainedSubset == before,
                    "trained subset changed from \(before.rawValue) to \(vm.trainedSubset.rawValue) after \(first) was trained")
            #expect(vm.visibleLetterNames.allSatisfy { before.letters.contains($0) },
                    "the session's letters are not the recorded subset's: \(vm.visibleLetterNames)")
            await s.dash.flush(); await s.log.flush()
        }
    }

    /// Control: before the first row the override still applies and the
    /// record follows it (R-016 unchanged).
    @Test("an arm override set before the child's first row still applies and the record follows it")
    func armOverrideBeforeRowsApplies() async throws {
        await Handover.withIdentity {
            let s = Handover.Stores(); defer { try? FileManager.default.removeItem(at: s.dir) }
            var vm = Handover.launch(s)
            let x = vm.resetForNewParticipant()
            let override = vm.audioCondition.nextInCycle
            ParticipantStore.audioConditionOverride = override
            vm = Handover.launch(s)
            #expect(vm.audioCondition == override)
            #expect(vm.enrolmentRecords.last { $0.participantId == x }?.audioCondition == override)
            #expect(vm.assignmentOverrideRefusal == nil)
            await s.log.flush()
        }
    }

    // MARK: - B2 (STATE-3): a phantom enrolment is dropped at the next enrolment

    /// Mutation check: delete `dropOutgoingEnrolmentIfInactive()` from
    /// `resetForNewParticipant` — RED.
    @Test("next child: an enrolment with no touch, probe, unpark or row is dropped from the enrolment log")
    func inactiveEnrolmentIsDroppedAtNextChild() async throws {
        await Handover.withIdentity {
            let s = Handover.Stores(); defer { try? FileManager.default.removeItem(at: s.dir) }
            let vm = Handover.launch(s)
            let phantom = vm.resetForNewParticipant()
            #expect(s.log.enrolments.map(\.participantId) == [phantom], "precondition: the enrolment is logged")
            let next = vm.resetForNewParticipant()   // a double tap: nothing happened in between
            #expect(s.log.enrolments.map(\.participantId) == [next],
                    "the phantom enrolment is still in the log: \(s.log.enrolments.map(\.participantId))")
            await s.log.flush()
            let reread = JSONEnrolmentLog(directoryURL: s.logDir, failureCenter: s.center)
            #expect(reread.enrolments.map(\.participantId) == [next], "the phantom's file is still on disk")
        }
    }

    /// A touch survives a relaunch and keeps the enrolment. Mutation check:
    /// delete `noteParticipantActivity()` from `beginTouch` — RED.
    @Test("next child: a child who touched the canvas keeps the enrolment record, across a relaunch")
    func touchedEnrolmentIsKept() async throws {
        await Handover.withIdentity {
            let s = Handover.Stores(); defer { try? FileManager.default.removeItem(at: s.dir) }
            let first = Handover.launch(s)
            let child = first.resetForNewParticipant()
            first.beginTouch(at: CGPoint(x: 50, y: 200), t: 1000)   // one sample, no move
            let relaunched = Handover.launch(s)
            let next = relaunched.resetForNewParticipant()
            #expect(Set(s.log.enrolments.map(\.participantId)) == [child, next],
                    "a child who touched the canvas lost the enrolment record")
            await s.log.flush()
        }
    }

    /// Control: a child with a row is sealed AND keeps the record.
    @Test("next child: a child with a row keeps the enrolment record")
    func enrolmentWithRowIsKept() async throws {
        await Handover.withIdentity {
            let s = Handover.Stores(); defer { try? FileManager.default.removeItem(at: s.dir) }
            let vm = Handover.launch(s)
            let child = vm.resetForNewParticipant()
            Handover.row(s, vm, letter: "A", phase: "observe")
            let next = vm.resetForNewParticipant()
            #expect(Set(s.log.enrolments.map(\.participantId)) == [child, next])
            await s.log.flush()
        }
    }

    // MARK: - B5 (DATA-9 / VERIFY-4)

    /// Each child counted once, archive and enrolment log together; a
    /// sealed child with no record counts under the arm its rows name.
    /// Mutation check: make `assignmentTally` read the enrolment log only
    /// (skip ids without a record) — RED.
    @Test("research dashboard: the tally counts every child once, a record-less archived child by its rows")
    func assignmentTallyCountsChildrenOnce() async throws {
        try await Handover.withIdentity {
            let s = Handover.Stores(); defer { try? FileManager.default.removeItem(at: s.dir) }
            let vm = Handover.launch(s)
            // An earlier child sealed with no enrolment record (pre-log, or quarantined).
            var snap = DashboardSnapshot()
            snap.phaseSessionRecords = [PhaseSessionRecord(letter: "F", phase: "freeWrite", completed: true,
                                                           score: 0.5, schedulerPriority: 0, audioCondition: .silent,
                                                           trainedSubset: "AFI")]
            try s.arch.archive(ArchivedParticipant(participantId: UUID(), enrolledAt: Date(), archivedAt: Date(),
                                               snapshot: snap, progress: [:], rawTraces: []))
            _ = vm.resetForNewParticipant()                   // child A: record
            Handover.row(s, vm, letter: "A", phase: "observe")
            _ = vm.resetForNewParticipant()                   // A sealed (record + archive), child B: record
            let tally = vm.assignmentTally
            #expect(tally.children == 3, "children: \(tally)")
            #expect(tally.arms.values.reduce(0, +) == 3 && tally.unknownArm == 0, "arms: \(tally)")
            #expect(tally.subsets.values.reduce(0, +) == 3 && tally.unknownSubset == 0, "subsets: \(tally)")
            var expectedArms: [PilotAudioCondition: Int] = [.silent: 1]
            for r in s.log.enrolments { expectedArms[r.audioCondition, default: 0] += 1 }
            #expect(tally.arms == expectedArms, "arms: \(tally.arms) expected \(expectedArms)")
            await s.log.flush()
        }
    }

    /// Mutation check: make `confirmText` drop the override notice — RED.
    @Test("next child: the confirm text names an override that the new child will not get")
    func confirmTextNamesPendingOverride() async {
        await Handover.withIdentity {
            let s = Handover.Stores(); defer { try? FileManager.default.removeItem(at: s.dir) }
            let vm = Handover.launch(s)
            ParticipantStore.audioConditionOverride = nil
            ParticipantStore.trainedSubsetOverride = nil
            ParticipantStore.conditionOverride = nil
            #expect(NextParticipantCopy.confirmText(banner: nil, overrides: vm.pendingAssignmentOverrides)
                    == NextParticipantCopy.confirmMessage, "control: no override, no notice")
            ParticipantStore.audioConditionOverride = .silent
            let text = NextParticipantCopy.confirmText(banner: nil, overrides: vm.pendingAssignmentOverrides)
            #expect(text.contains(PilotAudioCondition.silent.displayName) && text.contains("verworfen"),
                    "the confirm text does not name the pending override: \(text)")
            #expect(text.hasSuffix(NextParticipantCopy.confirmMessage))
        }
    }
}
