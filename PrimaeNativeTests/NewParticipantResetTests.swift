// Proves the new-participant reset: a fresh enrollee on a shared study
// device gets a NEW UUID (which re-derives BOTH arm axes, decorrelated),
// cleared researcher overrides, a re-stamped enrolment, and wiped
// participant data stores — while device/parent config survives.
//
// Identity logic is exercised directly on ParticipantStore; the
// store-wipe is exercised through TracingViewModel.resetForNewParticipant
// with a temp-file dashboard store.

import Testing
import Foundation
@testable import PrimaeNative

@Suite(.serialized) @MainActor struct NewParticipantResetTests {

    private let studyModeKey   = StudyBuild.studyModeDefaultsKey
    private let schriftArtKey  = SettingsView.defaultsKey   // from the owner, not re-declared
    // Read from the owner, not re-declared: a third copy of the string
    // would make this suite prove only that it agrees with itself.
    private let retrievalKey   = RetrievalScheduler.counterKey

    /// Snapshot the global participant-scoped keys this suite mutates and
    /// restore them after each test so suites stay independent.
    private func withRestoredState(_ body: () -> Void) {
        let pedOverride   = ParticipantStore.conditionOverride
        let audioOverride = ParticipantStore.audioConditionOverride
        let enrolled      = ParticipantStore.isEnrolled
        let studyMode     = UserDefaults.standard.object(forKey: studyModeKey)
        let schriftArt    = UserDefaults.standard.object(forKey: schriftArtKey)
        defer {
            ParticipantStore.conditionOverride = pedOverride
            ParticipantStore.audioConditionOverride = audioOverride
            ParticipantStore.isEnrolled = enrolled
            UserDefaults.standard.set(studyMode, forKey: studyModeKey)
            UserDefaults.standard.set(schriftArt, forKey: schriftArtKey)
        }
        body()
    }

    // MARK: - Identity (ParticipantStore.startNewParticipant)

    @Test("startNewParticipant generates a new UUID")
    func generatesNewUUID() {
        withRestoredState {
            let before = ParticipantStore.participantId
            let new = ParticipantStore.startNewParticipant()
            #expect(new != before)
            #expect(ParticipantStore.participantId == new, "new UUID must be persisted")
        }
    }

    @Test("startNewParticipant clears both arm overrides")
    func clearsBothOverrides() {
        withRestoredState {
            ParticipantStore.conditionOverride = .control
            ParticipantStore.audioConditionOverride = .silent
            _ = ParticipantStore.startNewParticipant()
            #expect(ParticipantStore.conditionOverride == nil)
            #expect(ParticipantStore.audioConditionOverride == nil)
        }
    }

    @Test("startNewParticipant re-enrols with a fresh enrolledAt = now")
    func reEnrolsWithFreshTimestamp() {
        withRestoredState {
            // Simulate a stale enrolment far in the past.
            ParticipantStore.isEnrolled = false
            ParticipantStore.isEnrolled = true            // stamps an enrolledAt
            // Make the stale stamp unmistakably old, so "not re-stamped"
            // cannot pass as "re-stamped within the same instant"
            // (audit 2026-09-04: `fresh >= old` and the optional guard
            // together could not fail).
            UserDefaults.standard.set(Date(timeIntervalSince1970: 1_000_000_000),
                                      forKey: "de.flamingistan.primae.thesisEnrolledAt")
            let old = ParticipantStore.enrolledAt
            #expect(old == Date(timeIntervalSince1970: 1_000_000_000), "precondition: stale stamp in place")
            let before = Date()
            _ = ParticipantStore.startNewParticipant()
            #expect(ParticipantStore.isEnrolled, "must remain enrolled")
            let fresh = ParticipantStore.enrolledAt
            #expect(fresh != nil, "a new participant must carry an enrolment instant")
            #expect((fresh ?? .distantPast) >= before.addingTimeInterval(-1),
                    "enrolledAt must be re-stamped to the reset instant, got \(String(describing: fresh))")
        }
    }

    @Test("startNewParticipant clears the retrieval counter")
    func clearsRetrievalCounter() {
        withRestoredState {
            UserDefaults.standard.set(7, forKey: retrievalKey)
            _ = ParticipantStore.startNewParticipant()
            #expect(UserDefaults.standard.object(forKey: retrievalKey) == nil)
        }
    }

    /// The string-level test above cannot catch the failure that matters.
    /// Both sides now read `RetrievalScheduler.counterKey`, so renaming it
    /// moves them together and stays green — correctly. What no
    /// string-comparison test can see is the reset clearing a DIFFERENT
    /// key than the scheduler actually uses, which is how a fresh
    /// enrollee silently inherits the previous child's cadence.
    ///
    /// So assert the behaviour instead of the string: drive the real
    /// scheduler, reset, and read a fresh scheduler back. This names no
    /// key at all, and goes red for any divergence however introduced.
    @Test("startNewParticipant clears the counter RetrievalScheduler actually uses")
    func clearsTheLiveRetrievalCounter() {
        withRestoredState {
            var progress = LetterProgress()
            progress.completionCount = 3          // clears minimumPriorCompletions
            let scheduler = RetrievalScheduler(initialCounter: 0)
            _ = scheduler.shouldPrompt(for: "A", progress: progress)
            #expect(scheduler.selectionsSinceRetrieval > 0,
                    "precondition: the scheduler must have persisted a non-zero cadence")

            _ = ParticipantStore.startNewParticipant()

            // A fresh scheduler re-reads UserDefaults. Still non-zero here
            // means the reset cleared a key nothing reads.
            let afterReset = RetrievalScheduler()
            #expect(afterReset.selectionsSinceRetrieval == 0,
                    "new participant inherited a cadence of \(afterReset.selectionsSinceRetrieval)")
        }
    }

    @Test("the new UUID re-derives BOTH arms, decorrelated")
    func newUUIDReDerivesBothArms() {
        withRestoredState {
            let new = ParticipantStore.startNewParticipant()   // sets enrolled=true, clears overrides
            // Enrolled + no override → defaultForInstall is the modulo arm.
            #expect(ThesisCondition.defaultForInstall == ThesisCondition.assign(participantId: new))
            #expect(PilotAudioCondition.defaultForInstall == PilotAudioCondition.assign(participantId: new))
            // The two axes key on independent UUID bytes (0 vs 15), so the
            // re-derivation is decorrelated — already proven in the
            // assignment suites; here we just confirm both move off the
            // same new UUID through defaultForInstall.
        }
    }

    @Test("device/parent config is preserved across a reset")
    func deviceConfigPreserved() {
        withRestoredState {
            UserDefaults.standard.set(true, forKey: studyModeKey)
            UserDefaults.standard.set("druckschrift", forKey: schriftArtKey)
            _ = ParticipantStore.startNewParticipant()
            #expect(UserDefaults.standard.bool(forKey: studyModeKey), "studyMode must survive")
            #expect(UserDefaults.standard.string(forKey: schriftArtKey) == "druckschrift",
                    "schriftArt must survive")
        }
    }

    // MARK: - Store wipe (TracingViewModel.resetForNewParticipant)

    @Test("resetForNewParticipant wipes the dashboard store and returns a new UUID")
    func vmResetWipesDataAndRegeneratesIdentity() {
        withRestoredState {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: tmp) }

            let store = JSONParentDashboardStore(fileURL: tmp)
            store.recordPhaseSession(letter: "A", phase: "guided", completed: true,
                                     score: 0.5, schedulerPriority: 0, condition: .threePhase)
            let vm = TracingViewModel(.stub.with(dashboardStore: store))
            #expect(!vm.dashboardSnapshot.phaseSessionRecords.isEmpty, "precondition: data present")

            ParticipantStore.conditionOverride = .control
            let before = ParticipantStore.participantId
            let newID = vm.resetForNewParticipant()

            #expect(vm.dashboardSnapshot.phaseSessionRecords.isEmpty, "records must be wiped")
            #expect(newID != before, "identity must regenerate")
            #expect(ParticipantStore.participantId == newID)
            #expect(ParticipantStore.conditionOverride == nil, "override must clear")
        }
    }

    // MARK: - Persistence across a reset (2026-09-14 data-loss fix)
    //
    // Drives the exact sequence David asked this be proven by: enrol,
    // record, enrol again, and confirm the first child's data is still
    // there and still attributable — not asserted from reading the
    // implementation, run against real JSON-backed stores on temp files/
    // directories, the same pattern `vmResetWipesDataAndRegeneratesIdentity`
    // above already uses to get real (not stubbed) recording behaviour.

    /// Fresh real dashboard store + real participant-archive directory,
    /// both on temp paths removed after the test.
    private func makeRealStores() -> (dashboard: JSONParentDashboardStore,
                                      archiveDir: URL) {
        let dashboardURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).json")
        let archiveDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-\(UUID().uuidString)", isDirectory: true)
        return (JSONParentDashboardStore(fileURL: dashboardURL), archiveDir)
    }

    @Test("resetForNewParticipant seals the outgoing participant before wiping, durably")
    func sealsOutgoingParticipantDurably() async {
        await withRestoredStateAsync {
            let (dashboard, archiveDir) = makeRealStores()
            defer { try? FileManager.default.removeItem(at: archiveDir) }
            let archive = JSONParticipantArchiveStore(directoryURL: archiveDir)

            dashboard.recordPhaseSession(letter: "F", phase: "freeWrite", completed: true,
                                         score: 0.73, schedulerPriority: 0, condition: .threePhase)
            let vm = TracingViewModel(.stub
                .with(dashboardStore: dashboard)
                .with(participantArchive: archive)
                .with(studyMode: true))
            let outgoingID = ParticipantStore.participantId

            _ = vm.resetForNewParticipant()
            await archive.flush()

            // Re-derive from a FRESH store instance pointed at the same
            // directory — proves the seal survived to disk, not just to
            // this one process's memory (the failure mode a relaunch, a
            // crash, or the app being quit before the combined export
            // runs would otherwise expose).
            let reopened = JSONParticipantArchiveStore(directoryURL: archiveDir)
            let sealed = reopened.archivedParticipants.first { $0.participantId == outgoingID }
            #expect(sealed != nil, "the outgoing participant must be durably archived")
            #expect(sealed?.snapshot.phaseSessionRecords.contains { $0.letter == "F" && $0.score == 0.73 } == true,
                    "the archived record must carry the outgoing child's actual row, not an empty snapshot")
        }
    }

    @Test("resetForNewParticipant re-derives the arms in place under studyMode — no relaunch needed")
    func reappliesIdentityWithoutRelaunch() {
        withRestoredState {
            let (dashboard, archiveDir) = makeRealStores()
            defer { try? FileManager.default.removeItem(at: archiveDir) }
            let archive = JSONParticipantArchiveStore(directoryURL: archiveDir)
            let vm = TracingViewModel(.stub
                .with(dashboardStore: dashboard)
                .with(participantArchive: archive)
                .with(studyMode: true))

            let newID = vm.resetForNewParticipant()

            #expect(vm.participantIdentityChanged == false,
                    "studyMode must clear the relaunch-required flag once the arms are re-derived")
            #expect(vm.audioCondition == PilotAudioCondition.assign(participantId: newID),
                    "the LIVE audioCondition must already reflect the NEW participant, with no relaunch")
            #expect(vm.trainedSubset == TrainedLetterSubset.assign(participantId: newID),
                    "the LIVE trainedSubset must already reflect the NEW participant, with no relaunch")
            #expect(vm.sessionBlockReason == nil,
                    "tracing must not be blocked after an in-place reapply")
        }
    }

    @Test("enrol, record, enrol again: the first child's data is still there and still attributable")
    func firstChildSurvivesASecondEnrolment() async {
        await withRestoredStateAsync {
            let (dashboard, archiveDir) = makeRealStores()
            defer { try? FileManager.default.removeItem(at: archiveDir) }
            let archive = JSONParticipantArchiveStore(directoryURL: archiveDir)
            let vm = TracingViewModel(.stub
                .with(dashboardStore: dashboard)
                .with(participantArchive: archive)
                .with(studyMode: true))

            // Child 1: enrol (fixture already enrolled via `.stub`'s
            // participantEnrolled pin), record a distinctive session.
            let child1 = ParticipantStore.participantId
            dashboard.recordPhaseSession(letter: "I", phase: "freeWrite", completed: true,
                                         score: 0.91, schedulerPriority: 0, condition: .threePhase)

            // Enrol child 2 — the destructive-in-the-old-design step.
            let child2 = vm.resetForNewParticipant()
            #expect(child2 != child1)
            dashboard.recordPhaseSession(letter: "L", phase: "freeWrite", completed: true,
                                         score: 0.42, schedulerPriority: 0, condition: .threePhase)
            await archive.flush()

            // Child 1's row must still exist, attributed to child1's id —
            // not merged into child2's live snapshot, not gone.
            let sources = vm.allParticipantExportSources
            #expect(sources.count == 2, "both children must be present in one export pass")

            let child1Export = sources.first { $0.participantId == child1 }
            #expect(child1Export != nil, "child 1 must still be exportable after child 2 enrolled")
            #expect(child1Export?.snapshot.phaseSessionRecords.contains { $0.letter == "I" && $0.score == 0.91 } == true,
                    "child 1's actual row must survive, not just their id")
            #expect(child1Export?.snapshot.phaseSessionRecords.contains { $0.letter == "L" } == false,
                    "child 2's row must NOT bleed into child 1's attributed record")

            let child2Export = sources.first { $0.participantId == child2 }
            #expect(child2Export != nil)
            #expect(child2Export?.snapshot.phaseSessionRecords.contains { $0.letter == "L" && $0.score == 0.42 } == true,
                    "child 2's row must be attributed to child 2")
            #expect(child2Export?.snapshot.phaseSessionRecords.contains { $0.letter == "I" } == false,
                    "child 1's row must NOT bleed into child 2's attributed record")

            // And the combined export actually produces one file
            // covering both — not two files the proctor has to remember
            // to send separately.
            let combined = ParentDashboardExporter.combinedDelimitedData(participants: sources, separator: ",")
            let combinedText = String(data: combined, encoding: .utf8) ?? ""
            #expect(combinedText.contains(child1.uuidString))
            #expect(combinedText.contains(child2.uuidString))
        }
    }

    /// A participant who did NOTHING must not be sealed — the phantom-N
    /// defect (2026-10-01, F1 in docs/AUDIT_2026-10-01.md).
    ///
    /// WHY THIS IS NOT A NICETY. `allParticipantExportSources` emits every
    /// sealed archive, and the combined export writes each one as a complete
    /// block with a valid `# participantId=` header and its full column set.
    /// An archive with no rows is indistinguishable in the output file from a
    /// child who was enrolled and did nothing — which is exactly the
    /// population an N derived from that file is supposed to exclude. Nothing
    /// errors; the file is well-formed; the only symptom is a denominator that
    /// is too large, in every per-arm breakdown derived from it.
    ///
    /// MEASURED on the study iPad rather than reasoned: 43 sealed archives,
    /// 25 of them carrying zero phase rows (18 with real data). So the
    /// "proctor taps Neuer Teilnehmer twice" path is the COMMON case in a
    /// multi-child session, not the rare edge case it reads like.
    ///
    /// Driven through two consecutive resets with nothing recorded between
    /// them — the shape that produces the phantom — rather than one reset on a
    /// fresh install, so the test would still fail if the guard were widened
    /// to seal only when some OTHER store (progress, traces) had content.
    @Test("a participant who recorded nothing is not sealed — an empty archive would inflate the analysed N")
    func emptyParticipantIsNotSealed() async {
        await withRestoredStateAsync {
            let (dashboard, archiveDir) = makeRealStores()
            defer { try? FileManager.default.removeItem(at: archiveDir) }
            let archive = JSONParticipantArchiveStore(directoryURL: archiveDir)
            let vm = TracingViewModel(.stub
                .with(dashboardStore: dashboard)
                .with(participantArchive: archive)
                .with(studyMode: true))

            // Child 1 does real work, so it MUST be sealed — this is the
            // control that stops the guard from over-reaching into "never seal
            // anyone", which would reintroduce the 2026-09-14 data-loss defect.
            let child1 = ParticipantStore.participantId
            dashboard.recordPhaseSession(letter: "A", phase: "freeWrite", completed: true,
                                         score: 0.8, schedulerPriority: 0, condition: .threePhase)
            _ = vm.resetForNewParticipant()

            // Child 2 is enrolled and immediately superseded WITHOUT recording
            // anything — the phantom-producing sequence.
            let child2 = vm.resetForNewParticipant()
            await archive.flush()

            let sealed = archive.archivedParticipants
            #expect(sealed.contains { $0.participantId == child1 },
                    "the child that DID work must still be sealed — losing this is the 2026-09-14 data-loss defect returning")
            #expect(sealed.contains { $0.snapshot.phaseSessionRecords.contains { $0.letter == "A" } },
                    "the sealed record must carry that child's actual row, not an empty snapshot")
            #expect(!sealed.contains { $0.participantId == child2 },
                    "the child that recorded nothing must NOT be sealed: an empty archive exports as a full block with a valid participantId header and zero rows, inflating N and every per-arm denominator")

            // The property the export's N actually rests on. Scoped to the
            // ARCHIVED participants deliberately: the CURRENT participant is
            // appended unconditionally by `allParticipantExportSources`,
            // and legitimately has no rows yet — they are mid-session. That
            // is not a phantom; it is the child currently being tested. Only
            // the sealed set accumulates across the whole sitting, so only
            // the sealed set is the population a denominator must count.
            let archived = vm.allParticipantExportSources.dropLast()
            #expect(!archived.isEmpty)
            #expect(archived.allSatisfy { !$0.snapshot.phaseSessionRecords.isEmpty },
                    "every ARCHIVED export source must carry rows; an archived child who did nothing must not exist")
        }
    }

    /// THE COLD-START PATH — the one the suite never had.
    ///
    /// A study iPad is launched with no participant, so `sessionBlockReason`
    /// is non-nil and `SchuleWorldView` renders "Studie kann nicht
    /// starten". The proctor then enrols child #1 — and the gate MUST
    /// clear, or the device is unusable and the proctor is stuck on the
    /// screen that told them what to do. Found on the physical iPad
    /// 2026-10-02: enrolling succeeded (the UUID and `thesisEnrolled`
    /// were written) and the screen stayed, because the VM's
    /// `participantEnrolled` was a `let` captured at init, so
    /// `studyPreconditionFailure` kept reading the launch-time value.
    ///
    /// Every other test in this file builds its VM from `.stub`, which
    /// pins `participantEnrolled: true` — so this transition had no
    /// fixture and no coverage anywhere in the suite, and
    /// `reappliesIdentityWithoutRelaunch` passed throughout because it
    /// never started un-enrolled.
    @Test("enrolling from a cold, un-enrolled device clears the start-gate")
    func enrollingFromColdDeviceClearsTheStartGate() {
        withRestoredState {
            let (dashboard, archiveDir) = makeRealStores()
            defer { try? FileManager.default.removeItem(at: archiveDir) }
            let archive = JSONParticipantArchiveStore(directoryURL: archiveDir)

            // The device as it is the moment a proctor first opens it.
            let vm = TracingViewModel(.stub
                .with(dashboardStore: dashboard)
                .with(participantArchive: archive)
                .with(participantEnrolled: false)
                .with(studyMode: true))

            #expect(vm.sessionBlockReason != nil,
                    "an un-enrolled study device must refuse to start — this is the gate itself")
            #expect(vm.sessionBlockReason?.contains("Kein Teilnehmer eingeschrieben") == true,
                    "and it must say WHY, in the proctor's language")

            vm.resetForNewParticipant()

            #expect(vm.participantEnrolled,
                    "the VM must learn it is enrolled; a value frozen at init can never clear the gate")
            #expect(vm.sessionBlockReason == nil,
                    "after enrolling child #1 the study must be startable — the proctor did exactly what the screen said")
        }
    }

    /// The same transition, seen from the store rather than the VM: the
    /// claim under test is that the DEVICE is enrolled afterwards, not
    /// merely that a cached flag was flipped.
    @Test("enrolling from a cold device actually persists the enrolment")
    func enrollingFromColdDevicePersistsEnrolment() {
        withRestoredState {
            ParticipantStore.isEnrolled = false
            let (dashboard, archiveDir) = makeRealStores()
            defer { try? FileManager.default.removeItem(at: archiveDir) }
            let vm = TracingViewModel(.stub
                .with(dashboardStore: dashboard)
                .with(participantArchive: JSONParticipantArchiveStore(directoryURL: archiveDir))
                .with(participantEnrolled: false)
                .with(studyMode: true))

            let newID = vm.resetForNewParticipant()

            #expect(ParticipantStore.isEnrolled,
                    "the enrolment must reach ParticipantStore, or the next launch blocks again")
            #expect(ParticipantStore.participantId == newID)
        }
    }

    /// Async counterpart of `withRestoredState` for tests that need to
    /// `await` a store flush mid-body.
    private func withRestoredStateAsync(_ body: () async -> Void) async {
        let pedOverride   = ParticipantStore.conditionOverride
        let audioOverride = ParticipantStore.audioConditionOverride
        let enrolled      = ParticipantStore.isEnrolled
        let studyMode     = UserDefaults.standard.object(forKey: studyModeKey)
        let schriftArt    = UserDefaults.standard.object(forKey: schriftArtKey)
        defer {
            ParticipantStore.conditionOverride = pedOverride
            ParticipantStore.audioConditionOverride = audioOverride
            ParticipantStore.isEnrolled = enrolled
            UserDefaults.standard.set(studyMode, forKey: studyModeKey)
            UserDefaults.standard.set(schriftArt, forKey: schriftArtKey)
        }
        await body()
    }
}
