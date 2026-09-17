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
