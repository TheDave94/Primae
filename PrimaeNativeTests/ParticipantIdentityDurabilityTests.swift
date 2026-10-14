// Participant identity and durability (audit 2026-10-13, lane B1):
// the background drain, the seal-before-wipe ordering, restore, the
// enrolment record's arm, the live participant in the export, and the
// end-of-set hold across a relaunch.
//
// An EXTENSION of `NewParticipantResetTests`, not a suite of its own:
// these tests mutate the same process-wide `ParticipantStore` keys, and
// only membership in that `.serialized` suite keeps them from
// interleaving with its tests.

import Testing
import Foundation
@testable import PrimaeNative

extension NewParticipantResetTests {

    /// Snapshot and restore the participant-scoped overrides and the
    /// enrolment flag this file mutates. Async so a body can await a flush.
    fileprivate func withRestoredIdentity(_ body: () async throws -> Void) async rethrows {
        let pedOverride    = ParticipantStore.conditionOverride
        let audioOverride  = ParticipantStore.audioConditionOverride
        let subsetOverride = ParticipantStore.trainedSubsetOverride
        let enrolled       = ParticipantStore.isEnrolled
        defer {
            ParticipantStore.conditionOverride = pedOverride
            ParticipantStore.audioConditionOverride = audioOverride
            ParticipantStore.trainedSubsetOverride = subsetOverride
            ParticipantStore.isEnrolled = enrolled
        }
        try await body()
    }

    // MARK: - R-049: the participant archive is drained on background

    /// "Nächstes Kind" followed by the iPad being put away is the normal end
    /// of a batch, so the archive is the store whose pending write matters
    /// most when the app is backgrounded. The drain covered six stores and
    /// not this one. Mutation check: delete the archive's `flush()` from
    /// `appDidEnterBackground` — this goes RED.
    @Test("backgrounding drains the participant archive")
    func backgroundingDrainsTheParticipantArchive() async {
        let archive = StubParticipantArchive()
        let vm = TracingViewModel(.stub.with(participantArchive: archive))
        #expect(archive.flushCount == 0)

        await vm.appDidEnterBackground()

        #expect(archive.flushCount == 1,
                "the sealed-children archive must be drained with the other stores")
    }

    // MARK: - R-059: the live participant is exported only if they did anything

    /// The archive guard (#21) keeps a child who recorded nothing out of the
    /// sealed set, but the export appended the LIVE participant
    /// unconditionally — so an extra "Nächstes Kind" after the last child (or
    /// an export at the start of a day) put a zero-row block with a valid id
    /// header back into `all<N>`. That child is still in the enrolment block.
    /// Mutation check: append `current` unconditionally again — RED.
    @Test("a live participant who recorded nothing is not an export source")
    func emptyLiveParticipantIsNotExported() async {
        await withRestoredIdentity {
            let dashboardURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: dashboardURL) }
            let dashboard = JSONParentDashboardStore(fileURL: dashboardURL)
            let vm = TracingViewModel(.stub
                .with(dashboardStore: dashboard)
                .with(participantArchive: StubParticipantArchive())
                .with(studyMode: true))

            _ = vm.resetForNewParticipant()   // the live child has no rows

            #expect(vm.allParticipantExportSources.isEmpty,
                    "a zero-row live participant is a phantom in all<N>: \(vm.allParticipantExportSources.map(\.participantId))")

            // Control: once they record a row, they ARE exported.
            dashboard.recordPhaseSession(letter: "M", phase: "guided", completed: true,
                                         score: 0.6, schedulerPriority: 0, condition: .threePhase)
            #expect(vm.allParticipantExportSources.map(\.participantId) == [ParticipantStore.participantId],
                    "a live participant with rows must be exported")
        }
    }

    // MARK: - R-050: the seal is confirmed durable BEFORE anything is wiped

    /// An archive directory nothing can be written into: its parent is a
    /// regular FILE, so every write below it fails with "not a directory".
    fileprivate func unwritableArchiveDirectory() -> (archiveDir: URL, blocker: URL) {
        let blocker = FileManager.default.temporaryDirectory
            .appendingPathComponent("blocker-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: blocker.path, contents: Data("x".utf8))
        return (blocker.appendingPathComponent("ParticipantArchive", isDirectory: true), blocker)
    }

    /// The seal was an in-memory append plus a detached write, and the live
    /// stores were reset synchronously right after it — so when the write
    /// failed, the only copy of the outgoing child was in memory, and the
    /// failure message told the proctor to relaunch. Now the reset must not
    /// wipe a child whose seal is not on disk. Mutation check: wipe even
    /// when the seal throws — RED.
    @Test("a child whose seal cannot be written is not wiped and keeps the device")
    func unsealableChildIsNotWiped() async {
        await withRestoredIdentity {
            let dashboardURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString).json")
            let (archiveDir, blocker) = unwritableArchiveDirectory()
            defer {
                try? FileManager.default.removeItem(at: dashboardURL)
                try? FileManager.default.removeItem(at: blocker)
            }
            let dashboard = JSONParentDashboardStore(fileURL: dashboardURL)
            let archive = JSONParticipantArchiveStore(directoryURL: archiveDir)
            let vm = TracingViewModel(.stub
                .with(dashboardStore: dashboard)
                .with(participantArchive: archive)
                .with(studyMode: true))
            dashboard.recordPhaseSession(letter: "F", phase: "freeWrite", completed: true,
                                         score: 0.55, schedulerPriority: 0, condition: .threePhase)
            let outgoing = ParticipantStore.participantId

            _ = vm.resetForNewParticipant()
            await archive.flush()

            #expect(vm.dashboardSnapshot.phaseSessionRecords.contains { $0.letter == "F" && $0.score == 0.55 },
                    "the live child's rows were wiped although their seal never reached the disk")
            #expect(ParticipantStore.participantId == outgoing,
                    "a new child was enrolled over an unsealed one")
            // …and the proctor is told so, without the advice to relaunch
            // that used to accompany an archive write failure.
            #expect(vm.participantSealFailure == TracingViewModel.participantSealFailureMessage)
            #expect(vm.participantSealFailure?.contains("neu starten") == false)
        }
    }

    // MARK: - R-047: restore seals the live child and never replaces an archive

    fileprivate func archivedRecord(_ id: UUID, enrolledAt: Date, archivedAt: Date,
                                    letter: String) -> ArchivedParticipant {
        var snapshot = DashboardSnapshot()
        snapshot.phaseSessionRecords.append(PhaseSessionRecord(
            letter: letter, phase: "freeWrite", completed: true, score: 0.5,
            schedulerPriority: 0, recordedAt: enrolledAt.addingTimeInterval(60)))
        return ArchivedParticipant(participantId: id, enrolledAt: enrolledAt,
                                   archivedAt: archivedAt, snapshot: snapshot,
                                   progress: [:], rawTraces: [])
    }

    /// A restored child is sealed a SECOND time when the delayed session
    /// ends. The archive was keyed by participant id — `removeAll` in memory
    /// and the same `<uuid>.json` on disk — so that second seal destroyed
    /// the training record. Mutation check: key the file by id again — RED.
    @Test("sealing the same participant twice keeps both records, on disk")
    func archiveIsAppendOnly() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let store = JSONParticipantArchiveStore(directoryURL: dir)

        try store.archive(archivedRecord(id, enrolledAt: t0, archivedAt: t0.addingTimeInterval(600),
                                         letter: "I"))
        try store.archive(archivedRecord(id, enrolledAt: t0.addingTimeInterval(86_400 * 30),
                                         archivedAt: t0.addingTimeInterval(86_400 * 30 + 600),
                                         letter: "M"))

        let reopened = JSONParticipantArchiveStore(directoryURL: dir)
        let letters = reopened.archivedParticipants
            .filter { $0.participantId == id }
            .flatMap { $0.snapshot.phaseSessionRecords.map(\.letter) }
        #expect(letters == ["I", "M"],
                "the training seal must survive the delayed seal, oldest first: \(letters)")
    }

    /// The register's scenario (Q5): A is sealed, C is the live child, and
    /// the proctor restores A for the delayed test. C must be sealed under
    /// C's id (not relabelled as A and filtered out of every export), the
    /// live stores must start empty for A, and A's delayed seal must not
    /// replace A's training seal. Mutation checks: drop the seal from the
    /// restore path — RED (C missing); drop the wipe — RED (C's row live
    /// under A); key the archive by id — RED (A-training missing).
    @Test("restoring a participant seals the live child and keeps every earlier seal")
    func restoreSealsTheLiveChildAndKeepsEarlierSeals() async throws {
        try await withRestoredIdentity {
            let dashboardURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString).json")
            let archiveDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("archive-\(UUID().uuidString)", isDirectory: true)
            defer {
                try? FileManager.default.removeItem(at: dashboardURL)
                try? FileManager.default.removeItem(at: archiveDir)
            }
            let dashboard = JSONParentDashboardStore(fileURL: dashboardURL)
            let archive = JSONParticipantArchiveStore(directoryURL: archiveDir)
            let vm = TracingViewModel(.stub
                .with(dashboardStore: dashboard)
                .with(participantArchive: archive)
                .with(studyMode: true))

            // Day 1: child A trains, child C trains and is still live.
            _ = vm.resetForNewParticipant()
            let childA = ParticipantStore.participantId
            dashboard.recordPhaseSession(letter: "I", phase: "freeWrite", completed: true,
                                         score: 0.9, schedulerPriority: 0, condition: .threePhase)
            let childC = vm.resetForNewParticipant()
            dashboard.recordPhaseSession(letter: "L", phase: "freeWrite", completed: true,
                                         score: 0.4, schedulerPriority: 0, condition: .threePhase)

            // Day 30: restore A.
            #expect(vm.restoreParticipant(uuidString: childA.uuidString) == .restored(childA))
            #expect(ParticipantStore.participantId == childA)
            #expect(archive.archivedParticipants.contains {
                $0.participantId == childC && $0.snapshot.phaseSessionRecords.contains { $0.letter == "L" }
            }, "the live child must be sealed under their own id before the identity switches")
            #expect(vm.dashboardSnapshot.phaseSessionRecords.isEmpty,
                    "the outgoing child's rows must not stay live under the restored id")

            // A's delayed session, then the next child.
            dashboard.recordPhaseSession(letter: "M", phase: "freeWrite", completed: true,
                                         score: 0.7, schedulerPriority: 0, condition: .threePhase)
            _ = vm.resetForNewParticipant()
            await archive.flush()

            let reopened = JSONParticipantArchiveStore(directoryURL: archiveDir)
            @MainActor func letters(_ id: UUID) -> [String] {
                reopened.archivedParticipants.filter { $0.participantId == id }
                    .flatMap { $0.snapshot.phaseSessionRecords.map(\.letter) }
            }
            #expect(letters(childA).sorted() == ["I", "M"],
                    "A's training seal and A's delayed seal must both be on disk: \(letters(childA))")
            #expect(letters(childC) == ["L"], "C must be on disk under C's id: \(letters(childC))")
            #expect(vm.allParticipantExportSources.contains { $0.participantId == childC },
                    "C must be in the combined export")
        }
    }

    // MARK: - R-048: restore accepts only an id this device knows

    /// The restore copy pointed the proctor at the first line of the
    /// combined export — the OLDEST child — and any well-formed UUID was
    /// accepted, so a typo or the wrong line silently re-derived a random
    /// arm and subset and labelled the delayed rows as somebody else.
    /// Mutation check: accept any parseable UUID again — RED.
    @Test("restore refuses a UUID that is neither archived nor enrolled here")
    func restoreRefusesAnUnknownID() async {
        await withRestoredIdentity {
            let vm = TracingViewModel(.stub.with(studyMode: true))
            let before = ParticipantStore.participantId
            let stranger = UUID()

            let result = vm.restoreParticipant(uuidString: stranger.uuidString)

            #expect(result == .unknownID, "an unknown id was not refused as unknown: \(result)")
            #expect(ParticipantStore.participantId == before,
                    "a refused restore must leave the identity untouched")
            #expect(vm.sessionBlockReason == nil, "a refused restore must not block the session")
        }
    }

    // MARK: - R-016: the enrolment record holds the arm the child actually ran

    fileprivate func studyDeps(log: StubEnrolmentLog) -> TracingDependencies {
        var deps = TracingDependencies.stub
            .with(participantArchive: StubParticipantArchive())
            .with(studyMode: true)
        deps.enrolmentLog = log
        return deps
    }

    /// The dry-run procedure is: enrol, set the override, relaunch. The
    /// record was written at enrolment, from the UUID-derived arm, and
    /// nothing updated it — so the enrolment block named a different arm
    /// and subset than every row. Mutation check: drop the record update at
    /// launch — RED.
    @Test("an override applied at relaunch reaches the enrolment record, enrolment time kept")
    func overrideReachesTheEnrolmentRecord() async {
        await withRestoredIdentity {
            let log = StubEnrolmentLog()
            let deps = studyDeps(log: log)
            let vm = TracingViewModel(deps)
            let child = vm.resetForNewParticipant()
            guard let enrolled = log.enrolments.last else {
                Issue.record("precondition: enrolment not logged"); return
            }
            let otherArm = PilotAudioCondition.allCases.first { $0 != enrolled.audioCondition }!
            let otherSubset = TrainedLetterSubset.allSubsets.first { $0.rawValue != enrolled.trainedSubset }!
            ParticipantStore.audioConditionOverride = otherArm
            ParticipantStore.trainedSubsetOverride = otherSubset

            // The relaunch: production deps read the assignment, overrides included.
            let relaunched = TracingViewModel(deps
                .with(audioCondition: .defaultForInstall)
                .with(trainedSubset: .defaultForInstall))
            #expect(relaunched.audioCondition == otherArm, "precondition: the override is applied")

            let record = log.enrolments.first { $0.participantId == child }
            #expect(record?.audioCondition == otherArm,
                    "the enrolment block names a different arm than the rows")
            #expect(record?.trainedSubset == otherSubset.rawValue)
            #expect(record?.enrolledAt == enrolled.enrolledAt, "the enrolment time must not move")
            #expect(log.enrolments.count == 1)
        }
    }

    /// Restore cleared all three overrides and told the proctor to re-apply
    /// them by hand from the export; forgetting meant the delayed rows ran
    /// in the UUID-derived arm, not the arm the child trained in. The
    /// device's enrolment record knows the arm, so restore re-applies it.
    /// Mutation check: skip the re-application — RED.
    @Test("restore re-applies the arm and subset the child was recorded with")
    func restoreReappliesTheRecordedAssignment() async {
        await withRestoredIdentity {
            let log = StubEnrolmentLog()
            let vm = TracingViewModel(studyDeps(log: log))
            let childA = vm.resetForNewParticipant()
            let derivedArm = PilotAudioCondition.assign(participantId: childA)
            let derivedSubset = TrainedLetterSubset.assign(participantId: childA)
            let otherArm = PilotAudioCondition.allCases.first { $0 != derivedArm }!
            let otherSubset = TrainedLetterSubset.allSubsets.first { $0 != derivedSubset }!
            // A trained under an override (what the record now holds).
            log.append(EnrolmentRecord(participantId: childA,
                                       enrolledAt: ParticipantStore.enrolledAt,
                                       audioCondition: otherArm,
                                       trainedSubset: otherSubset.rawValue,
                                       protocolRevision: StudyProtocol.revision))
            _ = vm.resetForNewParticipant()   // child B

            #expect(vm.restoreParticipant(uuidString: childA.uuidString) == .restored(childA))

            #expect(PilotAudioCondition.defaultForInstall == otherArm,
                    "the delayed session would run in the UUID-derived arm, not the trained one")
            #expect(TrainedLetterSubset.defaultForInstall == otherSubset)
        }
    }

    /// "Nächstes Kind" clears every override and re-derives the arms in
    /// place, but the override-changed flag survived it, so every later
    /// child saw "Zuweisung geändert — App neu starten": the relaunch #22
    /// removed. Mutation check: stop clearing the flag on enrolment — RED.
    @Test("an override set for one child does not block the next child")
    func overrideFlagDoesNotOutliveTheChild() async {
        await withRestoredIdentity {
            let vm = TracingViewModel(studyDeps(log: StubEnrolmentLog()))
            _ = vm.resetForNewParticipant()
            vm.markAssignmentOverrideChanged()
            #expect(vm.sessionBlockReason != nil, "precondition: the override blocks this child")

            _ = vm.resetForNewParticipant()

            #expect(vm.sessionBlockReason == nil,
                    "the next child is blocked by an override that enrolment already cleared")
        }
    }

    // MARK: - R-033: the end-of-set hold survives a relaunch

    /// The hold was an in-memory flag. After a crash or force-quit at set
    /// end the relaunched app parked on the first trained letter of the
    /// SAME participant, and one pill tap started a second full pass under
    /// that id. Mutation checks: stop reading the ledger at launch — RED;
    /// let the pill start a parked letter while held — RED.
    @Test("a relaunch after the set ended keeps the hold until the next child")
    func setEndHoldSurvivesARelaunch() async {
        await withRestoredIdentity {
            let ledger = StubSetCompletionLedger()
            var deps = studyDeps(log: StubEnrolmentLog())
            deps.setCompletion = ledger
            let vm = TracingViewModel(deps)
            _ = vm.resetForNewParticipant()
            vm.finishSetAwaitingNextParticipant()

            let relaunched = TracingViewModel(deps)
            #expect(relaunched.launchParked, "precondition: a study launch parks its first letter")
            #expect(relaunched.awaitingNextParticipant,
                    "the relaunched app reopened a set this participant already finished")
            relaunched.startParkedLetter()
            #expect(relaunched.launchParked,
                    "the observe pill started a second training pass under the same id")

            _ = relaunched.resetForNewParticipant()
            #expect(!relaunched.awaitingNextParticipant, "the next child must not inherit the hold")
        }
    }

    // MARK: - Review item 2: a restored child is ONE participant in the count

    /// Since R-047 a restored child exports as two blocks (training seal +
    /// delayed seal) under one participantId. The file name's participant
    /// count was `participants.count`, so that child counted twice. The
    /// count is of distinct participant ids. Mutation check: count blocks
    /// again — RED.
    @Test("the export's participant count counts a restored child once")
    func exportCountsDistinctParticipants() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let restored = UUID(), other = UUID()
        func source(_ id: UUID) -> ParticipantExportSource {
            ParticipantExportSource(snapshot: DashboardSnapshot(), participantId: id,
                                    progress: [:], rawTraces: [], enrolledAt: nil)
        }
        let sources = [source(restored), source(other), source(restored)]

        #expect(ParentDashboardExporter.distinctParticipantCount(sources) == 2)
        let url = try ParentDashboardExporter.combinedExportFileURL(
            participants: sources, format: .csv, tempDirectory: tmp)
        #expect(url.lastPathComponent.hasSuffix("_all2.csv"),
                "a restored child's two blocks were counted as two participants: \(url.lastPathComponent)")
    }

    // MARK: - Review item 3: the seal is idempotent

    fileprivate func realStoresVM() -> (vm: TracingViewModel, dashboard: JSONParentDashboardStore,
                                        archiveDir: URL, dashboardURL: URL) {
        let dashboardURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).json")
        let archiveDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-\(UUID().uuidString)", isDirectory: true)
        let dashboard = JSONParentDashboardStore(fileURL: dashboardURL)
        let vm = TracingViewModel(.stub
            .with(dashboardStore: dashboard)
            .with(participantArchive: JSONParticipantArchiveStore(directoryURL: archiveDir))
            .with(studyMode: true))
        return (vm, dashboard, archiveDir, dashboardURL)
    }

    /// The reviewer's hazard (hazardCrashBetweenSealAndWipeDuplicates): the
    /// seal lands, the process dies before the wipe and the identity switch
    /// persist, and after the relaunch the proctor taps "Nächstes Kind"
    /// again — the same session was sealed twice and exported as two
    /// identical blocks. Mutation check: drop the reuse check — RED.
    @Test("a session already sealed is reused, not sealed a second time")
    func resealingTheSameSessionIsIdempotent() async throws {
        try await withRestoredIdentity {
            let (vm, dashboard, archiveDir, dashboardURL) = realStoresVM()
            defer {
                try? FileManager.default.removeItem(at: dashboardURL)
                try? FileManager.default.removeItem(at: archiveDir)
            }
            let child = vm.resetForNewParticipant()
            dashboard.recordPhaseSession(letter: "F", phase: "freeWrite", completed: true,
                                         score: 0.5, schedulerPriority: 0, condition: .threePhase)
            // The seal half of resetForNewParticipant, then "the process dies".
            try vm.participantArchive.archive(ArchivedParticipant(
                participantId: child, enrolledAt: ParticipantStore.enrolledAt,
                archivedAt: Date(), snapshot: dashboard.snapshot,
                progress: [:], rawTraces: []))
            // Relaunch: identity and live rows unchanged; the proctor taps again.
            let relaunched = TracingViewModel(.stub
                .with(dashboardStore: dashboard)
                .with(participantArchive: JSONParticipantArchiveStore(directoryURL: archiveDir))
                .with(studyMode: true))
            let next = relaunched.resetForNewParticipant()

            #expect(next != child, "the reset must still go through")
            let seals = JSONParticipantArchiveStore(directoryURL: archiveDir)
                .archivedParticipants.filter { $0.participantId == child }
            #expect(seals.count == 1, "the same session was sealed \(seals.count) times")
        }
    }

    /// The other side of the key: the same child, the same enrolment, but
    /// MORE rows (the session continued after an earlier seal of it) is a
    /// different session record and must be sealed. Guards the reuse check
    /// against swallowing real data.
    @Test("a later, larger session of the same child is still sealed")
    func aLargerSessionOfTheSameChildIsSealed() async throws {
        try await withRestoredIdentity {
            let (vm, dashboard, archiveDir, dashboardURL) = realStoresVM()
            defer {
                try? FileManager.default.removeItem(at: dashboardURL)
                try? FileManager.default.removeItem(at: archiveDir)
            }
            let child = vm.resetForNewParticipant()
            dashboard.recordPhaseSession(letter: "F", phase: "freeWrite", completed: true,
                                         score: 0.5, schedulerPriority: 0, condition: .threePhase)
            try vm.participantArchive.archive(ArchivedParticipant(
                participantId: child, enrolledAt: ParticipantStore.enrolledAt,
                archivedAt: Date(), snapshot: dashboard.snapshot,
                progress: [:], rawTraces: []))
            dashboard.recordPhaseSession(letter: "I", phase: "freeWrite", completed: true,
                                         score: 0.6, schedulerPriority: 0, condition: .threePhase)

            _ = vm.resetForNewParticipant()

            let rowCounts = JSONParticipantArchiveStore(directoryURL: archiveDir)
                .archivedParticipants.filter { $0.participantId == child }
                .map(\.snapshot.phaseSessionRecords.count).sorted()
            #expect(rowCounts == [1, 2], "the larger session was not sealed: \(rowCounts)")
        }
    }

    // MARK: - Review item 4: the enrolment log is drained on background

    /// R-016 made the launch re-append the child's enrolment record (the
    /// applied arm), and `JSONEnrolmentLog` writes in a detached task — so
    /// the drain must cover it. Mutation check: drop the enrolment log's
    /// flush from `appDidEnterBackground` — RED.
    @Test("backgrounding drains the enrolment log")
    func backgroundingDrainsTheEnrolmentLog() async {
        let log = StubEnrolmentLog()
        var deps = TracingDependencies.stub
        deps.enrolmentLog = log
        let vm = TracingViewModel(deps)
        #expect(log.flushCount == 0)

        await vm.appDidEnterBackground()

        #expect(log.flushCount == 1, "the enrolment record update must be drained with the other stores")
    }

    // MARK: - Review item 5: the read-back verification is load-bearing

    /// A write that lands bytes which are not this child's record (here:
    /// another participant's id) must not count as a seal. Without the
    /// read-back check the store moved such a file into place and reported
    /// success, and the caller wiped the real child. Mutation check: remove
    /// the read-back verification from `archive(_:)` — RED.
    @Test("a seal whose bytes do not read back as the child's record is refused")
    func sealThatDoesNotReadBackIsRefused() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let child = UUID(), impostor = UUID()
        let store = JSONParticipantArchiveStore(directoryURL: dir, writeStaged: { data, url in
            let text = String(decoding: data, as: UTF8.self)
                .replacingOccurrences(of: child.uuidString, with: impostor.uuidString)
            try Data(text.utf8).write(to: url, options: .atomic)
        })
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)

        #expect(throws: (any Error).self) {
            try store.archive(archivedRecord(child, enrolledAt: t0, archivedAt: t0, letter: "A"))
        }
        #expect(store.archivedParticipants.isEmpty, "a seal that failed verification was kept in memory")
        #expect(JSONParticipantArchiveStore(directoryURL: dir).archivedParticipants.isEmpty,
                "a seal that failed verification became visible on disk")
    }

    // MARK: - Review item 6: stale staging files are cleaned at launch

    /// A seal interrupted between its staged write and the move leaves a
    /// `.json.sealing` file. It is inert (the loader reads only `.json`)
    /// but it accumulates. A launch removes the stale ones — and nothing
    /// else: not a real seal, not a file of any other name, not a staging
    /// file newer than the launch. Mutation check: skip the cleanup — RED.
    @Test("a launch removes stale staging files and never a real seal")
    func staleStagingFilesAreCleanedAtLaunch() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        let child = UUID()
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        try JSONParticipantArchiveStore(directoryURL: dir)
            .archive(archivedRecord(child, enrolledAt: t0, archivedAt: t0, letter: "A"))
        let seals = try fm.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".json") }
        #expect(seals.count == 1, "precondition: one real seal")

        func make(_ name: String, modified: Date) throws -> URL {
            let url = dir.appendingPathComponent(name)
            try Data("{}".utf8).write(to: url)
            try fm.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
            return url
        }
        let anHourAgo = Date().addingTimeInterval(-3600)
        let stale   = try make("\(UUID().uuidString)_1.json.sealing", modified: anHourAgo)
        let other   = try make("notes.sealing", modified: anHourAgo)
        let future  = try make("\(UUID().uuidString)_2.json.sealing", modified: Date().addingTimeInterval(3600))

        let relaunched = JSONParticipantArchiveStore(directoryURL: dir)

        #expect(!fm.fileExists(atPath: stale.path), "a stale staging file survived the launch")
        #expect(fm.fileExists(atPath: other.path), "a file that is not a staged seal was removed")
        #expect(fm.fileExists(atPath: future.path), "a staging file newer than the launch was removed")
        #expect(fm.fileExists(atPath: dir.appendingPathComponent(seals[0]).path), "a real seal was removed")
        #expect(relaunched.archivedParticipants.map(\.participantId) == [child])
    }
}
