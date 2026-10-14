// RecordedPromptTests.swift
// Protocol r9 (D15): the five phrases a study child hears are RECORDED
// takes (voice Kiki). What these pin:
//   - a recorded observe cue reports its end through the SAME handler a
//     spoken one did (R-022), with the same end / cancelled semantics, so
//     the presentation starts 1.0 s after the cue's end, not at the 3.0 s
//     fallback;
//   - stop / replace report the cut phrase cancelled exactly once, and its
//     late finish callback reports nothing;
//   - the retry cue waits for a phrase in flight, never cuts it;
//   - a study build never falls back to the system voice for a missing take;
//   - the file set is the one the manifest names, and its id is the voiceId.

import Testing
import Foundation
@testable import PrimaeNative

/// A recorded take that plays no audio; the test decides when it ends.
@MainActor
final class FakeSound: RecordedSounding {
    var onFinish: ((Bool) -> Void)?
    var duration: TimeInterval = 2.0
    private(set) var played = false
    private(set) var stopped = false
    func play() { played = true }
    func stop() { stopped = true }          // like AVAudioPlayer: no delegate call
    func finish(_ ok: Bool = true) { onFinish?(ok) }
}

/// A watchdog sleep the test wakes by hand; records the waits asked for.
@MainActor
final class SleepGate {
    private(set) var requested: [TimeInterval] = []
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func sleep(_ seconds: TimeInterval) async {
        requested.append(seconds)
        await withCheckedContinuation { waiting.append($0) }
    }
    func releaseAll() { let w = waiting; waiting = []; w.forEach { $0.resume() } }
}

@MainActor
private func settle() async { for _ in 0..<30 { await Task.yield() } }

@MainActor
private final class Sounds {
    private(set) var made: [FakeSound] = []
    func make(_ url: URL) throws -> any RecordedSounding { let s = FakeSound(); made.append(s); return s }
}

@Suite @MainActor struct RecordedPromptPlayerTests {

    private let cue = ChildSpeechLibrary.phaseEntry(.observe)
    private let anyURL = URL(fileURLWithPath: "/dev/null")

    private func rig(speechFallback: Bool = false, located: Bool = true, gate: SleepGate? = nil)
        -> (player: PromptPlayer, speech: CueSpeechSpy, sounds: Sounds, reports: CueReports) {
        let speech = CueSpeechSpy()
        let sounds = Sounds()
        let reports = CueReports()
        speech.setUtteranceEndHandler { reports.items.append(CueReport(text: $0, cancelled: $1)) }
        let url = anyURL
        let player = PromptPlayer(fallbackSpeech: speech, speechFallback: speechFallback,
                                  makeSound: { try sounds.make($0) },
                                  locate: { _ in located ? url : nil },
                                  watchdogSleep: { s in
                                      if let gate { await gate.sleep(s) }
                                      else { try? await Task.sleep(for: .seconds(3600)) }
                                  })
        return (player, speech, sounds, reports)
    }

    @Test("a recorded cue that plays to its end reports ONE end, not cancelled, with the cue's text")
    func finishReportsTheEnd() {
        let r = rig()
        r.player.play(.phaseObserve, fallbackText: cue)
        #expect(r.sounds.made.count == 1 && r.sounds.made[0].played)
        #expect(r.reports.items.isEmpty, "an end was reported before the take ended")
        r.sounds.made[0].finish()
        #expect(r.reports.items == [CueReport(text: cue, cancelled: false)])
        r.sounds.made[0].finish()
        r.player.stop()
        #expect(r.reports.items.count == 1, "a second report for the same cue: \(r.reports.items)")
    }

    @Test("stop() cancels the cue in flight exactly once; its late finish callback adds nothing")
    func stopReportsCancelledOnce() {
        let r = rig()
        r.player.play(.phaseObserve, fallbackText: cue)
        r.player.stop()
        #expect(r.sounds.made[0].stopped)
        #expect(r.reports.items == [CueReport(text: cue, cancelled: true)])
        r.sounds.made[0].finish()
        r.player.stop()
        #expect(r.reports.items.count == 1, "stop() reported a spurious end: \(r.reports.items)")
    }

    @Test("stop() with nothing playing reports nothing")
    func idleStopIsSilent() {
        let r = rig()
        r.player.stop()
        #expect(r.reports.items.isEmpty)
    }

    @Test("a new phrase cuts the old one and reports it cancelled before its own end")
    func replacementCancelsTheOld() {
        let r = rig()
        r.player.play(.phaseObserve, fallbackText: cue)
        r.player.play(.phaseObserve, fallbackText: cue)
        #expect(r.reports.items == [CueReport(text: cue, cancelled: true)])
        #expect(r.sounds.made[0].stopped && r.sounds.made[1].played)
        r.sounds.made[0].finish()               // the cut take's stale callback
        #expect(r.reports.items.count == 1)
        r.sounds.made[1].finish()
        #expect(r.reports.items.last == CueReport(text: cue, cancelled: false))
    }

    @Test("a take that fails to decode reports its end as cancelled")
    func decodeFailureIsCancelled() {
        let r = rig()
        r.player.play(.phaseObserve, fallbackText: cue)
        r.sounds.made[0].finish(false)
        #expect(r.reports.items == [CueReport(text: cue, cancelled: true)])
    }

    @Test("the retry cue waits for the phrase in flight and plays after it; a later play drops a waiting one")
    func retryCueWaits() {
        let r = rig()
        r.player.play(.phaseGuided, fallbackText: "Jetzt du.")
        r.player.play(.retryCue, fallbackText: "Probier's nochmal")
        #expect(r.sounds.made.count == 1 && !r.sounds.made[0].stopped, "the retry cue cut the instruction")
        r.sounds.made[0].finish()
        #expect(r.sounds.made.count == 2 && r.sounds.made[1].played, "the retry cue never played")
        // Dropped by a later play:
        r.player.play(.phaseFreeWrite, fallbackText: "Und jetzt ganz allein.")
        r.player.play(.retryCue, fallbackText: "Probier's nochmal")
        r.player.play(.phaseObserve, fallbackText: cue)
        let before = r.sounds.made.count
        r.sounds.made.last!.finish()
        #expect(r.sounds.made.count == before, "a stale retry cue played after a newer phrase")
        // Dropped by stop():
        r.player.play(.phaseGuided, fallbackText: "Jetzt du.")
        r.player.play(.retryCue, fallbackText: "Probier's nochmal")
        let afterGuided = r.sounds.made.count
        r.player.stop()
        r.sounds.made.last!.finish()
        #expect(r.sounds.made.count == afterGuided, "a retry cue queued before stop() played after it")
    }

    @Test("a phrase the system never reports on is released after its length + 1 s: reported cancelled once, the waiting retry cue plays")
    func watchdogReleasesAStuckPhrase() async {
        let gate = SleepGate()
        let r = rig(gate: gate)
        r.player.play(.phaseGuided, fallbackText: "Jetzt du.")      // never finishes
        r.player.play(.retryCue, fallbackText: "Probier's nochmal")  // queued behind it
        await settle()
        #expect(gate.requested == [3.0], "watchdog wait is duration (2.0) + 1.0: \(gate.requested)")
        #expect(r.sounds.made.count == 1)
        gate.releaseAll()
        await settle()
        #expect(r.reports.items == [CueReport(text: "Jetzt du.", cancelled: true)],
                "the stuck phrase was not reported cancelled exactly once: \(r.reports.items)")
        #expect(r.sounds.made[0].stopped)
        #expect(r.sounds.made.count == 2 && r.sounds.made[1].played, "the queued retry cue stayed unheard")
        r.sounds.made[0].finish()
        #expect(r.reports.items.count == 1, "the stuck take's late callback reported again")
        gate.releaseAll()
    }

    @Test("a phrase that ends in time is not touched by the watchdog")
    func watchdogLeavesAFinishedPhraseAlone() async {
        let gate = SleepGate()
        let r = rig(gate: gate)
        r.player.play(.phaseObserve, fallbackText: cue)
        await settle()
        r.sounds.made[0].finish()
        gate.releaseAll()
        await settle()
        #expect(r.reports.items == [CueReport(text: cue, cancelled: false)], "\(r.reports.items)")
        #expect(!r.sounds.made[0].stopped)
    }

    @Test("a missing take in a study build is silence and a fault, never the system voice")
    func missingTakeDoesNotSpeak() {
        let r = rig(speechFallback: false, located: false)
        r.player.play(.phaseGuided, fallbackText: "Jetzt du.")
        #expect(r.speech.spoken.isEmpty, "fell back to the system voice: \(r.speech.spoken)")
        #expect(r.sounds.made.isEmpty)
    }

    @Test("the production default is no speech fallback (STUDY_BUILD is unconditional)")
    func productionDefaultHasNoFallback() {
        let speech = CueSpeechSpy()
        let player = PromptPlayer(fallbackSpeech: speech, locate: { _ in nil })
        player.play(.phaseGuided, fallbackText: "Jetzt du.")
        #expect(speech.spoken.isEmpty)
    }

    @Test("with the fallback enabled (tests only) a missing take still speaks its text")
    func fallbackWhenEnabled() {
        let r = rig(speechFallback: true, located: false)
        r.player.play(.phaseGuided, fallbackText: "Jetzt du.")
        #expect(r.speech.spoken == ["Jetzt du."])
    }
}

struct CueReport: Equatable { let text: String; let cancelled: Bool }
@MainActor final class CueReports { var items: [CueReport] = [] }

// MARK: - The view model hears a recorded cue end

@Suite @MainActor struct RecordedObserveCueTests {

    private var cue: String { ChildSpeechLibrary.phaseEntry(.observe) }

    private func recordedRig(sounds: Sounds, cueEnd: TimeInterval = 0.05) -> LifecycleRig {
        let url = URL(fileURLWithPath: "/dev/null")
        return LifecycleRig(fallback: 3600, cueEnd: cueEnd) { deps in
            deps.makePromptPlayer = { speech in
                PromptPlayer(fallbackSpeech: speech, speechFallback: false,
                             makeSound: { try sounds.make($0) }, locate: { _ in url })
            }
        }
    }

    @Test("the presentation starts after the RECORDED cue ends (the 3600 s fallback is not what starts it)")
    func recordedCueEndStartsThePresentation() async {
        let sounds = Sounds()
        let rig = recordedRig(sounds: sounds)
        rig.vm.loadLetter(name: "A")
        #expect(sounds.made.count == 1, "the observe cue was not played as a recording")
        #expect(rig.speech.spoken.isEmpty, "a live line was spoken for the recorded cue")
        try? await Task.sleep(for: .milliseconds(200))
        #expect(rig.vm.animation.armedStrokes == nil, "started before the cue ended")
        sounds.made[0].finish()
        await rig.waitUntil(10) { rig.vm.animation.armedStrokes != nil }
        #expect(rig.vm.animation.armedStrokes != nil, "the recorded cue's end did not start the observe")
    }

    @Test("an OLDER load's recorded cue being cut does not start the newer load's presentation")
    func cutCueDoesNotStartTheNewerLoad() async {
        let sounds = Sounds()
        let rig = recordedRig(sounds: sounds)
        rig.vm.loadLetter(name: "A")
        rig.vm.loadLetter(name: "A")             // cuts the first cue: reported cancelled
        #expect(sounds.made.count == 2)
        #expect(rig.vm.debugPendingObserveCues == 1, "the cut cue was not counted down")
        sounds.made[0].finish()                  // its stale callback
        try? await Task.sleep(for: .milliseconds(300))
        #expect(rig.vm.animation.armedStrokes == nil, "a cut cue started the presentation")
        sounds.made[1].finish()
        await rig.waitUntil(10) { rig.vm.animation.armedStrokes != nil }
        #expect(rig.vm.animation.armedStrokes != nil)
    }

    @Test("stop() on the prompt player does not start the presentation")
    func stoppedCueStartsNothing() async {
        let sounds = Sounds()
        let rig = recordedRig(sounds: sounds)
        rig.vm.loadLetter(name: "A")
        rig.vm.prompts.stop()
        #expect(rig.vm.debugPendingObserveCues == 0)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(rig.vm.animation.armedStrokes == nil, "a stopped cue was taken for a finished one")
    }
}

// MARK: - The set

@Suite @MainActor struct RecordedPromptSetTests {

    @Test("the five required keys are exactly the study's spoken phrases, in manifest order")
    func requiredKeys() {
        #expect(RecordedPromptSet.requiredKeys.map(\.rawValue)
                == ["phase_observe", "phase_guided", "phase_freewrite", "retry_cue", "celebration"])
        for key in RecordedPromptSet.requiredKeys {
            #expect(StudyVoiceoverPromptPlayer.studySpokenKeys.contains(key), "\(key) is not passed in a study session")
        }
    }

    @Test("the set id the app stamps is the one MANIFEST.json (checked in CI against the bytes) names")
    func setIdMatchesTheManifest() throws {
        let url = try #require(PrimaeBundle.resourceURL(
            firstOf: PrimaeBundle.layouts(dir: "Prompts", name: "MANIFEST", ext: "json")),
            "MANIFEST.json is not bundled")
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(RecordedPromptSet.setId() == json["setId"] as? String)
    }

    @Test("a missing or unreadable file gives no id; the id depends on the bytes")
    func idNeedsAllFiveAndTheirBytes() {
        #expect(RecordedPromptSet.setId(locate: { $0 == .retryCue ? nil : PromptPlayer.locate($0) }) == nil)
        #expect(RecordedPromptSet.setId(read: { _ in nil }) == nil)
        let a = RecordedPromptSet.setId(read: { _ in Data([1]) })
        let b = RecordedPromptSet.setId(read: { _ in Data([2]) })
        #expect(a != nil && a != b)
    }

    @Test("verify: ok for the bundled set, missing for a hole, corrupt for changed bytes or no manifest")
    func verdicts() {
        guard case .ok(let id) = RecordedPromptSet.verify() else { Issue.record("bundled set is not ok"); return }
        #expect(id == RecordedPromptSet.setId())
        #expect(RecordedPromptSet.verify(locate: { $0 == .celebration ? nil : PromptPlayer.locate($0) })
                == .missing([.celebration]))
        // One take's bytes differ from the reviewed ones.
        let tampered = RecordedPromptSet.verify(read: {
            let d = try? Data(contentsOf: $0)
            return $0.lastPathComponent == "retry_cue.mp3" ? d.map { $0 + [0] } : d
        })
        guard case .corrupt(let actual, let expected) = tampered else { Issue.record("\(tampered)"); return }
        #expect(actual != nil && actual != expected && expected == id)
        // The manifest cannot be read.
        let noManifest = RecordedPromptSet.verify(read: {
            $0.lastPathComponent == "MANIFEST.json" ? nil : try? Data(contentsOf: $0)
        })
        #expect(noManifest == .corrupt(actual: id, expected: nil))
        #expect(RecordedPromptSet.refusal(for: tampered)?.contains("nicht die geprüften") == true)
        #expect(RecordedPromptSet.refusal(for: .ok(id)) == nil)
        #expect(RecordedPromptSet.dashboardText(.ok(id)) == "Kiki · \(id)")
        #expect(RecordedPromptSet.dashboardText(.missing([.retryCue])) == "UNVOLLSTÄNDIG – fehlt: retry_cue.mp3")
    }

    @Test("a study session refuses when a take's bytes are not the reviewed ones, and checks the set once, not per read")
    func corruptTakeRefusesAndTheCheckIsCached() {
        var reads = 0
        var deps = TracingDependencies.stub
        deps.studyMode = true; deps.thesisCondition = .threePhase; deps.audioCondition = .silent
        deps.spokenFeedbackInStudy = true
        deps.promptReader = {
            reads += 1
            let d = try? Data(contentsOf: $0)
            return $0.lastPathComponent == "phase_guided.mp3" ? d.map { $0 + [0] } : d
        }
        let vm = TracingViewModel(deps)
        let afterInit = reads
        #expect(afterInit > 0, "precondition: the check read the files")
        for _ in 0..<5 { #expect(vm.studyPreconditionFailure?.contains("nicht die geprüften") == true) }
        _ = vm.sessionVoiceId; _ = vm.recordedPromptsDashboardText
        #expect(reads == afterInit, "the set was re-read after init: \(reads - afterInit) more reads")
        #expect(vm.sessionVoiceId == nil, "a changed set must not be stamped as the reviewed one")
        #expect(vm.recordedPromptsDashboardText?.hasPrefix("VERÄNDERT") == true)
    }

    @Test("the dashboard shows the recorded set for a voiceover session, and live-voice controls only where a live voice can be heard")
    func dashboardTruth() {
        var deps = TracingDependencies.stub
        deps.studyMode = true; deps.thesisCondition = .threePhase; deps.audioCondition = .silent
        deps.spokenFeedbackInStudy = true
        let voiceover = TracingViewModel(deps)
        #expect(voiceover.playsRecordedPrompts && !voiceover.liveSpeechReachable)
        #expect(voiceover.recordedPromptsDashboardText == "Kiki · \(RecordedPromptSet.setId() ?? "?")")
        deps.spokenFeedbackInStudy = false
        let quiet = TracingViewModel(deps)
        #expect(!quiet.playsRecordedPrompts && !quiet.liveSpeechReachable && quiet.recordedPromptsDashboardText == nil)
        var casual = TracingDependencies.stub
        casual.studyMode = false; casual.audioCondition = .phoneme
        casual.speech = CueSpeechSpy()
        let live = TracingViewModel(casual)
        #expect(live.liveSpeechReachable && !live.playsRecordedPrompts, "a non-study session with a live voice lost its controls")
    }

    @Test("the refusal names every missing file; an empty list is no refusal")
    func refusalText() {
        #expect(RecordedPromptSet.refusal(missing: []) == nil)
        let text = RecordedPromptSet.refusal(missing: [.retryCue, .celebration])
        #expect(text?.contains("retry_cue.mp3") == true && text?.contains("celebration.mp3") == true)
    }
}

// MARK: - The second retry-cue call site

@Suite @MainActor struct RetryCueFreeWriteSiteTests {
    @Test("a confident-wrong free-writing result plays the recorded retry cue through the prompt player, not the live voice")
    func freeWriteRetryUsesTheRecording() {
        let speech = CueSpeechSpy()
        let prompts = PromptSpy()
        var deps = TracingDependencies.stub
        deps.studyMode = false              // the retry path is the casual one: study never retries
        deps.audioCondition = .phoneme
        deps.speech = speech
        deps.makePromptPlayer = { _ in prompts }
        let vm = TracingViewModel(deps)
        #expect(vm.prompts === prompts as AnyObject, "precondition: the prompt player is the injected one")
        let wrong = RecognitionResult(predictedLetter: "X", confidence: 0.95, topThree: [], isCorrect: false)
        vm.phaseTransitions.completePostFreeWriteRecognition(score: 0.5, result: wrong)
        #expect(prompts.count(.retryCue) == 1, "keys: \(prompts.keys)")
        #expect(!speech.spoken.contains("Probier's nochmal"), "spoken live: \(speech.spoken)")
    }
}
