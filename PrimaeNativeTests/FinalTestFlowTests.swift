// FinalTestFlowTests.swift
// PrimaeNativeTests
//
// Protocol revision 27 (David, 2026-11-23): after the third trained letter a
// silent bubble pause, then a FINAL TEST — each trained letter once more, in
// training order, as a plain glyph for a moment, hidden, and written from
// memory; no sound in any arm, no feedback, no retry, ended by a check button
// rather than the quiet window; then "Super gemacht!" and the session end
// screen.
//
// WHAT IS PINNED, and how:
//   - the DECISIONS as plain values (`FinalTestRules`, `PauseBubbles`), the
//     `CanvasDrawPlan` pattern: the views replay them and are not tested;
//   - the whole flow through the view model, with a MANUAL clock injected at
//     the `finalTestSleep` seam, so "the pause lasts the setting" and "the
//     glyph hides after the setting" are asserted on the REQUESTED duration
//     and on the stage that follows its release, never on wall time;
//   - the settings (domains, clamping, stamp, reset), the revision, the
//     prompt set, and the export fields.
//
// HERMETIC. No global is written: the settings come through the dependency
// seams (`pauseSeconds`, `glimpseSeconds`), the recorded-prompt set is a fake
// one served through `promptLocator`/`promptReader` (so these tests do not
// depend on whether the r27 takes have been recorded yet), the dashboard
// store is a temp file, and nothing touches `UserDefaults.standard`.

import Testing
import Foundation
import CoreGraphics
@testable import PrimaeNative

// MARK: - Doubles

/// Stands in for `Task.sleep` at the `finalTestSleep` seam: it records every
/// requested duration and returns only when the test releases that request
/// (or the test is over), polling so a cancelled task ends at once.
@MainActor
final class FinalTestClock {
    private(set) var requests: [TimeInterval] = []
    private var released = Set<Int>()
    private var closed = false

    func sleep(_ seconds: TimeInterval) async {
        let id = requests.count
        requests.append(seconds)
        while !closed, !released.contains(id), !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    func release(_ id: Int) { released.insert(id) }
    /// Lets every pending sleeper go, so none outlives its test.
    func close() { closed = true }

    /// Waits (by polls, not wall time) until `n` sleeps have been requested.
    func waitForRequests(_ n: Int) async {
        for _ in 0..<3000 where requests.count < n {
            try? await Task.sleep(for: .milliseconds(2))
        }
    }
}

/// The monotonic clock the rows read (`deps.mediaClock`).
final class FinalTestNow: @unchecked Sendable {
    var seconds: TimeInterval = 1000
}

/// The recognizer, stubbed: freeWrite completion is deferred to its return.
private struct FinalTestRecognizer: LetterRecognizerProtocol {
    func recognize(points: [CGPoint], strokeStartIndices: [Int],
                   canvasSize: CGSize, expectedLetter: String?,
                   historicalFormScores: [CGFloat]) async -> RecognitionResult? { nil }
    func isModelAvailable() async -> Bool { true }
}

/// A resource provider that serves only `letters` from the real bundle.
private struct FinalTestLetterProvider: LetterResourceProviding {
    private let base = BundleLetterResourceProvider()
    let letters: Set<String>
    var bundle: Bundle { base.bundle }
    var searchBundles: [Bundle] { base.searchBundles }
    func allResourceURLs() -> [URL] {
        base.allResourceURLs().filter { url in letters.contains { url.path.contains("/" + $0 + "/") } }
    }
    func resourceURL(for relativePath: String) -> URL? { base.resourceURL(for: relativePath) }
}

/// A fake recorded-prompt set that verifies `.ok`: seven fake files whose
/// bytes hash to the id the fake manifest names.
@MainActor
enum HermeticPromptSet {
    static func install(into deps: inout TracingDependencies) {
        let locate: @MainActor (PromptPlayer.PromptKey) -> URL? = {
            URL(fileURLWithPath: "/hermetic/\($0.rawValue).mp3")
        }
        let bytes: (URL) -> Data? = { Data($0.lastPathComponent.utf8) }
        let setId = RecordedPromptSet.setId(locate: locate, read: bytes) ?? "unreachable"
        deps.promptLocator = locate
        deps.promptReader = { url in
            if url.lastPathComponent == "MANIFEST.json" {
                return try? JSONSerialization.data(withJSONObject: ["setId": setId])
            }
            return bytes(url)
        }
    }
}

/// A study session over A, F, I (the stub's trained subset "AFI") with the
/// final-test seams under the test's control.
@MainActor
final class FinalTestRig {
    let vm: TracingViewModel
    let prompts = PromptSpy()
    let clock = FinalTestClock()
    let now = FinalTestNow()
    let audio = EngineModelAudio()
    let store: JSONParentDashboardStore
    private let storeURL: URL
    let canvas = CGSize(width: 400, height: 400)

    init(arm: PilotAudioCondition = .silent,
         pauseSeconds: Double? = nil,
         glimpseSeconds: Double? = nil,
         pool: Set<String> = ["A", "F", "I"],
         configure: (inout TracingDependencies) -> Void = { _ in }) {
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("final-test-\(UUID().uuidString).json")
        store = JSONParentDashboardStore(fileURL: storeURL)
        var deps = TracingDependencies.stub
        deps.studyMode = true
        deps.thesisCondition = .threePhase
        deps.audioCondition = arm
        deps.spokenFeedbackInStudy = true
        deps.letterRecognizer = FinalTestRecognizer()
        deps.repo = LetterRepository(
            resources: FinalTestLetterProvider(letters: pool),
            cache: NullLetterCache(),
            userDefaults: UserDefaults(suiteName: "final-test-\(UUID().uuidString)") ?? .standard)
        deps.audio = audio
        deps.dashboardStore = store
        let prompts = self.prompts
        deps.makePromptPlayer = { _ in prompts }
        HermeticPromptSet.install(into: &deps)
        if let pauseSeconds { deps.pauseSeconds = pauseSeconds }
        if let glimpseSeconds { deps.glimpseSeconds = glimpseSeconds }
        let clock = self.clock
        deps.finalTestSleep = { await clock.sleep($0) }
        let now = self.now
        deps.mediaClock = { now.seconds }
        configure(&deps)
        vm = TracingViewModel(deps)
        vm.canvasSize = canvas
    }

    deinit { try? FileManager.default.removeItem(at: storeURL) }

    /// Poll the main actor until `condition` holds (bounded by polls).
    func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<3000 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// One training pass of `name`: observe -> guided -> freeWrite -> done.
    func finishTraining(_ name: String) async {
        vm.loadLetter(name: name)
        vm.advanceLearningPhase()
        vm.advanceLearningPhase()
        vm.advanceLearningPhase()
        await waitUntil { vm.isPhaseSessionComplete }
        try? await Task.sleep(for: .milliseconds(100))
    }

    /// The whole training: every trained letter once, in order.
    func finishTrainingOfEveryLetter() async {
        for name in vm.visibleLetterNames { await finishTraining(name) }
    }

    /// One stroke across the letter, pen DOWN, then the lift.
    func writeOneStroke(from start: CGPoint = CGPoint(x: 50, y: 200), t0: CFTimeInterval = 1000) {
        var t = t0
        var p = start
        vm.beginTouch(at: p, t: t)
        for _ in 0..<15 { t += 0.01; p.x += 10; vm.updateTouch(at: p, t: t, canvasSize: canvas) }
        vm.endTouch()
    }

    /// Runs pause -> intro with the clock: releases request 0 (the pause) and
    /// request 1 (the intro fallback).
    func passPauseAndIntro() async {
        await clock.waitForRequests(1)
        clock.release(0)
        await waitUntil { vm.finalTestStage == .intro }
        await clock.waitForRequests(2)
        clock.release(1)
        await waitUntil { vm.finalTestStage == .glimpse }
    }

    func close() { clock.close() }
}

// MARK: - Decisions as plain values

@MainActor
@Suite struct FinalTestRulesTests {

    @Test("the test letters are the trained letters in TRAINING order, each once")
    func lettersFollowTrainingOrder() {
        #expect(FinalTestRules.letters(trainingOrder: ["I", "A", "F"]) == ["I", "A", "F"])
        #expect(FinalTestRules.letters(trainingOrder: ["A", "F", "A", "I", "F"]) == ["A", "F", "I"],
                "a repeated letter in the pool is tested once, at its first place")
        #expect(FinalTestRules.letters(trainingOrder: []).isEmpty)
    }

    @Test("touches are taken in training and while writing, and in no other stage")
    func touchAcceptance() {
        #expect(FinalTestRules.acceptsTouch(.inactive))
        #expect(FinalTestRules.acceptsTouch(.writing))
        for stage in [FinalTestStage.pause, .intro, .glimpse] {
            #expect(!FinalTestRules.acceptsTouch(stage), "\(stage) took a touch")
        }
    }

    @Test("the plain glyph is drawn during the glimpse only; the scaffolding never in the test")
    func glyphAndScaffolding() {
        for stage in [FinalTestStage.inactive, .pause, .intro, .writing] {
            #expect(!FinalTestRules.showsGlimpseGlyph(stage))
        }
        #expect(FinalTestRules.showsGlimpseGlyph(.glimpse))
        #expect(FinalTestRules.showsScaffolding(.inactive))
        for stage in [FinalTestStage.pause, .intro, .glimpse, .writing] {
            #expect(!FinalTestRules.showsScaffolding(stage), "\(stage) draws a guide, start dots or a ring")
        }
    }

    @Test("the check button shows while writing and after the first stroke, never before")
    func checkButton() {
        #expect(FinalTestRules.showsCheckButton(stage: .writing, hasInk: true))
        #expect(!FinalTestRules.showsCheckButton(stage: .writing, hasInk: false), "the button was up before any ink")
        for stage in [FinalTestStage.inactive, .pause, .intro, .glimpse] {
            #expect(!FinalTestRules.showsCheckButton(stage: stage, hasInk: true), "\(stage) showed the button")
        }
    }

    @Test("the quiet window ends every letter except a final-test letter")
    func quietWindow() {
        #expect(FinalTestRules.endsOnQuietWindow(probe: nil))
        for probe in [StudyProbe.pretest, .posttest, .delayed] {
            #expect(FinalTestRules.endsOnQuietWindow(probe: probe), "\(probe) lost its quiet window")
        }
        #expect(!FinalTestRules.endsOnQuietWindow(probe: .finalTest))
    }

    @Test("chrome is hidden from the pause on; the pause screen is the pause stage only")
    func chromeAndPause() {
        #expect(!FinalTestRules.hidesChrome(.inactive))
        for stage in [FinalTestStage.pause, .intro, .glimpse, .writing] {
            #expect(FinalTestRules.hidesChrome(stage))
        }
        #expect(FinalTestRules.showsPause(.pause))
        for stage in [FinalTestStage.inactive, .intro, .glimpse, .writing] {
            #expect(!FinalTestRules.showsPause(stage))
        }
    }

    @Test("the next test letter is the following index, and nil after the last")
    func nextIndex() {
        #expect(FinalTestRules.nextIndex(after: 0, count: 3) == 1)
        #expect(FinalTestRules.nextIndex(after: 1, count: 3) == 2)
        #expect(FinalTestRules.nextIndex(after: 2, count: 3) == nil)
        #expect(FinalTestRules.nextIndex(after: 0, count: 1) == nil)
    }

    @Test("a final-test probe tests only TRAINED letters; the other probes keep their rule")
    func finalTestIsRestrictedToTheTrainedSubset() {
        let study = Set(TrainedLetterSubset.studyLetters)
        let untrained: Set<String> = ["L", "M"]
        for letter in ["A", "F", "I"] {
            #expect(StudyProbe.finalTest.permits(letter: letter, untrained: untrained, studyLetters: study))
        }
        for letter in untrained {
            #expect(!StudyProbe.finalTest.permits(letter: letter, untrained: untrained, studyLetters: study),
                    "the final test accepted untrained \(letter)")
            #expect(StudyProbe.posttest.permits(letter: letter, untrained: untrained, studyLetters: study),
                    "the post-test must keep accepting every study letter (r12)")
        }
        #expect(!StudyProbe.finalTest.permits(letter: "Z", untrained: untrained, studyLetters: study),
                "a letter outside the study set")
    }
}

// MARK: - The bubbles

@MainActor
@Suite struct PauseBubblesTests {

    @Test("a bubble is a pure function of its index and age")
    func deterministic() {
        for i in 0..<20 {
            #expect(PauseBubbles.bubble(i, age: 2.5) == PauseBubbles.bubble(i, age: 2.5))
        }
    }

    @Test("a bubble exists only while it floats: not before its birth, not after it has risen")
    func lifetime() {
        for i in 0..<20 {
            let rise = PauseBubbles.riseSeconds(i)
            #expect((7.0...11.0).contains(rise), "bubble \(i) rises in \(rise) s — too fast for a 5-year-old's finger")
            #expect(PauseBubbles.bubble(i, age: -0.01) == nil)
            #expect(PauseBubbles.bubble(i, age: rise + 0.01) == nil)
            #expect(PauseBubbles.bubble(i, age: rise / 2) != nil)
        }
    }

    @Test("a bubble rises (y falls) and stays inside the width")
    func risesInsideTheWidth() throws {
        for i in 0..<20 {
            let rise = PauseBubbles.riseSeconds(i)
            let early = try #require(PauseBubbles.bubble(i, age: rise * 0.2))
            let late = try #require(PauseBubbles.bubble(i, age: rise * 0.8))
            #expect(late.y < early.y, "bubble \(i) sank")
            for b in [early, late] {
                #expect((0.0...1.0).contains(b.x), "bubble \(i) left the screen sideways: \(b.x)")
                #expect((0...3).contains(b.colourIndex))
            }
        }
    }

    @Test("bubbles are born one after another at the spawn rate")
    func birthOrder() {
        #expect(PauseBubbles.birth(0) == 0)
        #expect(PauseBubbles.birth(1) < PauseBubbles.birth(2))
        #expect(abs(PauseBubbles.birth(14) - 14 / PauseBubbles.spawnPerSecond) < 1e-9)
    }
}

// MARK: - Settings, revision, prompt set

@MainActor
@Suite struct FinalTestSettingsTests {

    typealias S = StudyComparisonSettings

    @Test("defaults and ranges are the ones David ruled: pause 45 s in 30...60, glimpse 3.0 s in 1.0...3.0")
    func defaultsAndRanges() {
        #expect(S.pauseSecondsDefault == 45)
        #expect(S.pauseSecondsRange == 30...60)
        #expect(S.glimpseSecondsDefault == 3.0)
        #expect(S.glimpseSecondsRange == 1.0...3.0)
        #expect(StudyComparisonConfiguration.defaults.pauseSeconds == 45)
        #expect(StudyComparisonConfiguration.defaults.glimpseSeconds == 3.0)
    }

    @Test("the steppers' domains match the store: 30...60 step 5, 1...3 step 0.5")
    func controlDomains() {
        #expect(ComparisonControlDomains.pauseSeconds.range == 30...60)
        #expect(ComparisonControlDomains.pauseSeconds.step == 5)
        #expect(ComparisonControlDomains.glimpseSeconds.range == 1...3)
        #expect(ComparisonControlDomains.glimpseSeconds.step == 0.5)
    }

    @Test("an out-of-range stored value is clamped, an in-range one is kept")
    func clamping() {
        let box = ThrowawayDefaults()
        box.defaults.set(500.0, forKey: S.pauseSecondsKey)
        box.defaults.set(0.1, forKey: S.glimpseSecondsKey)
        var c = S.configuration(in: box.defaults)
        #expect(c.pauseSeconds == 60)
        #expect(c.glimpseSeconds == 1.0)
        box.defaults.set(35.0, forKey: S.pauseSecondsKey)
        box.defaults.set(2.5, forKey: S.glimpseSecondsKey)
        c = S.configuration(in: box.defaults)
        #expect(c.pauseSeconds == 35)
        #expect(c.glimpseSeconds == 2.5)
    }

    @Test("both settings are in the stamp when moved, and reset to their defaults")
    func stampAndReset() {
        let box = ThrowawayDefaults()
        #expect(S.configuration(in: box.defaults).nonDefaultStamp == nil, "precondition: a fresh store stamps nothing")
        box.defaults.set(30.0, forKey: S.pauseSecondsKey)
        box.defaults.set(1.5, forKey: S.glimpseSecondsKey)
        let stamp = S.configuration(in: box.defaults).nonDefaultStamp ?? ""
        #expect(stamp.contains("pauseSeconds=30"), "\(stamp)")
        #expect(stamp.contains("glimpseSeconds=1.5"), "\(stamp)")
        S.resetToDefaults(in: box.defaults)
        #expect(S.configuration(in: box.defaults).pauseSeconds == S.pauseSecondsDefault)
        #expect(S.configuration(in: box.defaults).glimpseSeconds == S.glimpseSecondsDefault)
    }

    @Test("the protocol is at revision 27, and the newest history entry says what r27 changed")
    func revision27() throws {
        #expect(StudyProtocol.revision == 27)
        let last = try #require(StudyProtocol.history.last)
        #expect(last.revision == 27)
        #expect(last.childFacingChange.localizedCaseInsensitiveContains("final test")
                || last.childFacingChange.localizedCaseInsensitiveContains("Abschlusstest"),
                "the r27 entry does not name the final test")
    }

    @Test("the recorded set needs SEVEN takes, in manifest order, all passed in a study session")
    func promptSetHasSevenKeys() {
        #expect(RecordedPromptSet.requiredKeys.count == 7)
        #expect(RecordedPromptSet.requiredKeys.suffix(2).map(\.rawValue) == ["final_intro", "final_glimpse"])
        #expect(StudyVoiceoverPromptPlayer.studySpokenKeys == Set(RecordedPromptSet.requiredKeys))
        #expect(ChildSpeechLibrary.finalIntro == "Jetzt schreibst du sie alle noch einmal.")
        #expect(ChildSpeechLibrary.finalGlimpse == "Merk ihn dir gut.")
    }

    @Test("a set missing the two new takes is refused, and the refusal names both files and says seven")
    func refusalNamesTheNewTakes() {
        let verdict = RecordedPromptSet.verify(
            locate: { [.finalIntro, .finalGlimpse].contains($0) ? nil : URL(fileURLWithPath: "/x/\($0.rawValue).mp3") },
            read: { _ in Data([1]) })
        #expect(verdict == .missing([.finalIntro, .finalGlimpse]))
        let text = RecordedPromptSet.refusal(for: verdict) ?? ""
        #expect(text.contains("final_intro.mp3") && text.contains("final_glimpse.mp3"), "\(text)")
        #expect(text.contains("sieben"), "\(text)")
        #expect(!text.contains("fünf"), "\(text)")
    }

    @Test("MANIFEST.json lists the seven keys in requiredKeys order")
    func manifestKeyOrder() throws {
        let url = try #require(PrimaeBundle.resourceURL(
            firstOf: PrimaeBundle.layouts(dir: "Prompts", name: "MANIFEST", ext: "json")))
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let files = try #require(json["files"] as? [[String: Any]])
        #expect(files.compactMap { $0["key"] as? String } == RecordedPromptSet.requiredKeys.map(\.rawValue))
    }
}

// MARK: - The flow through the view model

@MainActor
@Suite struct FinalTestFlowTests {

    @Test("the third trained letter starts the pause: no celebration, no end screen, navigation held")
    func trainingEndsInThePause() async {
        let rig = FinalTestRig()
        defer { rig.close() }
        // Study order is `.motorSimilarity` (I, L, T, F, E, H, A, …), not alphabetical.
        #expect(rig.vm.visibleLetterNames == ["I", "F", "A"], "fixture: \(rig.vm.visibleLetterNames)")
        await rig.finishTrainingOfEveryLetter()

        #expect(rig.vm.finalTestStage == .pause)
        #expect(rig.prompts.count(.celebration) == 0, "'Super gemacht!' moved to the end of the final test")
        #expect(!rig.vm.sessionEndScreenPresented, "the end screen follows the final test, not the third letter")
        #expect(!rig.vm.awaitingNextParticipant, "the set is not finished until the test is")
        #expect(rig.vm.studyNavigationHeld, "a chevron would walk the child out of the pause")
        let before = rig.vm.currentLetterName
        rig.vm.nextLetter()
        #expect(rig.vm.currentLetterName == before, "the chevron moved during the pause")
    }

    @Test("the pause lasts exactly the setting, and plays and loads nothing")
    func pauseLengthIsTheSetting() async {
        for seconds in [30.0, 45.0, 60.0] {
            let rig = FinalTestRig(pauseSeconds: seconds)
            await rig.finishTrainingOfEveryLetter()
            await rig.clock.waitForRequests(1)
            #expect(rig.clock.requests.first == seconds, "pause \(seconds): requested \(rig.clock.requests)")
            #expect(rig.vm.finalTestStage == .pause)
            #expect(rig.prompts.count(.finalIntro) == 0, "the intro played inside the pause")
            #expect(rig.vm.currentProbe == nil, "a test letter loaded inside the pause")
            rig.clock.close()
        }
    }

    @Test("the default pause is 45 seconds")
    func defaultPause() async {
        let rig = FinalTestRig()
        defer { rig.close() }
        await rig.finishTrainingOfEveryLetter()
        await rig.clock.waitForRequests(1)
        #expect(rig.clock.requests.first == 45)
    }

    @Test("when the pause ends the intro plays once, and the first glimpse follows it")
    func introThenFirstGlimpse() async {
        let rig = FinalTestRig()
        defer { rig.close() }
        await rig.finishTrainingOfEveryLetter()
        await rig.clock.waitForRequests(1)
        rig.clock.release(0)
        await rig.waitUntil { rig.vm.finalTestStage == .intro }
        #expect(rig.vm.finalTestStage == .intro)
        #expect(rig.prompts.count(.finalIntro) == 1)
        #expect(rig.vm.currentProbe == nil, "no letter is loaded while the intro plays")
        #expect(!FinalTestRules.acceptsTouch(rig.vm.finalTestStage))

        await rig.clock.waitForRequests(2)
        #expect(rig.clock.requests[1] == FinalTestRules.introFallbackSeconds)
        rig.clock.release(1)
        await rig.waitUntil { rig.vm.finalTestStage == .glimpse }
        #expect(rig.vm.finalTestStage == .glimpse)
        #expect(rig.prompts.count(.finalIntro) == 1, "the intro must play once")
    }

    @Test("the intro's own end starts the first glimpse a breath later (not at the fallback)")
    func introEndStartsTheGlimpse() async {
        let rig = FinalTestRig()
        defer { rig.close() }
        await rig.finishTrainingOfEveryLetter()
        await rig.clock.waitForRequests(1)
        rig.clock.release(0)
        await rig.waitUntil { rig.vm.finalTestStage == .intro }
        await rig.clock.waitForRequests(2)

        rig.vm.finalTestIntroEnded(cancelled: false)
        await rig.clock.waitForRequests(3)
        #expect(rig.clock.requests[2] == FinalTestRules.introEndToGlimpseSeconds)
        rig.clock.release(2)
        await rig.waitUntil { rig.vm.finalTestStage == .glimpse }
        #expect(rig.vm.finalTestStage == .glimpse)
    }

    @Test("a CUT intro starts nothing; the fallback still does")
    func cutIntroStartsNothing() async {
        let rig = FinalTestRig()
        defer { rig.close() }
        await rig.finishTrainingOfEveryLetter()
        await rig.clock.waitForRequests(1)
        rig.clock.release(0)
        await rig.waitUntil { rig.vm.finalTestStage == .intro }
        await rig.clock.waitForRequests(2)

        rig.vm.finalTestIntroEnded(cancelled: true)
        try? await Task.sleep(for: .milliseconds(60))
        #expect(rig.clock.requests.count == 2, "a cancelled recording scheduled a glimpse: \(rig.clock.requests)")
        #expect(rig.vm.finalTestStage == .intro)
    }

    @Test("the glimpse shows the first trained letter as a cold final-test probe, with its prompt, and hides after the setting")
    func glimpseLengthIsTheSetting() async {
        for seconds in [1.0, 2.0, 3.0] {
            let rig = FinalTestRig(glimpseSeconds: seconds)
            await rig.finishTrainingOfEveryLetter()
            await rig.passPauseAndIntro()
            #expect(rig.vm.finalTestStage == .glimpse)
            #expect(rig.vm.currentProbe == .finalTest)
            #expect(rig.vm.currentLetterName == rig.vm.visibleLetterNames[0], "the first test letter is the first trained one")
            #expect(rig.vm.showsReferenceGlyph, "the glimpse shows the plain glyph")
            #expect(rig.prompts.keys.last == .finalGlimpse, "'Merk ihn dir gut.' plays at the glimpse's start")
            await rig.clock.waitForRequests(3)
            #expect(rig.clock.requests[2] == seconds, "glimpse \(seconds): requested \(rig.clock.requests)")

            #expect(rig.vm.finalTestStage == .glimpse, "the glyph hid before its time")
            rig.clock.release(2)
            await rig.waitUntil { rig.vm.finalTestStage == .writing }
            #expect(rig.vm.finalTestStage == .writing)
            #expect(!rig.vm.showsReferenceGlyph, "the glyph stayed after the glimpse")
            #expect(rig.prompts.keys.last == ChildSpeechLibrary.phaseEntryPromptKey(.freeWrite),
                    "'Und jetzt ganz allein.' plays when the glyph hides")
            rig.clock.close()
        }
    }

    @Test("during the glimpse there is no guide, no start dots and no ring; touches are ignored")
    func glimpseIsThePlainGlyphAndTakesNoTouch() async {
        let rig = FinalTestRig()
        defer { rig.close() }
        await rig.finishTrainingOfEveryLetter()
        await rig.passPauseAndIntro()
        #expect(rig.vm.sessionBlockReason == nil, "precondition: a block would make 'ignored' vacuous")

        let plan = rig.vm.canvasDrawPlan
        #expect(!plan.showsGhost && !plan.showsStartDots && !plan.showsEndpointRing,
                "the glimpse draws scaffolding: \(plan)")

        rig.vm.beginTouch(at: CGPoint(x: 100, y: 100), t: 1)
        rig.vm.updateTouch(at: CGPoint(x: 150, y: 100), t: 1.1, canvasSize: rig.canvas)
        rig.vm.endTouch()
        #expect(rig.vm.activePath.isEmpty, "a stroke began during the glimpse")
        #expect(!rig.vm.touchDispatcher.isSingleTouchInteractionActive)
        #expect(!rig.vm.showsFinalTestCheck)
    }

    @Test("after the glimpse the canvas takes ink (the control for 'ignored'), still without a guide")
    func writingTakesInk() async {
        let rig = FinalTestRig()
        defer { rig.close() }
        await rig.finishTrainingOfEveryLetter()
        await rig.passPauseAndIntro()
        await rig.clock.waitForRequests(3)
        rig.clock.release(2)
        await rig.waitUntil { rig.vm.finalTestStage == .writing }

        let plan = rig.vm.canvasDrawPlan
        #expect(!plan.showsGhost && !plan.showsStartDots && !plan.showsEndpointRing)
        rig.vm.beginTouch(at: CGPoint(x: 100, y: 100), t: 1)
        #expect(rig.vm.touchDispatcher.isSingleTouchInteractionActive, "the same touch, accepted once writing")
        rig.vm.endTouch()
    }

    @Test("the check button appears after the first stroke; the 2 s quiet window does NOT end the letter")
    func checkButtonNotQuietWindow() async {
        let rig = FinalTestRig()
        defer { rig.close() }
        await rig.finishTrainingOfEveryLetter()
        await rig.passPauseAndIntro()
        await rig.clock.waitForRequests(3)
        rig.clock.release(2)
        await rig.waitUntil { rig.vm.finalTestStage == .writing }
        #expect(!rig.vm.showsFinalTestCheck, "the button was up before any stroke")

        rig.writeOneStroke()
        #expect(rig.vm.showsFinalTestCheck, "no check button after a stroke")
        #expect(!rig.vm.touchDispatcher.isFreeWriteAdvanceScheduled,
                "a lift scheduled the quiet window in the final test")
        // The window is 2.0 s; wait it out once.
        try? await Task.sleep(for: .milliseconds(2300))
        #expect(!rig.vm.didCompleteCurrentLetter, "the quiet window ended a final-test letter")
        #expect(rig.vm.finalTestStage == .writing)
        #expect(rig.vm.showsFinalTestCheck)
    }

    @Test("the check button ends the letter; the next test letter follows in training order")
    func checkEndsTheLetterAndAdvances() async {
        let rig = FinalTestRig()
        defer { rig.close() }
        await rig.finishTrainingOfEveryLetter()
        await rig.passPauseAndIntro()
        await rig.clock.waitForRequests(3)
        rig.clock.release(2)
        await rig.waitUntil { rig.vm.finalTestStage == .writing }

        // A tap on the button before any ink does nothing.
        rig.vm.finishFinalTestLetterTapped()
        #expect(!rig.vm.didCompleteCurrentLetter, "the check ended a letter with no ink")

        rig.writeOneStroke()
        rig.vm.finishFinalTestLetterTapped()
        await rig.waitUntil { rig.vm.isPhaseSessionComplete }
        #expect(rig.vm.isPhaseSessionComplete, "the check did not end the letter")

        rig.vm.advanceAfterCompletedStudyLetter()
        #expect(rig.vm.finalTestStage == .glimpse)
        #expect(rig.vm.currentProbe == .finalTest)
        #expect(rig.vm.currentLetterName == rig.vm.visibleLetterNames[1], "the second test letter is the second trained one")
        #expect(!rig.vm.showsFinalTestCheck, "the button carried over to the next letter")
        #expect(rig.prompts.count(.finalGlimpse) == 2)
    }

    @Test("the whole session: three trained letters, pause, intro, three test letters in training order, 'Super gemacht!', end screen, set held")
    func wholeFlowOrder() async {
        let rig = FinalTestRig(pauseSeconds: 30, glimpseSeconds: 1.5)
        defer { rig.close() }
        let pool = rig.vm.visibleLetterNames
        await rig.finishTrainingOfEveryLetter()
        #expect(rig.vm.finalTestStage == .pause)

        await rig.passPauseAndIntro()
        var testedInOrder: [String] = []
        for n in 0..<pool.count {
            await rig.clock.waitForRequests(3 + n)
            #expect(rig.vm.finalTestStage == .glimpse)
            #expect(rig.vm.currentProbe == .finalTest)
            testedInOrder.append(rig.vm.currentLetterName)
            #expect(rig.clock.requests[2 + n] == 1.5)
            rig.clock.release(2 + n)
            await rig.waitUntil { rig.vm.finalTestStage == .writing }
            rig.writeOneStroke(t0: 1000 + Double(n) * 10)
            rig.vm.finishFinalTestLetterTapped()
            await rig.waitUntil { rig.vm.isPhaseSessionComplete }
            if n < pool.count - 1 {
                #expect(!rig.vm.sessionEndScreenPresented, "the end screen came before the last test letter")
                #expect(rig.prompts.count(.celebration) == 0, "'Super gemacht!' came before the last test letter")
            }
            rig.vm.advanceAfterCompletedStudyLetter()
        }

        #expect(testedInOrder == pool, "tested \(testedInOrder), trained \(pool)")
        #expect(rig.vm.finalTestStage == .inactive)
        #expect(rig.prompts.count(.celebration) == 1, "'Super gemacht!' plays once, after the last test letter")
        #expect(rig.vm.awaitingNextParticipant, "the device waits for the next child")
        #expect(rig.vm.sessionEndScreenPresented, "the end screen fires after the final test")
        #expect(rig.prompts.keys.last == .celebration || rig.prompts.count(.celebration) == 1)
        // The order of the prompts the child heard, from the pause on.
        let heard = rig.prompts.keys.drop { $0 != .finalIntro }
        #expect(heard.filter { $0 == .finalIntro || $0 == .finalGlimpse || $0 == .celebration }.map(\.rawValue)
                == ["final_intro", "final_glimpse", "final_glimpse", "final_glimpse", "celebration"])
        // Held for the next child: no chevron, no restart.
        let before = rig.vm.currentLetterName
        rig.vm.nextLetter()
        #expect(rig.vm.currentLetterName == before)
    }

    @Test("a final-test letter records ONE row, no retry, and no feedback toast, however poor the writing")
    func noRetryNoFeedback() async {
        let rig = FinalTestRig()
        defer { rig.close() }
        await rig.finishTrainingOfEveryLetter()
        await rig.passPauseAndIntro()
        await rig.clock.waitForRequests(3)
        rig.clock.release(2)
        await rig.waitUntil { rig.vm.finalTestStage == .writing }

        let promptsBefore = rig.prompts.keys.count
        rig.writeOneStroke()
        rig.vm.finishFinalTestLetterTapped()
        await rig.waitUntil { rig.vm.isPhaseSessionComplete }

        let rows = rig.store.snapshot.phaseSessionRecords.filter { $0.probe == "finalTest" }
        #expect(rows.count == 1, "expected one final-test row, got \(rows.count)")
        #expect(rows.first?.completed == true, "a final-test letter must be recorded as completed")
        #expect(!rig.prompts.keys.dropFirst(promptsBefore).contains(.retryCue), "a retry cue played")
        let praise: [PromptPlayer.PromptKey] = [.praise0, .praise1, .praise2, .praise3, .praise4]
        #expect(Set(rig.prompts.keys.dropFirst(promptsBefore)).isDisjoint(with: praise), "praise was spoken")
        #expect(rig.vm.currentProbe == .finalTest && rig.vm.didCompleteCurrentLetter,
                "the letter was reopened for another attempt")
    }

    @Test("a refused test letter is a fault and leaves the session, never a quiet skip")
    func refusedLetterFails() async {
        let rig = FinalTestRig()
        defer { rig.close() }
        await rig.finishTrainingOfEveryLetter()
        // An untrained letter cannot be tested.
        rig.vm.cancelFinalTest()
        #expect(rig.vm.startColdProbe(letter: "L", kind: .finalTest) != nil,
                "the final test accepted a letter the child was not trained on")
    }

    @Test("'Nächstes Kind' during the pause drops the test and clears the screen")
    func nextChildDropsTheTest() async {
        let rig = FinalTestRig()
        defer { rig.close() }
        await rig.finishTrainingOfEveryLetter()
        #expect(rig.vm.finalTestStage == .pause)
        _ = rig.vm.resetForNewParticipant()
        #expect(rig.vm.finalTestStage == .inactive)
        #expect(!rig.vm.awaitingNextParticipant)
        // The released pause sleeper must not resurrect the test.
        rig.clock.release(0)
        try? await Task.sleep(for: .milliseconds(80))
        #expect(rig.vm.finalTestStage == .inactive, "a cancelled pause woke the test of the previous child")
        #expect(rig.prompts.count(.finalIntro) == 0)
    }
}

// MARK: - No arm sound

@MainActor
@Suite struct FinalTestSilenceTests {

    /// A whole final-test letter in `arm`, measuring the engine from the pause
    /// on: the sound arms play in training (the control) and not in the test.
    private func engineEventsDuringTestLetter(arm: PilotAudioCondition) async -> (before: Int, after: Int, playing: Bool, blocked: String?) {
        let rig = FinalTestRig(arm: arm)
        defer { rig.close() }
        await rig.finishTrainingOfEveryLetter()
        await rig.passPauseAndIntro()
        await rig.clock.waitForRequests(3)
        let blocked = rig.vm.sessionBlockReason
        rig.clock.release(2)
        await rig.waitUntil { rig.vm.finalTestStage == .writing }
        let before = rig.audio.plays.count
        rig.writeOneStroke()
        return (before, rig.audio.plays.count, rig.audio.isPlaying, blocked)
    }

    @Test("no arm sound while writing the final test, in every arm", arguments: PilotAudioCondition.allCases)
    func noArmSound(arm: PilotAudioCondition) async {
        let result = await engineEventsDuringTestLetter(arm: arm)
        #expect(result.blocked == nil, "precondition: \(arm) is blocked (\(result.blocked ?? "")), so 'silent' proves nothing")
        #expect(result.after == result.before, "\(arm): the engine started \(result.after - result.before) sound(s) while writing from memory")
        #expect(!result.playing, "\(arm): the engine is playing during the final test")
    }

    @Test("a final-test probe is not refused for a missing arm recording (it plays none); a pretest still is")
    func silentProbeIsNotRefusedForMissingArmAudio() async {
        let rig = FinalTestRig(arm: .phoneme)
        defer { rig.close() }
        // The same three letters, with no phoneme takes: a sound-arm probe would refuse.
        rig.vm.letters = rig.vm.letters.map { asset in
            LetterAsset(id: asset.id, name: asset.name, baseLetter: asset.baseLetter, letterCase: asset.letterCase,
                        audioFiles: [], strokes: asset.strokes, phonemeAudioFiles: [])
        }
        #expect(rig.vm.startColdProbe(letter: "A", kind: .pretest) != nil,
                "control: with no phoneme take the arm's pretest must be refused")
        #expect(rig.vm.startColdProbe(letter: "A", kind: .finalTest) == nil,
                "the silent final test was refused for a missing arm recording")
    }
}

// MARK: - The export

@MainActor
@Suite struct FinalTestExportTests {

    @Test("a final-test row records planned and MEASURED glimpse, planned pause and the hide-to-touch latency")
    func rowCarriesTheFacts() async throws {
        let rig = FinalTestRig(pauseSeconds: 35, glimpseSeconds: 2.0)
        defer { rig.close() }
        await rig.finishTrainingOfEveryLetter()
        await rig.passPauseAndIntro()
        await rig.clock.waitForRequests(3)

        // The glyph is shown for 2.5 s on the monotonic clock although 2.0 was planned.
        rig.now.seconds += 2.5
        rig.clock.release(2)
        await rig.waitUntil { rig.vm.finalTestStage == .writing }
        // The first touch comes 0.75 s after the glyph hid.
        rig.now.seconds += 0.75
        rig.writeOneStroke()
        rig.vm.finishFinalTestLetterTapped()
        await rig.waitUntil { rig.vm.isPhaseSessionComplete }

        let rows = rig.store.snapshot.phaseSessionRecords.filter { $0.probe == "finalTest" }
        let row = try #require(rows.first, "no final-test row was written")
        #expect(row.glimpseSecondsPlanned == 2.0)
        #expect(row.pauseSecondsPlanned == 35)
        let shown = try #require(row.glimpseSecondsShown, "the shown time was not measured")
        #expect(abs(shown - 2.5) < 1e-6, "shown \(shown), planned 2.0: the row must carry the measurement")
        let latency = try #require(row.glimpseHiddenToFirstTouchSeconds, "the latency was not measured")
        #expect(abs(latency - 0.75) < 1e-6, "latency \(latency)")

        // Training rows carry none of it.
        let training = rig.store.snapshot.phaseSessionRecords.filter { $0.probe == nil }
        #expect(!training.isEmpty, "precondition: training rows exist")
        for t in training {
            #expect(t.glimpseSecondsPlanned == nil && t.glimpseSecondsShown == nil
                    && t.pauseSecondsPlanned == nil && t.glimpseHiddenToFirstTouchSeconds == nil,
                    "a training row carries final-test fields")
        }
    }

    @Test("no touch: the latency is empty, never zero")
    func noTouchNoLatency() async throws {
        let rig = FinalTestRig()
        defer { rig.close() }
        await rig.finishTrainingOfEveryLetter()
        await rig.passPauseAndIntro()
        await rig.clock.waitForRequests(3)
        rig.clock.release(2)
        await rig.waitUntil { rig.vm.finalTestStage == .writing }
        #expect(rig.vm.finalTestFacts?.glimpseHiddenToFirstTouchSeconds == nil)
        #expect(rig.vm.finalTestFacts?.glimpseSecondsShown != nil)
    }

    private func csvText(_ snap: DashboardSnapshot) -> String {
        String(data: ParentDashboardExporter.csvData(from: snap, participantId: UUID(),
                                                     progress: [:], enrolledAt: nil), encoding: .utf8)!
    }

    @Test("the four columns are appended LAST in the phase table and carry the row's values; other rows are empty")
    func columnsReachTheCSV() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("final-test-csv-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = JSONParentDashboardStore(fileURL: url)
        func record(probe: String?, facts: FinalTestFacts?) {
            store.recordPhaseSession(
                letter: "A", phase: "freeWrite", completed: true, score: 0.5, schedulerPriority: 0,
                condition: .threePhase, audioCondition: .silent, assessment: nil, recognition: nil,
                inputDevice: "finger", rawTraceID: nil, trainedSubset: "AFI", phaseDurationSeconds: nil,
                frechetDistance: nil, checkpointCoverage: nil, spatialDeviation: nil, strokeCount: nil,
                strokeOrder: nil, reversedStrokeCount: nil, studyMode: true, probe: probe,
                comparisonConfiguration: nil, spatialDeviationRaw: nil,
                context: PhaseRowContext(finalTest: facts))
        }
        record(probe: nil, facts: nil)
        record(probe: "finalTest", facts: FinalTestFacts(glimpseSecondsPlanned: 3.0, glimpseSecondsShown: 2.5,
                                                         pauseSecondsPlanned: 45, glimpseHiddenToFirstTouchSeconds: 1.5))
        await store.flush()

        let block = try #require(DelimitedExport.block(in: csvText(store.snapshot), headerPrefix: "letter,phase,completed"))
        #expect(Array(block.header.suffix(5)) == ["glimpseSecondsPlanned", "glimpseSecondsShown",
                                                  "pauseSecondsPlanned", "glimpseHiddenToFirstTouchSeconds",
                                                  "glimpseRestarts"],
                "the r27 columns must be the newest, last: \(block.header.suffix(6))")
        #expect(block.header.firstIndex(of: "attemptCheckExtraReversals")! < block.header.firstIndex(of: "glimpseSecondsPlanned")!)
        let probeColumn = try #require(block.header.firstIndex(of: "probe"))
        let rows = block.rows
        let training = try #require(rows.first { $0[probeColumn].isEmpty })
        let test = try #require(rows.first { $0[probeColumn] == "finalTest" })
        #expect(Array(training.suffix(5)) == ["", "", "", "", ""])
        #expect(Array(test.suffix(5)) == ["3.000", "2.500", "45.000", "1.500", "0"], "\(Array(test.suffix(5)))")
    }
}
