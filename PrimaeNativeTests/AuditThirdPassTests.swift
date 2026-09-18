// Third-pass audit (2026-09-04/05): regression pins for the class one/two
// defects found in the Tracing surface and the participant handling.
// Each test names the defect it would have caught.

import Testing
import Foundation
import CoreGraphics
@testable import PrimaeNative

fileprivate final class ThirdPassRecordingStore: ParentDashboardStoring {
    var snapshot: DashboardSnapshot { DashboardSnapshot() }
    private(set) var sessionCalls: [(letter: String, duration: TimeInterval)] = []
    private(set) var phaseCalls: [(letter: String, phase: String, completed: Bool, score: Double,
                                   trainedSubset: String?, phaseDurationSeconds: Double?,
                                   spatialDeviation: Double?, rawTraceID: UUID?, studyMode: Bool?, probe: String?)] = []
    func recordSession(letter: String, accuracy: Double,
                       durationSeconds: TimeInterval,
                       wallClockSeconds: TimeInterval?,
                       date: Date, condition: ThesisCondition,
                       inputDevice: String?) {
        sessionCalls.append((letter, durationSeconds))
    }
    func recordPhaseSession(letter: String, phase: String, completed: Bool, score: Double, schedulerPriority: Double, condition: ThesisCondition, audioCondition: PilotAudioCondition, assessment: WritingAssessment?, recognition: RecognitionSample?, inputDevice: String?, rawTraceID: UUID?, trainedSubset: String?, phaseDurationSeconds: Double?, frechetDistance: Double?, checkpointCoverage: Double?, spatialDeviation: Double?, strokeCount: Int?, strokeOrder: String?, reversedStrokeCount: Int?, studyMode: Bool?, probe: String?, comparisonConfiguration: String?) {
        phaseCalls.append((letter, phase, completed, score, trainedSubset, phaseDurationSeconds,
                           spatialDeviation, rawTraceID, studyMode, probe))
    }
    func reset() {}
}

@Suite(.serialized) @MainActor struct AuditThirdPassTests {

    private let canvas = CGSize(width: 400, height: 400)

    private func studyVM(store: ThirdPassRecordingStore? = nil) -> TracingViewModel {
        var deps = TracingDependencies.stub
        deps.studyMode = true
        if let store { deps.dashboardStore = store }
        return TracingViewModel(deps)
    }

    private func inkStroke(_ vm: TracingViewModel, from x0: CGFloat, y: CGFloat, count: Int, t: inout CFTimeInterval) {
        vm.beginTouch(at: CGPoint(x: x0, y: y), t: t)
        var p = CGPoint(x: x0, y: y)
        for _ in 0..<count { t += 0.01; p.x += 10; vm.updateTouch(at: p, t: t, canvasSize: canvas) }
    }

    // MARK: - Observe phase (T1 / T2)

    @Test("the FIRST letter of a session leaves observe after two animation cycles without a tap")
    func firstLetterObserveAutoAdvances() {
        let vm = studyVM()
        vm.canvasSize = canvas
        #expect(vm.learningPhase == .observe, "precondition: a study session starts in observe")
        // A study launch is PARKED (2026-09-06): nothing is installed
        // until the observe pill starts the letter. Then the
        // auto-advance must be there — it used to be left nil on the
        // first letter, and studyMode makes the skip tap inert.
        #expect(vm.launchParked && vm.animation.onCycleComplete == nil,
                "a parked launch installs no auto-advance")
        vm.startParkedLetter()
        #expect(vm.animation.onCycleComplete != nil,
                "starting the parked letter must install the auto-advance")
        // ONE pass ends observe (2026-09-17). The letter is demonstrated
        // once rather than twice, on the supervisor's review note ("einmal
        // vorzeigen (vielleicht etwas langsamer)"); the single pass runs
        // at `AnimationSpeed.slow` so the observe window keeps roughly
        // its former length. This assertion used to be the opposite —
        // "one cycle is not enough" — and the pair below it asserted that
        // two cycles end observe.
        vm.animation.onCycleComplete?()
        #expect(vm.learningPhase != .observe,
                "one full pass must end observe; got \(vm.learningPhase)")
    }

    @Test("a fresh observe exits on its own pass, whatever ran before it")
    func observeCycleCountResetsPerLetter() {
        let vm = studyVM()
        vm.canvasSize = canvas
        vm.phaseController.resume(at: .guided)
        // Cycles fired while NOT in observe must not leave a later observe
        // in a state it cannot leave. The failure mode this guarded has
        // changed shape with one pass per observe (2026-09-17): a stale
        // count can no longer cut observe short, because one cycle IS the
        // target now. What is still worth pinning is that a fresh observe
        // ends on its own pass — the phase gate in the handler is what
        // makes that true, and it is the part that would silently break
        // if the counter were trusted without it. (The guided phase no
        // longer drives the animator at all; these calls are direct.)
        for _ in 0..<3 { vm.animation.onCycleComplete?() }
        vm.loadLetter(name: vm.currentLetterName)
        #expect(vm.learningPhase == .observe, "precondition: reload starts in observe")
        vm.animation.onCycleComplete?()
        #expect(vm.learningPhase != .observe,
                "one pass ends observe regardless of what ran before it")
    }

    // MARK: - FreeWrite recording (T9 / T3)

    @Test("the pen-down sample is the first point of every freeWrite stroke")
    func penDownSampleIsRecorded() {
        let vm = studyVM()
        vm.canvasSize = canvas
        vm.phaseController.resume(at: .freeWrite)
        var t: CFTimeInterval = 1000
        vm.beginTouch(at: CGPoint(x: 50, y: 200), t: t)
        #expect(vm.freeWritePoints.count == 1, "pen-down must be recorded before any movement")
        #expect(vm.freeWritePoints.first == CGPoint(x: 50, y: 200))
        #expect(vm.freeWriteTimestamps.first == t)
        for _ in 0..<5 { t += 0.01; vm.updateTouch(at: CGPoint(x: 50 + CGFloat(vm.freeWritePoints.count) * 10, y: 200), t: t, canvasSize: canvas) }
        vm.endTouch()
        #expect(vm.freeWritePoints.count == 6)
        // Second stroke: its boundary sits exactly at the first stroke's length.
        t += 0.5
        vm.beginTouch(at: CGPoint(x: 50, y: 300), t: t)
        #expect(vm.freeWriteStrokeStartIndices == [6], "got \(vm.freeWriteStrokeStartIndices)")
        #expect(vm.freeWritePoints.count == 7)
        vm.endTouch()
    }

    @Test("an out-of-bounds excursion in freeWrite ends the stroke, keeps what was drawn, and gives no retry cue")
    func freeWriteExcursionSplitsStroke() {
        let vm = studyVM()
        vm.canvasSize = canvas
        vm.phaseController.resume(at: .freeWrite)
        var t: CFTimeInterval = 1000
        inkStroke(vm, from: 50, y: 200, count: 5, t: &t)
        let before = vm.freeWritePoints.count
        #expect(before == 6)
        t += 0.01; vm.updateTouch(at: CGPoint(x: -20, y: 200), t: t, canvasSize: canvas)   // leaves the canvas
        #expect(vm.freeWritePoints.count == before, "nothing is recorded outside the canvas, and nothing is erased")
        #expect(vm.toastMessage == nil, "free production gives no retry cue")
        t += 0.01; vm.updateTouch(at: CGPoint(x: 30, y: 210), t: t, canvasSize: canvas)    // re-enters
        t += 0.01; vm.updateTouch(at: CGPoint(x: 45, y: 215), t: t, canvasSize: canvas)
        #expect(vm.freeWriteStrokeStartIndices == [before],
                "the re-entry must start a new stroke, not fuse with the aborted one: \(vm.freeWriteStrokeStartIndices)")
        #expect(vm.freeWritePoints.count == before + 2)
        vm.endTouch()
    }

    // MARK: - Backgrounding with the finger down (T10)

    @Test("backgrounding mid-stroke records the finished production instead of leaving it to a task that may never run")
    func backgroundWithFingerDownRecordsTheTrial() async {
        let store = ThirdPassRecordingStore()
        let vm = studyVM(store: store)
        vm.canvasSize = canvas
        vm.phaseController.resume(at: .freeWrite)
        var t: CFTimeInterval = 1000
        inkStroke(vm, from: 50, y: 200, count: 15, t: &t)   // finger still down
        await vm.appDidEnterBackground()
        let fw = store.phaseCalls.first { $0.phase == LearningPhase.freeWrite.rawName }
        #expect(fw != nil, "the production must be recorded before the app is suspended")
        #expect(fw?.completed == true)
        #expect(fw?.spatialDeviation != nil, "and scored")
    }

    // MARK: - Participant identity (V1 / V2)

    @Test("after a participant reset under studyMode the VM re-derives the arms in place and does NOT require a relaunch")
    func resetReappliesArmsInPlaceUnderStudyMode() {
        // Was "...refuses to trace until relaunch" until 2026-09-14: a
        // kindergarten pilot with one proctor and one iPad enrolling
        // several children in one sitting cannot absorb a force-quit
        // between every child, so `resetForNewParticipant` now re-derives
        // the arms in place instead of requiring one (see
        // `reapplyParticipantIdentity`). This test used to prove the OLD
        // (now-removed) block; it now proves the block is genuinely
        // lifted, not just that the flag was never set.
        let vm = studyVM()
        vm.canvasSize = canvas
        vm.phaseController.resume(at: .guided)
        #expect(vm.sessionBlockReason == nil, "precondition: the fixture can trace")
        let prevID = ParticipantStore.participantId
        defer { UserDefaults.standard.set(prevID.uuidString, forKey: "de.flamingistan.primae.participantId") }
        let newID = vm.resetForNewParticipant()
        #expect(newID != prevID)
        #expect(vm.sessionBlockReason == nil,
                "a studyMode reset must not leave tracing blocked — the arms are re-derived synchronously, not on next launch")
        #expect(!vm.participantIdentityChanged)
        #expect(vm.audioCondition == PilotAudioCondition.assign(participantId: newID),
                "the LIVE audioCondition must already be the NEW participant's, with no relaunch")
        #expect(vm.trainedSubset == TrainedLetterSubset.assign(participantId: newID),
                "the LIVE trainedSubset must already be the NEW participant's, with no relaunch")
        // Positive control: a probe under the NEW arms is actually
        // reachable, not just flag-permitted. "A" is the fixture's only
        // letter and is a study letter for every possible trainedSubset,
        // so this is deterministic regardless of which subset the new
        // random participant id happened to draw.
        vm.startColdProbe(letter: "A", kind: .pretest)
        #expect(vm.currentProbe == .pretest, "a cold probe must actually start under the newly-applied arms")
    }

    @Test("a reset leaves no stale outgoing-phase state behind, even when the new participant's trainedSubset excludes the fixture's only letter")
    func resetClearsPhaseStateEvenWithoutAFirstLetterLoad() {
        // Found by CI (2026-09-14), not designed in: `resetForNewParticipant`
        // reset the data stores correctly but left `phaseController` (and
        // `progress`/`directTappedDots`) untouched UNLESS
        // `loadFirstTrainedLetter` found a letter to load — and it silently
        // finds none whenever the new participant's random trainedSubset
        // happens not to include "A", the fixture's only letter (4 of the
        // 10 possible 3-of-5 subsets: FIL, FIM, FLM, ILM). When that
        // happened, the OUTGOING child's stale `.freeWrite` phase state
        // survived, and the very next ordinary letter load for the
        // INCOMING child — now correctly unblocked — read that stale state
        // as an abandoned trial and wrote a phantom row for it.
        //
        // `resetForNewParticipant`'s new UUID is genuinely random, so this
        // retries until it draws a subset that excludes "A" — overwhelmingly
        // likely (~40% per draw) within a handful of attempts, and this is
        // what makes the test exercise the actual edge case deterministically
        // rather than ~60% of the time by luck.
        let store = ThirdPassRecordingStore()
        var vm = studyVM(store: store)
        vm.canvasSize = canvas
        let prevID = ParticipantStore.participantId
        defer { UserDefaults.standard.set(prevID.uuidString, forKey: "de.flamingistan.primae.participantId") }

        var hitTheEdgeCase = false
        for _ in 0..<40 {
            vm = studyVM(store: store)
            vm.canvasSize = canvas
            vm.phaseController.resume(at: .freeWrite)
            var t: CFTimeInterval = 1000
            inkStroke(vm, from: 50, y: 200, count: 15, t: &t)
            let newID = vm.resetForNewParticipant()
            guard !TrainedLetterSubset.assign(participantId: newID).letters.contains("A") else { continue }
            hitTheEdgeCase = true
            #expect(vm.phaseController.currentPhase == .observe,
                    "the phase controller must be reset even when no letter load followed")
            #expect(vm.progress == 0)
            #expect(vm.directTappedDots.isEmpty)
            vm.loadLetter(name: vm.currentLetterName)   // what the next probe/letter would do
            #expect(store.phaseCalls.isEmpty,
                    "no phantom row may be written for the outgoing child's stale phase state: \(store.phaseCalls.count)")
            break
        }
        #expect(hitTheEdgeCase, "the retry loop must have drawn a trainedSubset excluding \"A\" at least once in 40 tries")
    }

    @Test("restoring the id this device already carries keeps the original enrolment instant")
    func restoreSameParticipantKeepsEnrolledAt() {
        let prevID = ParticipantStore.participantId
        let prevEnrolled = ParticipantStore.isEnrolled
        let prevStamp = UserDefaults.standard.object(forKey: "de.flamingistan.primae.thesisEnrolledAt")
        defer {
            UserDefaults.standard.set(prevID.uuidString, forKey: "de.flamingistan.primae.participantId")
            ParticipantStore.isEnrolled = prevEnrolled
            UserDefaults.standard.set(prevStamp, forKey: "de.flamingistan.primae.thesisEnrolledAt")
        }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: "de.flamingistan.primae.participantId")
        let original = Date(timeIntervalSince1970: 1_700_000_000)
        UserDefaults.standard.set(original, forKey: "de.flamingistan.primae.thesisEnrolledAt")
        _ = ParticipantStore.restoreParticipant(uuidString: id.uuidString)
        #expect(ParticipantStore.enrolledAt == original,
                "same child, same device: existing rows must stay inside the export window")
        // A DIFFERENT id re-stamps, so another child's rows stay out.
        _ = ParticipantStore.restoreParticipant(uuidString: UUID().uuidString)
        #expect((ParticipantStore.enrolledAt ?? .distantPast) > original)
    }

    // MARK: - Export filename (V3)

    @Test("two exports on one day for two participants do not collide")
    func exportFilenamesAreUniquePerParticipant() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        let prevID = ParticipantStore.participantId
        defer { UserDefaults.standard.set(prevID.uuidString, forKey: "de.flamingistan.primae.participantId") }
        let a = try ParentDashboardExporter.exportFileURL(from: DashboardSnapshot(), format: .csv, tempDirectory: tmp)
        UserDefaults.standard.set(UUID().uuidString, forKey: "de.flamingistan.primae.participantId")
        let b = try ParentDashboardExporter.exportFileURL(from: DashboardSnapshot(), format: .csv, tempDirectory: tmp)
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        #expect(a.lastPathComponent != b.lastPathComponent, "\(a.lastPathComponent) vs \(b.lastPathComponent)")
        #expect(a.lastPathComponent.contains(String(prevID.uuidString.prefix(8))))
    }

    // MARK: - Ink width against the renderer's formula (V8)

    @Test("live ink width follows the renderer's pressure formula")
    func inkWidthFormula() {
        #expect(InkStyle.width(forPressure: nil) == 14, "finger")
        #expect(InkStyle.width(forPressure: 0) == 8, "pencil, no pressure")
        #expect(InkStyle.width(forPressure: 1) == 22, "pencil, full pressure")
    }

    // MARK: - Retrieval prompt cannot fire in a study session (C1-3, 2026-09-05)

    @Test("the spaced-retrieval prompt is unreachable in a study session even when the parent toggle is on")
    func retrievalPromptUnreachableUnderStudy() {
        var deps = TracingDependencies.stub
        deps.studyMode = true
        deps.enableRetrievalPrompts = true
        let vm = TracingViewModel(deps)
        vm.canvasSize = canvas
        #expect(vm.enableRetrievalPrompts, "precondition: the toggle is on")
        vm.loadRecommendedLetter()   // the only enqueue site sits behind the studyMode early return
        var sawPrompt = false
        if case .retrievalPrompt = vm.overlayQueue.currentOverlay { sawPrompt = true }
        #expect(!sawPrompt && vm.overlayQueue.pendingCount == 0,
                "no retrieval prompt may be queued in a study session; current=\(String(describing: vm.overlayQueue.currentOverlay)) pending=\(vm.overlayQueue.pendingCount)")
    }

    // MARK: - Spatial arm precondition (C1-6, 2026-09-05)

    @Test("the spatial carrier resolves in the bundle and the spatial arm passes the session precondition")
    func spatialCarrierIsASessionPrecondition() {
        #expect(SpatialSonification.carrierToneURL() != nil,
                "the carrier must resolve by the engine's own lookups: \(SpatialSonification.carrierToneFile)")
        var deps = TracingDependencies.stub
        deps.studyMode = true
        deps.audioCondition = .spatial
        let vm = TracingViewModel(deps)
        #expect(vm.studyPreconditionFailure == nil, "\(String(describing: vm.studyPreconditionFailure))")
    }

    // MARK: - Review 2026-09-05: linkage of the freeWrite row to its trace

    @Test("a scored production accepts no more ink while the recognizer runs")
    func scoredProductionRefusesInk() async {
        let store = ThirdPassRecordingStore()
        let traces = StubRawTraceStore()
        let vm = studyVM(store: store)
        vm.canvasSize = canvas
        vm.phaseController.resume(at: .freeWrite)
        var t: CFTimeInterval = 1000
        inkStroke(vm, from: 50, y: 200, count: 15, t: &t)
        vm.endTouch()
        let inkBefore = vm.freeWritePoints.count
        vm.advanceLearningPhase()   // what the quiet window calls: latches the measures, starts the recognizer
        #expect(vm.didCompleteCurrentLetter, "the production is closed the moment it is scored")
        t += 0.5
        inkStroke(vm, from: 50, y: 300, count: 5, t: &t)   // the child touches again during the await
        vm.endTouch()
        #expect(vm.freeWritePoints.count == inkBefore,
                "no ink may enter the buffer the later capture reads; got \(vm.freeWritePoints.count) vs \(inkBefore)")
        _ = traces
    }

    @Test("a pencil move or lift during a finger session is ignored, and vice versa")
    func touchSessionIsPinnedToItsDevice() {
        let vm = studyVM()
        vm.canvasSize = canvas
        vm.phaseController.resume(at: .freeWrite)
        var t: CFTimeInterval = 1000
        vm.fingerDidTouchDown()
        vm.beginTouch(at: CGPoint(x: 50, y: 200), t: t)
        t += 0.01; vm.updateTouch(at: CGPoint(x: 60, y: 200), t: t, canvasSize: canvas)
        let before = vm.freeWritePoints.count
        // A Pencil move arrives (the pencil overlay stamps pressure first).
        vm.pencilPressure = 0.6
        t += 0.01; vm.updateTouch(at: CGPoint(x: 300, y: 50), t: t, canvasSize: canvas)
        #expect(vm.freeWritePoints.count == before, "the pencil's point must not join the finger's stroke")
        #expect(vm.pencilPressure == nil, "the stray pencil stamp is cleared")
        // The Pencil lifts: the finger's session must survive it.
        vm.endTouch(fromPencil: true)
        t += 0.01; vm.updateTouch(at: CGPoint(x: 70, y: 200), t: t, canvasSize: canvas)
        #expect(vm.freeWritePoints.count == before + 1, "the finger is still drawing after the pencil lifted")
        vm.endTouch(fromPencil: false)
        #expect(vm.freeWriteStrokeStartIndices.isEmpty, "one stroke, no boundary from the ignored events")
    }

    @Test("a one-sample contact is not a finished production")
    func singleSampleContactDoesNotComplete() async {
        let store = ThirdPassRecordingStore()
        let vm = studyVM(store: store)
        vm.canvasSize = canvas
        vm.phaseController.resume(at: .freeWrite)
        vm.beginTouch(at: CGPoint(x: 50, y: 200), t: 1000)   // a palm: one sample, no movement
        vm.endTouch()
        #expect(vm.freeWritePoints.count == 1)
        try? await Task.sleep(for: .seconds(2.5))   // past the quiet window
        #expect(store.phaseCalls.isEmpty, "a palm contact must not produce a completed freeWrite row")
        // The unload/background path agrees.
        vm.loadLetter(name: vm.currentLetterName)
        #expect(!store.phaseCalls.contains { $0.phase == LearningPhase.freeWrite.rawName && $0.completed },
                "still not a completed production on unload")
    }

    @Test("a participant reset closes the outgoing trial: nothing of it is written under the new id")
    func resetClosesTheOutgoingTrial() {
        let store = ThirdPassRecordingStore()
        let vm = studyVM(store: store)
        vm.canvasSize = canvas
        vm.phaseController.resume(at: .freeWrite)
        var t: CFTimeInterval = 1000
        inkStroke(vm, from: 50, y: 200, count: 15, t: &t)
        vm.endTouch()   // ink on the canvas, quiet window pending
        let prevID = ParticipantStore.participantId
        defer { UserDefaults.standard.set(prevID.uuidString, forKey: "de.flamingistan.primae.participantId") }
        _ = vm.resetForNewParticipant()
        #expect(vm.freeWritePoints.isEmpty, "the outgoing child's ink is discarded")
        vm.loadLetter(name: vm.currentLetterName)   // what the next probe/letter would do
        #expect(store.phaseCalls.isEmpty, "no row may be written for the outgoing child after the reset: \(store.phaseCalls.count)")
    }

    @Test("a blocked session refuses cold probes too")
    func blockedSessionRefusesProbes() {
        // `resetForNewParticipant` no longer leaves a studyMode session
        // blocked (2026-09-14 — see `resetReappliesArmsInPlaceUnderStudyMode`
        // above), so this test now exercises the ONE path that still
        // genuinely blocks: "Teilnehmer wiederherstellen" (the delayed
        // retest restore), which is deliberately UNCHANGED — a real
        // relaunch is still required there, and `startColdProbe`'s
        // `participantIdentityChanged` guard must still refuse in that
        // state, silently or not (see the dead-button investigation).
        let vm = studyVM()
        vm.canvasSize = canvas
        let phaseBefore = vm.learningPhase
        vm.markParticipantRestored()
        #expect(vm.sessionBlockReason != nil, "precondition: a restore genuinely blocks the session")
        vm.startColdProbe(letter: "A", kind: .pretest)
        #expect(vm.currentProbe == nil && vm.learningPhase == phaseBefore,
                "a probe must not start while the arms in memory are stale")
    }

    @Test("schedulerPriority belongs to the scheduler's pick, not to the next letter loaded by hand")
    func schedulerPriorityDoesNotLeak() {
        var deps = TracingDependencies.stub
        deps.studyMode = false
        let vm = TracingViewModel(deps)
        vm.canvasSize = canvas
        vm.lastScheduledLetterPriority = 0.7   // as loadRecommendedLetter would leave it
        vm.loadLetter(name: vm.currentLetterName)
        #expect(vm.lastScheduledLetterPriority == 0, "a hand-loaded letter carries no scheduler priority")
    }

    @Test("two stroke boundaries at one index collapse to one")
    func duplicateStrokeBoundaryIsDropped() {
        let r = FreeWritePhaseRecorder()
        r.startSession(now: 100)
        r.record(point: CGPoint(x: 1, y: 1), timestamp: 100, force: 0, canvasSize: canvas)
        r.beginStroke(); r.beginStroke()
        #expect(r.strokeStartIndices == [1], "got \(r.strokeStartIndices)")
    }

    // MARK: - Review 2026-09-05: duration rows

    @Test("duration rows carry the arm, the study flag and the probe, and are filtered on enrolment like the phase rows")
    func durationRowsAreStampedAndFiltered() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("dur-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = JSONParentDashboardStore(fileURL: tmp)
        let enrolled = Date(timeIntervalSince1970: 1_770_000_000)
        store.recordSession(letter: "A", accuracy: 0.5, durationSeconds: 30, wallClockSeconds: 31,
                            date: enrolled.addingTimeInterval(-3600), condition: .threePhase, inputDevice: "finger",
                            audioCondition: .spatial, studyMode: true, probe: nil)          // before enrolment
        store.recordSession(letter: "A", accuracy: 0.5, durationSeconds: 40, wallClockSeconds: 41,
                            date: enrolled.addingTimeInterval(60), condition: .threePhase, inputDevice: "pencil",
                            audioCondition: .phoneme, studyMode: true, probe: "delayed")   // after
        let last = try #require(store.snapshot.sessionDurations.last)
        #expect(last.audioCondition == .phoneme && last.studyMode == true && last.probe == "delayed")
        let csv = String(data: ParentDashboardExporter.csvData(from: store.snapshot, progress: [:], enrolledAt: enrolled), encoding: .utf8)!
        let lines = csv.components(separatedBy: "\n")
        let header = try #require(lines.first { $0.hasPrefix("date,recordedAt,durationSeconds") })
        #expect(header.hasSuffix(",letter,audioCondition,studyMode,probe"), "\(header)")
        let rows = lines.filter { $0.hasPrefix("20") && $0.contains(",threePhase,") && $0.contains(",A,") }
        #expect(rows.count == 1, "the pre-enrolment duration must be filtered out: \(rows)")
        #expect(rows.first?.hasSuffix(",pencil,A,phoneme,true,delayed") == true, "\(String(describing: rows.first))")
    }

    // MARK: - Class two (2026-09-05): the model has no umlaut class

    @Test("a predicted base letter counts as correct for its umlaut, case-insensitively; a different letter does not")
    func recogniserMatchFoldsDiacritics() {
        #expect(LetterMatch.matches(predicted: "A", expected: "Ä"))
        #expect(LetterMatch.matches(predicted: "o", expected: "Ö"))
        #expect(LetterMatch.matches(predicted: "u", expected: "ü"))
        #expect(LetterMatch.matches(predicted: "a", expected: "A"))
        #expect(LetterMatch.matches(predicted: "ß", expected: "ß"))
        #expect(!LetterMatch.matches(predicted: "B", expected: "A"))
        #expect(!LetterMatch.matches(predicted: "s", expected: "ß"), "ß is its own class")
    }

    @Test("an unenrolled study device refuses to start a session")
    func unenrolledStudyDeviceRefuses() {
        var deps = TracingDependencies.stub
        deps.studyMode = true
        deps.participantEnrolled = false
        let vm = TracingViewModel(deps)
        #expect(vm.studyPreconditionFailure?.contains("Neuer Teilnehmer") == true,
                "the arms are un-randomised defaults until enrolment: \(String(describing: vm.studyPreconditionFailure))")
        deps.participantEnrolled = true
        #expect(TracingViewModel(deps).studyPreconditionFailure == nil)
    }

}
