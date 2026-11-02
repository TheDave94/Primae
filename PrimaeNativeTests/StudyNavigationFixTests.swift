// Study navigation and set-end fixes (fix lane L2, 2026-11-02): FIXPLAN
// A8-A11. Pins, each mutation-checked on the physical iPad:
//   A8  VERIFY H9   no cold probe with no child enrolled
//   A9  STATE-4     the chevron after a probe goes to the first unfinished
//                   trained letter
//       VERIFY-10   a relaunch mid-set parks on the first unfinished letter
//                   (real bundle repository; RED on the iPad before the fix,
//                   settle lane 2026-11-02)
//   A10 STATE-5     study chevrons do not wrap at either end of the set
//   A11 STATE-6     letterRepeatCount > 1 celebrates the set once, after the
//                   last pass
// None of these writes the process-wide participant identity: `stub` pins
// enrolment in the dependencies.

import Testing
import Foundation
import CoreGraphics
import QuartzCore
@testable import PrimaeNative

/// Five study letters cloned from the stub fixture's "A" geometry, each with
/// a phoneme take so no arm refuses them.
@MainActor
private func installFiveLetters(_ vm: TracingViewModel) {
    let a = vm.letters.first { $0.name == "A" } ?? vm.letters[0]
    vm.letters = TrainedLetterSubset.studyLetters.map { name in
        LetterAsset(id: name, name: name, baseLetter: name, letterCase: .upper,
                    audioFiles: ["\(name).mp3"],
                    strokes: LetterStrokes(letter: name, checkpointRadius: a.strokes.checkpointRadius,
                                           strokes: a.strokes.strokes),
                    phonemeAudioFiles: ["\(name)_phoneme1.mp3"])
    }
}

private func subset(_ raw: String) -> TrainedLetterSubset {
    TrainedLetterSubset.allSubsets.first { $0.rawValue == raw }!
}

@Suite(.serialized) @MainActor struct StudyNavigationFixTests {

    // MARK: - A8 (VERIFY H9)

    /// Mutation check: delete the `participantEnrolled` guard in
    /// `startColdProbe` — RED.
    @Test("with no child enrolled, a cold probe is refused with the enrolment text")
    func coldProbeRefusedWhenNotEnrolled() {
        let vm = TracingViewModel(.stub.with(studyMode: true).with(participantEnrolled: false))
        let refusal = vm.startColdProbe(letter: "A", kind: .pretest)
        #expect(refusal != nil, "an unenrolled probe was accepted")
        #expect(refusal?.contains("Kein Teilnehmer eingeschrieben") == true, "refusal text: \(refusal ?? "nil")")
        #expect(vm.currentProbe == nil, "the refused probe still loaded")
    }

    // MARK: - A9 (STATE-4): the chevron after a probe

    /// Round-1 `chevronAfterPretestOfFirstTrainedLetterSkipsIt`. Mutation
    /// check: make `loadTrainingResumeLetterAfterProbe` return false — RED
    /// (lands on L).
    @Test("after a repeated pretest of the first trained letter the chevron lands on it, not past it")
    func chevronAfterPretestOfFirstTrainedLetter() {
        let rig = LifecycleRig { d in d.trainedSubset = subset("FIL") }
        installFiveLetters(rig.vm)
        #expect(rig.vm.visibleLetterNames == ["I", "L", "F"], "precondition: motor order \(rig.vm.visibleLetterNames)")
        // Documented order A F I L M: the last pretest is on an untrained letter.
        for l in ["A", "F", "I", "L", "M"] { #expect(rig.vm.startColdProbe(letter: l, kind: .pretest) == nil) }
        rig.vm.nextLetter()
        #expect(rig.vm.currentLetterName == "I", "documented order: \(rig.vm.currentLetterName)")
        // A repeated pretest of I at the end (R-032 allows repeats).
        #expect(rig.vm.startColdProbe(letter: "I", kind: .pretest) == nil)
        rig.vm.nextLetter()
        #expect(rig.vm.currentLetterName == "I",
                "after a last pretest on I the chevron lands on \(rig.vm.currentLetterName): I is skipped")
        #expect(rig.vm.currentProbe == nil, "the chevron must leave the probe for training")
    }

    /// The first UNFINISHED letter, not simply the first: with I already
    /// trained, a probe followed by the chevron resumes at L.
    @Test("the chevron after a probe skips a trained letter the child already finished")
    func chevronAfterProbeSkipsFinishedLetter() {
        let dashURL = FileManager.default.temporaryDirectory.appendingPathComponent("NAV-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: dashURL) }
        let dash = JSONParentDashboardStore(fileURL: dashURL, failureCenter: PersistenceFailureCenter())
        let rig = LifecycleRig { d in
            d.trainedSubset = subset("FIL")
            d.dashboardStore = dash
        }
        installFiveLetters(rig.vm)
        dash.recordPhaseSession(letter: "I", phase: "freeWrite", completed: true, score: 0.6,
                                schedulerPriority: 0, condition: .threePhase)
        #expect(rig.vm.firstUntrainedLetterInSet == "L")
        #expect(rig.vm.startColdProbe(letter: "M", kind: .pretest) == nil)
        rig.vm.nextLetter()
        #expect(rig.vm.currentLetterName == "L", "lands on \(rig.vm.currentLetterName)")
    }

    // MARK: - A10 (STATE-5): no wrap in a study session

    /// Round-1 `chevronOnUnfinishedLastLetterWrapsToFirst`. Mutation check:
    /// delete the study clamp in `nextLetter` — RED (lands on I).
    @Test("the chevron on the unfinished last letter of the set stays there")
    func nextOnLastLetterDoesNotWrap() {
        let rig = LifecycleRig { d in d.trainedSubset = subset("FIL") }
        installFiveLetters(rig.vm)
        rig.vm.loadLetter(name: "F")
        #expect(rig.vm.isLastLetterOfSet)
        rig.vm.nextLetter()
        #expect(rig.vm.currentLetterName == "F",
                "chevron on the unfinished last letter started a second pass at \(rig.vm.currentLetterName)")
    }

    /// Mirror. Mutation check: delete the study clamp in `previousLetter` —
    /// RED (lands on F, the letter that ends the set).
    @Test("the left chevron on the first letter of the set stays there")
    func previousOnFirstLetterDoesNotWrap() {
        let rig = LifecycleRig { d in d.trainedSubset = subset("FIL") }
        installFiveLetters(rig.vm)
        rig.vm.loadLetter(name: "I")
        rig.vm.previousLetter()
        #expect(rig.vm.currentLetterName == "I",
                "left chevron on the first letter wrapped to \(rig.vm.currentLetterName)")
    }

    /// Control: mid-set the chevrons still move.
    @Test("mid-set the chevrons still move one letter")
    func midSetChevronsMove() {
        let rig = LifecycleRig { d in d.trainedSubset = subset("FIL") }
        installFiveLetters(rig.vm)
        rig.vm.loadLetter(name: "L")
        rig.vm.nextLetter()
        #expect(rig.vm.currentLetterName == "F")
        rig.vm.previousLetter()
        #expect(rig.vm.currentLetterName == "L")
    }

    // MARK: - A11 (STATE-6): repeat count and the end of the set

    /// Round-1 `repeatCountCelebratesTheSetBeforeTheLastPass`. Mutation
    /// check: drop `vm.isFinalPassOfLetter` from the end-of-set branch —
    /// RED (a celebration after pass 1).
    @Test("letterRepeatCount 2 celebrates the set once, after the last pass of the last letter")
    func repeatCountCelebratesOnceAfterLastPass() async {
        let rig = LifecycleRig(fallback: 0.01) { d in
            d.trainedSubset = subset("FIL")
            d.letterRepeatCount = 2
        }
        installFiveLetters(rig.vm)
        rig.vm.loadLetter(name: "F")
        await runOnePass(rig)
        #expect(rig.vm.currentLetterName == "F")
        #expect(rig.prompts.count(.celebration) == 0,
                "end-of-set celebration after pass 1 of 2 (awaitingNextParticipant=\(rig.vm.awaitingNextParticipant))")
        #expect(!rig.vm.awaitingNextParticipant, "the set was held after pass 1 of 2")
        await runOnePass(rig)
        #expect(rig.prompts.count(.celebration) == 1, "celebrations: \(rig.prompts.count(.celebration))")
        #expect(rig.vm.awaitingNextParticipant, "the set did not end after the last pass")
    }

    private func runOnePass(_ rig: LifecycleRig) async {
        await rig.waitUntil(5) { rig.vm.animation.armedStrokes != nil }
        rig.vm.animation.onCycleComplete?()
        #expect(rig.vm.phaseController.currentPhase == .guided)
        rig.vm.advanceLearningPhase()               // tracker completion
        #expect(rig.vm.phaseController.currentPhase == .freeWrite)
        rig.strokeDown(from: CGPoint(x: 60, y: 200), t0: 5000)
        rig.vm.endTouch()
        // The 2.0 s quiet window scores the free-write.
        await rig.waitUntil(10) { rig.vm.isPhaseSessionComplete || rig.vm.phaseController.currentPhase == .observe }
        try? await Task.sleep(for: .milliseconds(50))
    }
}

// MARK: - A9 (VERIFY-10): relaunch mid-set, real bundle repository

/// Adopted from the settle lane's `ExpSettleTests` (2026-11-02), which ran
/// RED on the iPad on main a3b70fbb: "relaunch parks on L, already finished".
@MainActor
private enum Relaunch {
    static let canvas = CGSize(width: 1084, height: 626)

    struct Stores {
        let dir: URL
        let dash: JSONParentDashboardStore
        let ledger = StubSetCompletionLedger()
        let archive = StubParticipantArchive()
        let log = StubEnrolmentLog()
        init() {
            dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("RELAUNCH-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            dash = JSONParentDashboardStore(fileURL: dir.appendingPathComponent("dash.json"),
                                            failureCenter: PersistenceFailureCenter())
        }
    }

    static func launch(_ s: Stores, subset: String) throws -> TracingViewModel {
        var deps = TracingDependencies.stub
        deps.repo = LetterRepository(cache: NullLetterCache())          // the real bundle
        deps.studyMode = true
        deps.thesisCondition = .threePhase
        deps.audioCondition = .silent
        deps.trainedSubset = try #require(TrainedLetterSubset(rawValue: subset))
        deps.dashboardStore = s.dash
        deps.setCompletion = s.ledger
        deps.participantArchive = s.archive
        deps.enrolmentLog = s.log
        let vm = TracingViewModel(deps)
        vm.canvasSize = canvas
        return vm
    }

    static func strokePoints(_ vm: TracingViewModel) -> [[CGPoint]] {
        guard let def = vm.strokeTracker.definition else { return [] }
        let f = vm.grid.activeCell.frame
        let useFrame = f.width > 0 && f.height > 0
        return def.strokes.map { s in
            s.checkpoints.map { cp in
                useFrame ? CGPoint(x: f.minX + cp.x * f.width, y: f.minY + cp.y * f.height)
                         : CGPoint(x: cp.x * canvas.width, y: cp.y * canvas.height)
            }
        }
    }

    static func walk(_ poly: [CGPoint], step: CGFloat = 4) -> [CGPoint] {
        guard poly.count >= 2 else { return poly }
        var out: [CGPoint] = [poly[0]]
        for i in 1..<poly.count {
            let a = poly[i - 1], b = poly[i]
            let n = max(1, Int(hypot(b.x - a.x, b.y - a.y) / step))
            for k in 1...n {
                let t = CGFloat(k) / CGFloat(n)
                out.append(CGPoint(x: a.x + t * (b.x - a.x), y: a.y + t * (b.y - a.y)))
            }
        }
        return out
    }

    static func touch(_ vm: TracingViewModel, _ strokes: [[CGPoint]], t: inout CFTimeInterval) {
        for s in strokes where !s.isEmpty {
            vm.beginTouch(at: s[0], t: t)
            for p in s.dropFirst() {
                t += 1.0 / 60
                vm.updateTouch(at: p, t: t, canvasSize: canvas)
            }
            vm.endTouch()
            t += 0.4
        }
    }
}

@Suite(.serialized) @MainActor struct StudyRelaunchParkTests {

    /// Mutation check: make `loadFirstTrainedLetter` take
    /// `visibleLetterNames.first` again — RED (parks on L).
    @Test("a relaunch mid-set parks on the first unfinished letter, and the finished one is not trained twice")
    func relaunchMidSetParksOnFirstUnfinishedLetter() async throws {
        let s = Relaunch.Stores(); defer { try? FileManager.default.removeItem(at: s.dir) }
        var vm = try Relaunch.launch(s, subset: "AFL")
        let first = vm.currentLetterName
        #expect(vm.visibleLetterNames == ["L", "F", "A"], "precondition: order \(vm.visibleLetterNames)")
        // Letter 1, played through: unpark, observe tap, guided trace, free-write trace.
        vm.startParkedLetter()
        vm.completeObservePhase()
        var t: CFTimeInterval = 1000
        Relaunch.touch(vm, Relaunch.strokePoints(vm).map { Relaunch.walk($0) }, t: &t)
        #expect(vm.learningPhase == .freeWrite, "precondition: guided completed (\(vm.learningPhase), \(vm.progress))")
        Relaunch.touch(vm, Relaunch.strokePoints(vm).map { Relaunch.walk($0) }, t: &t)
        for _ in 0..<80 where !vm.phaseController.isLetterSessionComplete { try await Task.sleep(for: .milliseconds(100)) }
        #expect(vm.phaseController.isLetterSessionComplete, "precondition: letter 1 finished")
        // Letter 2 started (mid-set).
        vm.nextLetter()
        let second = vm.currentLetterName
        vm.completeObservePhase()
        await s.dash.flush()

        // Relaunch (crash / force-quit / settings block): a fresh VM over the same stores.
        vm = try Relaunch.launch(s, subset: "AFL")
        #expect(vm.currentLetterName == second,
                "relaunch parks on \(vm.currentLetterName); \(first) is finished and \(second) was in progress")
        #expect(vm.launchParked)
        // One observe-pill tap and the child carries on: no second set of rows for letter 1.
        vm.startParkedLetter()
        vm.completeObservePhase()
        Relaunch.touch(vm, Relaunch.strokePoints(vm).map { Relaunch.walk($0) }, t: &t)
        Relaunch.touch(vm, Relaunch.strokePoints(vm).map { Relaunch.walk($0) }, t: &t)
        for _ in 0..<80 where !vm.phaseController.isLetterSessionComplete { try await Task.sleep(for: .milliseconds(100)) }
        let completedFirst = s.dash.snapshot.phaseSessionRecords
            .filter { $0.letter == first && $0.phase == "freeWrite" && $0.completed }.count
        #expect(completedFirst == 1, "\(first) trained twice under the same participant: \(completedFirst) completed free-write rows")
        await s.dash.flush()
    }
}
