// FinalTestInterruptionTests.swift
// PrimaeNativeTests
//
// Protocol revision 27, lane B2 (seat ruling 2026-11-23): the pause, the intro
// and the glimpse of the final test obey the study's interruption model
// (DECISIONS r8 "`.inactive` suspends the session instead of finalising it";
// r15/r16 "unplugging the headphones is an interruption", B1).
//
//   - ANY interruption (scene inactive/background, the parent area, the
//     headphones) FREEZES the stage timer: nothing advances while interrupted;
//   - the PAUSE resumes with its REMAINING time;
//   - the INTRO restarts from the start of its prompt (as an interrupted
//     observe restarts from its cue);
//   - a cut GLIMPSE restarts in full (the child gets the planned exposure) and
//     the row records the restart (`glimpseRestarts`, see the second suite);
//   - WRITING behaves as a free-writing interruption already does.
//
// HERMETIC and clock-driven: the stage timers run on the `finalTestSleep` seam
// and elapsed time is read from `mediaClock`; both are manual here, so nothing
// waits on wall time except the short `settle()` that lets a (wrongly) woken
// sleeper show itself. The rig, clock and doubles are `FinalTestFlowTests`'.

import Testing
import Foundation
import CoreGraphics
@testable import PrimaeNative

@MainActor
private func settle() async {
    try? await Task.sleep(for: .milliseconds(60))
}

@MainActor
@Suite struct FinalTestInterruptionTests {

    // MARK: Pause

    @Test("an interrupted pause is frozen: the released timer does not end it, and the intro does not play",
          arguments: [SessionInterruption.scene, .headphones, .parentArea])
    func pauseFreezes(source: SessionInterruption) async {
        let rig = FinalTestRig(pauseSeconds: 45)
        defer { rig.close() }
        await rig.finishTrainingOfEveryLetter()
        await rig.clock.waitForRequests(1)
        #expect(rig.vm.finalTestStage == .pause, "precondition")

        rig.vm.beginInterruption(source)
        rig.clock.release(0)              // the sleeper the interruption must have cancelled
        await settle()
        #expect(rig.vm.finalTestStage == .pause, "\(source): the pause ended while the session was interrupted")
        #expect(rig.prompts.count(.finalIntro) == 0, "\(source): the intro played during an interruption")
    }

    @Test("the pause resumes with its REMAINING time; time spent interrupted is not counted",
          arguments: [SessionInterruption.scene, .headphones, .parentArea])
    func pauseResumesWithRemainingTime(source: SessionInterruption) async {
        let rig = FinalTestRig(pauseSeconds: 45)
        defer { rig.close() }
        await rig.finishTrainingOfEveryLetter()
        await rig.clock.waitForRequests(1)

        rig.now.seconds += 10             // ten seconds of pause
        rig.vm.beginInterruption(source)
        rig.now.seconds += 500            // a long phone call
        rig.vm.endInterruption(source)

        await rig.clock.waitForRequests(2)
        #expect(rig.clock.requests.count == 2, "requests: \(rig.clock.requests)")
        #expect(rig.clock.requests[1] == 35, "the resumed pause asked for \(rig.clock.requests[1]) s, not the 35 s that remained")
        #expect(rig.vm.finalTestStage == .pause)
        rig.clock.release(1)
        await rig.waitUntil { rig.vm.finalTestStage == .intro }
        #expect(rig.vm.finalTestStage == .intro, "the resumed pause never ended")
    }

    @Test("nested interruptions: the pause stays frozen until the LAST one ends, and the elapsed time is taken once")
    func nestedInterruptionsResumeOnce() async {
        let rig = FinalTestRig(pauseSeconds: 30)
        defer { rig.close() }
        await rig.finishTrainingOfEveryLetter()
        await rig.clock.waitForRequests(1)

        rig.now.seconds += 5
        rig.vm.beginInterruption(.scene)
        rig.now.seconds += 20
        rig.vm.beginInterruption(.headphones)     // a second cover on top of the first
        rig.now.seconds += 20
        rig.vm.endInterruption(.scene)
        await settle()
        #expect(rig.clock.requests.count == 1, "the pause restarted while the headphones were still out: \(rig.clock.requests)")

        rig.vm.endInterruption(.headphones)
        await rig.clock.waitForRequests(2)
        #expect(rig.clock.requests[1] == 25, "30 s pause, 5 s elapsed -> 25 s; got \(rig.clock.requests[1])")
    }

    @Test("a real scene round trip (inactive, then active) freezes and resumes the pause")
    func sceneRoundTripPause() async {
        let rig = FinalTestRig(pauseSeconds: 45)
        defer { rig.close() }
        await rig.finishTrainingOfEveryLetter()
        await rig.clock.waitForRequests(1)

        rig.now.seconds += 15
        rig.vm.appWillResignActive()
        rig.clock.release(0)
        await settle()
        #expect(rig.vm.finalTestStage == .pause, "a Control Center pull ended the pause")

        rig.vm.appDidBecomeActive()
        await rig.clock.waitForRequests(2)
        #expect(rig.clock.requests[1] == 30)
    }

    // MARK: Intro

    @Test("an interrupted intro is frozen: its fallback timer does not start the glimpse",
          arguments: [SessionInterruption.scene, .headphones, .parentArea])
    func introFreezes(source: SessionInterruption) async {
        let rig = FinalTestRig()
        defer { rig.close() }
        await rig.finishTrainingOfEveryLetter()
        await rig.clock.waitForRequests(1)
        rig.clock.release(0)
        await rig.waitUntil { rig.vm.finalTestStage == .intro }
        await rig.clock.waitForRequests(2)
        #expect(rig.prompts.count(.finalIntro) == 1, "precondition")

        rig.vm.beginInterruption(source)
        rig.clock.release(1)
        await settle()
        #expect(rig.vm.finalTestStage == .intro, "\(source): the glimpse started during an interruption")
        #expect(rig.vm.currentProbe == nil, "\(source): a test letter loaded during an interruption")
    }

    @Test("the intro restarts from the start of its prompt, with a fresh fallback",
          arguments: [SessionInterruption.scene, .headphones, .parentArea])
    func introRestartsFromTheStart(source: SessionInterruption) async {
        let rig = FinalTestRig()
        defer { rig.close() }
        await rig.finishTrainingOfEveryLetter()
        await rig.clock.waitForRequests(1)
        rig.clock.release(0)
        await rig.waitUntil { rig.vm.finalTestStage == .intro }
        await rig.clock.waitForRequests(2)

        rig.vm.beginInterruption(source)
        rig.vm.endInterruption(source)
        await rig.clock.waitForRequests(3)
        #expect(rig.prompts.count(.finalIntro) == 2, "\(source): the intro did not play again from its start")
        #expect(rig.clock.requests[2] == FinalTestRules.introFallbackSeconds,
                "the restarted intro asked for \(rig.clock.requests[2]) s of fallback")
        #expect(rig.vm.finalTestStage == .intro)

        rig.clock.release(2)
        await rig.waitUntil { rig.vm.finalTestStage == .glimpse }
        #expect(rig.vm.finalTestStage == .glimpse, "the restarted intro never led to the glimpse")
        #expect(rig.prompts.count(.finalIntro) == 2)
    }

    @Test("an interruption in the breath between the intro's end and the glimpse restarts the intro too")
    func interruptionInTheBreathAfterTheIntro() async {
        let rig = FinalTestRig()
        defer { rig.close() }
        await rig.finishTrainingOfEveryLetter()
        await rig.clock.waitForRequests(1)
        rig.clock.release(0)
        await rig.waitUntil { rig.vm.finalTestStage == .intro }
        await rig.clock.waitForRequests(2)
        rig.vm.finalTestIntroEnded(cancelled: false)
        await rig.clock.waitForRequests(3)
        #expect(rig.clock.requests[2] == FinalTestRules.introEndToGlimpseSeconds, "precondition")

        rig.vm.beginInterruption(.scene)
        rig.clock.release(2)
        await settle()
        #expect(rig.vm.finalTestStage == .intro, "the glimpse started during an interruption")
        #expect(rig.vm.currentProbe == nil)

        rig.vm.endInterruption(.scene)
        await rig.clock.waitForRequests(4)
        #expect(rig.prompts.count(.finalIntro) == 2, "the intro was not replayed from its start")
    }

    @Test("an intro-ended report that arrives while interrupted starts nothing")
    func introEndReportDuringInterruptionIsIgnored() async {
        let rig = FinalTestRig()
        defer { rig.close() }
        await rig.finishTrainingOfEveryLetter()
        await rig.clock.waitForRequests(1)
        rig.clock.release(0)
        await rig.waitUntil { rig.vm.finalTestStage == .intro }
        await rig.clock.waitForRequests(2)

        rig.vm.beginInterruption(.headphones)
        rig.vm.finalTestIntroEnded(cancelled: false)
        await settle()
        #expect(rig.clock.requests.count == 2, "a glimpse was scheduled under an interruption: \(rig.clock.requests)")
        #expect(rig.vm.finalTestStage == .intro)
    }

    // MARK: Glimpse

    @Test("an interrupted glimpse is frozen: the released timer does not hide the glyph",
          arguments: [SessionInterruption.scene, .headphones, .parentArea])
    func glimpseFreezes(source: SessionInterruption) async {
        let rig = FinalTestRig(glimpseSeconds: 2)
        defer { rig.close() }
        await rig.finishTrainingOfEveryLetter()
        await rig.passPauseAndIntro()
        await rig.clock.waitForRequests(3)
        #expect(rig.vm.finalTestStage == .glimpse, "precondition")

        rig.vm.beginInterruption(source)
        rig.clock.release(2)
        await settle()
        #expect(rig.vm.finalTestStage == .glimpse, "\(source): the glyph hid while the session was interrupted")
        #expect(rig.vm.currentProbe == .finalTest)
    }

    @Test("a cut glimpse restarts in FULL, with its prompt, and hides after the full setting",
          arguments: [SessionInterruption.scene, .headphones, .parentArea])
    func glimpseRestartsInFull(source: SessionInterruption) async {
        let rig = FinalTestRig(glimpseSeconds: 2)
        defer { rig.close() }
        await rig.finishTrainingOfEveryLetter()
        await rig.passPauseAndIntro()
        await rig.clock.waitForRequests(3)
        let letter = rig.vm.currentLetterName
        #expect(rig.prompts.count(.finalGlimpse) == 1, "precondition")

        rig.now.seconds += 1.2            // the child saw it for 1.2 s of 2
        rig.vm.beginInterruption(source)
        rig.now.seconds += 90
        rig.vm.endInterruption(source)

        await rig.clock.waitForRequests(4)
        #expect(rig.clock.requests[3] == 2, "the restarted glimpse asked for \(rig.clock.requests[3]) s, not the full 2 s")
        #expect(rig.vm.finalTestStage == .glimpse)
        #expect(rig.vm.currentLetterName == letter, "the restart changed the letter")
        #expect(rig.prompts.count(.finalGlimpse) == 2, "'Merk ihn dir gut.' did not play again")

        rig.now.seconds += 2
        rig.clock.release(3)
        await rig.waitUntil { rig.vm.finalTestStage == .writing }
        #expect(rig.vm.finalTestStage == .writing)
        let shown = rig.vm.finalTestFacts?.glimpseSecondsShown
        #expect(shown == 2, "the recorded exposure is the full restarted glimpse (2 s), not \(String(describing: shown))")
    }

    @Test("a test letter that finishes while the session is covered starts its glimpse only when the cover lifts")
    func glimpseOfTheNextLetterWaitsForTheCover() async {
        let rig = FinalTestRig(glimpseSeconds: 2)
        defer { rig.close() }
        await rig.finishTrainingOfEveryLetter()
        await rig.passPauseAndIntro()
        await rig.clock.waitForRequests(3)
        rig.clock.release(2)
        await rig.waitUntil { rig.vm.finalTestStage == .writing }
        rig.writeOneStroke()
        rig.vm.finishFinalTestLetterTapped()
        await rig.waitUntil { rig.vm.isPhaseSessionComplete }
        let glimpsesBefore = rig.prompts.count(.finalGlimpse)

        rig.vm.beginInterruption(.scene)
        rig.vm.advanceAfterCompletedStudyLetter()     // the view's completion hook
        await settle()
        #expect(rig.vm.finalTestStage == .glimpse)
        #expect(rig.vm.currentLetterName == rig.vm.visibleLetterNames[1])
        #expect(rig.prompts.count(.finalGlimpse) == glimpsesBefore, "the glimpse prompt played under an interruption")
        #expect(rig.clock.requests.count == 3, "a glimpse timer ran under an interruption: \(rig.clock.requests)")

        rig.vm.endInterruption(.scene)
        await rig.clock.waitForRequests(4)
        #expect(rig.prompts.count(.finalGlimpse) == glimpsesBefore + 1)
        #expect(rig.clock.requests[3] == 2)
        #expect(rig.vm.finalTestFacts?.glimpseRestarts == 0, "a glimpse that merely started late was counted as a restart")
    }

    // MARK: Writing

    @Test("an interruption while writing keeps the letter open: no quiet window, no row, the check stays")
    func writingSurvivesAnInterruption() async {
        let rig = FinalTestRig()
        defer { rig.close() }
        await rig.finishTrainingOfEveryLetter()
        await rig.passPauseAndIntro()
        await rig.clock.waitForRequests(3)
        rig.clock.release(2)
        await rig.waitUntil { rig.vm.finalTestStage == .writing }
        rig.writeOneStroke()
        #expect(rig.vm.showsFinalTestCheck, "precondition")

        rig.vm.appWillResignActive()
        rig.vm.appDidBecomeActive()
        #expect(rig.vm.finalTestStage == .writing)
        #expect(!rig.vm.didCompleteCurrentLetter, "an inactive scene finished a final-test letter")
        #expect(rig.vm.showsFinalTestCheck, "the check button went away")
        #expect(!rig.vm.touchDispatcher.isFreeWriteAdvanceScheduled, "the resume armed the quiet window in the final test")
        #expect(rig.store.snapshot.phaseSessionRecords.filter { $0.probe == "finalTest" }.isEmpty,
                "an inactive scene wrote a row")
    }

    @Test("a stroke cut by an interruption is cancelled, and its ink still brings up the check button on resume")
    func cutStrokeStillShowsTheCheck() async {
        let rig = FinalTestRig()
        defer { rig.close() }
        await rig.finishTrainingOfEveryLetter()
        await rig.passPauseAndIntro()
        await rig.clock.waitForRequests(3)
        rig.clock.release(2)
        await rig.waitUntil { rig.vm.finalTestStage == .writing }

        // A stroke across the letter, the pen still DOWN.
        var t: CFTimeInterval = 1000
        var p = CGPoint(x: 50, y: 200)
        rig.vm.beginTouch(at: p, t: t)
        for _ in 0..<15 { t += 0.01; p.x += 10; rig.vm.updateTouch(at: p, t: t, canvasSize: rig.canvas) }
        #expect(rig.vm.touchDispatcher.isSingleTouchInteractionActive, "precondition")
        #expect(!rig.vm.showsFinalTestCheck, "the check showed before any lift")

        rig.vm.beginInterruption(.scene)
        #expect(!rig.vm.touchDispatcher.isSingleTouchInteractionActive, "the stroke under the pen was not cancelled")
        #expect(rig.vm.lifecycleCounters.strokesCancelled == 1)
        #expect(!rig.vm.showsFinalTestCheck, "a cancel is not the child's 'done'")

        rig.vm.endInterruption(.scene)
        #expect(rig.vm.showsFinalTestCheck, "the child's only stroke was cut and the letter can no longer be ended")
        #expect(!rig.vm.didCompleteCurrentLetter, "the resume finished the letter by itself")
        #expect(!rig.vm.touchDispatcher.isFreeWriteAdvanceScheduled)
    }

    @Test("BACKGROUNDING with a finished production finalises it as free-writing does (finalizedBy background); the next glimpse waits for the foreground")
    func backgroundFinalisesAsFreeWriteDoes() async {
        let rig = FinalTestRig(glimpseSeconds: 2)
        defer { rig.close() }
        await rig.finishTrainingOfEveryLetter()
        await rig.passPauseAndIntro()
        await rig.clock.waitForRequests(3)
        rig.clock.release(2)
        await rig.waitUntil { rig.vm.finalTestStage == .writing }
        rig.writeOneStroke()
        let glimpsesBefore = rig.prompts.count(.finalGlimpse)

        rig.vm.appWillResignActive()
        await rig.vm.appDidEnterBackground()
        await rig.waitUntil { rig.vm.isPhaseSessionComplete }
        let rows = rig.store.snapshot.phaseSessionRecords.filter { $0.probe == "finalTest" }
        #expect(rows.count == 1, "expected one final-test row, got \(rows.count)")
        #expect(rows.first?.finalizedBy == RowFinalization.background.rawValue,
                "the row says it was closed by \(String(describing: rows.first?.finalizedBy))")

        // The view's completion hook, while the app is in the background.
        rig.vm.advanceAfterCompletedStudyLetter()
        await settle()
        #expect(rig.prompts.count(.finalGlimpse) == glimpsesBefore, "the next glimpse started in the background")
        #expect(rig.clock.requests.count == 3)

        rig.vm.appDidBecomeActive()
        await rig.clock.waitForRequests(4)
        #expect(rig.prompts.count(.finalGlimpse) == glimpsesBefore + 1, "the next glimpse never started on return")
        #expect(rig.clock.requests[3] == 2)
    }

    @Test("an interruption outside the final test changes nothing in it")
    func inactiveStageIsUntouched() async {
        let rig = FinalTestRig()
        defer { rig.close() }
        #expect(rig.vm.finalTestStage == .inactive)
        rig.vm.beginInterruption(.scene)
        rig.vm.endInterruption(.scene)
        await settle()
        #expect(rig.vm.finalTestStage == .inactive)
        #expect(rig.clock.requests.isEmpty, "a final-test timer started outside the final test")
    }

    // MARK: The restart is recorded

    @Test("each cut of the glimpse is counted on the letter, an uncut letter says 0, and the next letter starts again at 0")
    func glimpseRestartsAreCounted() async {
        let rig = FinalTestRig(glimpseSeconds: 2)
        defer { rig.close() }
        await rig.finishTrainingOfEveryLetter()
        await rig.passPauseAndIntro()
        await rig.clock.waitForRequests(3)
        #expect(rig.vm.finalTestFacts?.glimpseRestarts == 0, "an uncut glimpse")

        rig.vm.beginInterruption(.scene); rig.vm.endInterruption(.scene)
        await rig.clock.waitForRequests(4)
        #expect(rig.vm.finalTestFacts?.glimpseRestarts == 1)
        rig.vm.beginInterruption(.headphones); rig.vm.endInterruption(.headphones)
        await rig.clock.waitForRequests(5)
        #expect(rig.vm.finalTestFacts?.glimpseRestarts == 2, "the second cut of the same glimpse")

        rig.clock.release(4)
        await rig.waitUntil { rig.vm.finalTestStage == .writing }
        rig.writeOneStroke()
        rig.vm.finishFinalTestLetterTapped()
        await rig.waitUntil { rig.vm.isPhaseSessionComplete }
        let rows = rig.store.snapshot.phaseSessionRecords.filter { $0.probe == "finalTest" }
        #expect(rows.count == 1)
        #expect(rows.first?.glimpseRestarts == 2, "the row says \(String(describing: rows.first?.glimpseRestarts))")

        // The next letter is its own glimpse.
        rig.vm.advanceAfterCompletedStudyLetter()
        await rig.clock.waitForRequests(6)
        #expect(rig.vm.finalTestFacts?.glimpseRestarts == 0, "the count carried over to the next letter")
    }

    @Test("an interruption of the pause, the intro or the writing is not a glimpse restart")
    func onlyAGlimpseCutCounts() async {
        let rig = FinalTestRig(glimpseSeconds: 2)
        defer { rig.close() }
        await rig.finishTrainingOfEveryLetter()
        await rig.clock.waitForRequests(1)
        rig.vm.beginInterruption(.scene); rig.vm.endInterruption(.scene)          // the pause
        await rig.clock.waitForRequests(2)
        rig.clock.release(1)
        await rig.waitUntil { rig.vm.finalTestStage == .intro }
        await rig.clock.waitForRequests(3)
        rig.vm.beginInterruption(.scene); rig.vm.endInterruption(.scene)          // the intro
        await rig.clock.waitForRequests(4)
        rig.clock.release(3)
        await rig.waitUntil { rig.vm.finalTestStage == .glimpse }
        await rig.clock.waitForRequests(5)
        rig.clock.release(4)
        await rig.waitUntil { rig.vm.finalTestStage == .writing }
        rig.writeOneStroke()
        rig.vm.beginInterruption(.scene); rig.vm.endInterruption(.scene)          // the writing
        #expect(rig.vm.finalTestStage == .writing)
        #expect(rig.vm.finalTestFacts?.glimpseRestarts == 0)
    }

    @Test("the restart count reaches the CSV in the last column of the final-test row, and is empty on training rows")
    func restartCountReachesTheCSV() async throws {
        let rig = FinalTestRig(glimpseSeconds: 2)
        defer { rig.close() }
        await rig.finishTrainingOfEveryLetter()
        await rig.passPauseAndIntro()
        await rig.clock.waitForRequests(3)
        rig.vm.beginInterruption(.scene); rig.vm.endInterruption(.scene)
        await rig.clock.waitForRequests(4)
        rig.clock.release(3)
        await rig.waitUntil { rig.vm.finalTestStage == .writing }
        rig.writeOneStroke()
        rig.vm.finishFinalTestLetterTapped()
        await rig.waitUntil { rig.vm.isPhaseSessionComplete }
        await rig.store.flush()

        let csv = String(data: ParentDashboardExporter.csvData(from: rig.store.snapshot, participantId: UUID(),
                                                               progress: [:], enrolledAt: nil), encoding: .utf8)!
        let block = try #require(DelimitedExport.block(in: csv, headerPrefix: "letter,phase,completed"))
        #expect(block.header.last == "glimpseRestarts", "the new column must be the last: \(block.header.suffix(3))")
        let probeColumn = try #require(block.header.firstIndex(of: "probe"))
        let test = try #require(block.rows.first { $0[probeColumn] == "finalTest" })
        #expect(test.last == "1", "the final-test row says \(String(describing: test.last))")
        let training = try #require(block.rows.first { $0[probeColumn].isEmpty })
        #expect(training.last == "", "a training row carries a restart count")
    }
}
