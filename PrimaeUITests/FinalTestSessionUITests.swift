// FinalTestSessionUITests.swift
// PrimaeUITests
//
// ONE WHOLE STUDY SESSION PER ARM, end to end, checking what is on screen and
// what is heard at every transition (2026-11-23, David: "you should catch
// that stuff in your testing without me sending a video").
//
// The flow, per arm (phoneme / spatial / silent, set through the arm
// override): enrol through the rail, the three training letters drawn along
// their real strokes (`LetterTracer`; never a straight drag), the silent
// bubble pause, the final test's intro, each test letter's glimpse, writing
// and check, and the end screen.
//
// WHAT IS CHECKED, AND WITH WHAT INSTRUMENT:
//  - The app's DEBUG-only hook (`-tracingGeometryHook`) keeps a TIMELINE of
//    the session (`TracingSessionTimeline`, sampled every 0.2 s): final-test
//    stage, chrome shown, the ink layers the tracing canvas actually STROKED
//    in its latest frame (`TracingInkDrawProbe`, recorded inside the Canvas
//    closure), glyph shown, pause / end screen / check button up. The
//    assertions read the whole timeline after the session, so they do not
//    race the transitions.
//  - The accessibility tree itself: while the end screen comes up, the
//    practice chrome (letter pill, phase dots, chevrons, the observe button)
//    must not be in it.
//  - Screenshots at every edge (`XCTAttachment`, `.keepAlways`), and a pixel
//    comparison of the canvas region: the intro (bubbles gone, no test letter
//    yet) must look like the empty canvas of a test letter's writing stage,
//    and a glimpse must not.
//  - AUDIO, measured, not "playback requested": the run is launched with
//    `-popCapture`, whose tap on the main mixer feeds a peak per hook tick
//    into the timeline, attributed to (letter, phase, probe, stage). The arm
//    sound must be present in the sound arms' training, absent in the silent
//    arm, and absent in every arm from the bubble pause to the end screen.
//    Recorded prompts (AVAudioPlayer, NOT through the mixer) are logged by
//    `PromptPlayer` as play / end (played to its end, the player's own
//    report) / cut; the final test's prompt sequence is asserted. The same
//    run also leaves Documents/popcap/e2e_<arm>-<time>/ (mixer.wav,
//    events.tsv with `hook.state` lines) in the app container for offline
//    review.
//
// The two defects this was written against (David's recordings, 2026-11-23):
//  Bug 1: the last training letter's free-write ink was uncovered when the
//         bubbles ended and stayed until the first test letter loaded.
//  Bug 2: the badge, page dots, chevrons and the test letter's ink came back
//         for about 1.5 s while the end screen faded in.
//
// Physical iPad only (not in CI), like the rest of PrimaeUITests. One test
// method per arm, so a run fits the tool timeout; each takes about 4 min.

import XCTest
import UIKit
import Foundation

final class FinalTestSessionUITests: XCTestCase {

    override func setUpWithError() throws {
        // The flow steps `return` on their own failures; the edge checks are
        // all reported, so one run shows every defect.
        continueAfterFailure = true
    }

    @MainActor func testPhonemeSession() { runSession(arm: "phoneme") }
    @MainActor func testSpatialSession() { runSession(arm: "spatial") }
    @MainActor func testSilentSession()  { runSession(arm: "silent") }

    /// The trained set, walked in the fixed study order I, F, A.
    private let subset = "AFI"
    /// The shortest bubble pause the domain allows (30-60 s).
    private let pauseSeconds = 30

    // MARK: - The session

    @MainActor
    private func runSession(arm: String) {
        let app = XCUIApplication.primaeUnderTest()
        app.launchArguments += [
            LetterTracer.launchArgument,
            "-popCapture", "-popCaptureTag", "e2e_\(arm)",
            "-de.flamingistan.primae.audioConditionOverride", arm,
            "-de.flamingistan.primae.trainedSubsetOverride", subset,
            "-de.flamingistan.primae.comparison.pauseSeconds", "\(pauseSeconds)",
        ]
        app.launch()
        guard app.enrolNextChildViaRail() else { return XCTFail("[\(arm)] the child must be enrolled through the rail") }
        XCTAssertTrue(app.descendants(matching: .any)["newChildReadyToast"].waitForExistence(timeout: 5),
                      "[\(arm)] the ready toast must appear once the child is enrolled")
        var last: TracingHookSnapshot?
        if let s = LetterTracer.waitForSnapshot(app, timeout: 10, last: &last, where: { _ in true }), s.parked {
            let observe = app.descendants(matching: .any)["Beobachtungsphase"]
            if observe.waitForExistence(timeout: 5) { observe.tap() }
        }

        // 1. Training: three letters, guided then free-write, real strokes.
        var trained: [String] = []
        for round in 1...3 {
            guard let guided = LetterTracer.waitForSnapshot(app, timeout: 60, last: &last, where: {
                $0.phase == "guided" && !$0.strokes.isEmpty && !$0.blocked && !trained.contains($0.letter)
            }) else {
                return XCTFail("[\(arm)] training letter \(round) never reached guided after \(trained): \(last?.summary ?? "no hook")")
            }
            let letter = guided.letter
            Thread.sleep(forTimeInterval: 1.0)
            LetterTracer.traceLetter(guided, in: app)
            guard let fw = LetterTracer.waitForSnapshot(app, timeout: 8, last: &last, where: {
                $0.letter == letter && $0.phase == "freeWrite" && $0.checkpointsHit == 0
            }) else {
                return XCTFail("[\(arm)] \(letter): guided did not advance to freeWrite: \(last?.summary ?? "no hook")")
            }
            Thread.sleep(forTimeInterval: 1.0)
            LetterTracer.traceLetter(fw, in: app)
            if round == 3 { attach("T\(round)-\(letter)-freewrite-ink") }
            _ = LetterTracer.waitForCompletion(app, letter: letter, probe: nil)
            trained.append(letter)
        }

        // 2. The bubble pause.
        guard let pause = waitForState(app, timeout: 15, where: { $0.stage == "pause" }) else {
            return XCTFail("[\(arm)] the bubble pause never started after \(trained): \(stateSummary(app))")
        }
        Thread.sleep(forTimeInterval: 0.6)
        attach("P1-pause-start")
        XCTAssertTrue(app.descendants(matching: .any)["finalTestPause"].exists,
                      "[\(arm)] the bubble pause view must be on screen in stage pause")
        XCTContext.runActivity(named: "pause started at t=\(pause.timeline.last?.t ?? -1)") { _ in }

        // 3. The intro: bubbles gone, no test letter yet. Bug 1's window.
        guard waitForState(app, timeout: Double(pauseSeconds) + 15, where: { $0.stage == "intro" }) != nil else {
            return XCTFail("[\(arm)] the pause never ended into the intro: \(stateSummary(app))")
        }
        Thread.sleep(forTimeInterval: 0.5)   // the pause view's 0.25 s fade
        var introShots: [(name: String, image: UIImage)] = []
        for i in 0..<3 {
            guard let s = currentState(app), s.stage == "intro" else { break }
            introShots.append(("P2-intro-\(i)", attach("P2-intro-\(i)").image))
            Thread.sleep(forTimeInterval: 0.3)
        }

        // 4. The test letters: glimpse, writing, check.
        var tested: [String] = []
        var emptyCanvas: (name: String, image: UIImage)?
        var canvasRect = CGRect.zero
        // Controls drawn over the canvas while writing (the hand button) are
        // not canvas content: masked out of every canvas diff.
        var overlayControls: [CGRect] = []
        var endChrome: [String] = []
        var endChromeSeen = Set<String>()
        for k in 1...3 {
            guard let glimpse = waitForState(app, timeout: 15, where: {
                $0.stage == "glimpse" && $0.probe == "finalTest" && !tested.contains($0.letter)
            }) else {
                return XCTFail("[\(arm)] test letter \(k) never showed its glimpse after \(tested): \(stateSummary(app))")
            }
            let letter = glimpse.letter
            Thread.sleep(forTimeInterval: 0.6)
            let glimpseShot = attach("F\(k)-\(letter)-glimpse").image
            if let s = currentState(app), s.stage == "glimpse" {
                XCTAssertTrue(s.glyph, "[\(arm)] \(letter): the glimpse must show the glyph")
                XCTAssertFalse(s.check, "[\(arm)] \(letter): no check button during the glimpse")
            }
            guard waitForState(app, timeout: 10, where: { $0.stage == "writing" && $0.letter == letter }) != nil else {
                return XCTFail("[\(arm)] \(letter): the glimpse never hid: \(stateSummary(app))")
            }
            Thread.sleep(forTimeInterval: 0.6)
            let hiddenShot = attach("F\(k)-\(letter)-hidden").image
            if let s = currentState(app) {
                XCTAssertFalse(s.glyph, "[\(arm)] \(letter): the glyph must be hidden while writing")
                XCTAssertEqual(s.inkLayers, 0, "[\(arm)] \(letter): the writing canvas must start empty (ink layers drawn)")
                XCTAssertFalse(s.check, "[\(arm)] \(letter): no check button before the first stroke")
                canvasRect = s.canvasFrame
            }
            if overlayControls.isEmpty { overlayControls = controlsOver(canvasRect, in: app) }
            XCTAssertFalse(app.descendants(matching: .any)["finalTestCheck"].exists,
                           "[\(arm)] \(letter): the check button must not be up before the child writes")
            if emptyCanvas == nil { emptyCanvas = ("F\(k)-\(letter)-hidden", hiddenShot) }
            let glimpseDiff = canvasDiff(glimpseShot, hiddenShot, canvas: canvasRect, masking: overlayControls, app: app)
            XCTContext.runActivity(named: "\(letter) glimpse vs hidden: \(glimpseDiff) changed canvas samples") { _ in }
            XCTAssertGreaterThan(glimpseDiff, 500, "[\(arm)] \(letter): the glimpse glyph must be visible (canvas differs from the hidden state)")

            guard let ready = LetterTracer.waitForSnapshot(app, timeout: 5, last: &last, where: {
                $0.letter == letter && $0.probe == "finalTest" && !$0.strokes.isEmpty
            }) else {
                return XCTFail("[\(arm)] \(letter): no strokes to trace in the final test: \(last?.summary ?? "no hook")")
            }
            LetterTracer.traceLetter(ready, in: app)
            let check = app.descendants(matching: .any)["finalTestCheck"]
            guard check.waitUntilHittable(timeout: 5) else {
                return XCTFail("[\(arm)] \(letter): the check button never came up after writing: \(stateSummary(app))")
            }
            attach("F\(k)-\(letter)-written")
            check.tap()
            tested.append(letter)

            if k == 3 {
                // 5. The end: the end screen fades in (lead 1.2 s). Bug 2's
                // window: nothing of the practice screen may come back.
                let t0 = Date()
                var i = 0
                while Date().timeIntervalSince(t0) < 4.0 {
                    let ms = Int(Date().timeIntervalSince(t0) * 1000)
                    attach(String(format: "END-%02d-t%04dms", i, ms))
                    for name in chromePresent(app) where endChromeSeen.insert(name).inserted {
                        endChrome.append("\(name) @\(ms)ms")
                    }
                    i += 1
                }
            }
        }
        XCTAssertEqual(tested, trained, "[\(arm)] the final test must ask the trained letters in training order")

        let endScreen = app.descendants(matching: .any)["sessionEndScreen"]
        XCTAssertTrue(endScreen.waitForExistence(timeout: 10), "[\(arm)] the end screen must appear after the last test letter")
        Thread.sleep(forTimeInterval: 2.0)
        attach("END-rest")
        for name in chromePresent(app) where endChromeSeen.insert(name).inserted {
            endChrome.append("\(name) @rest")
        }
        XCTAssertTrue(endChrome.isEmpty,
                      "[\(arm)] Bug 2: practice chrome in the accessibility tree while the end screen came up: \(endChrome)")

        // 6. The intro must look like an empty test canvas (Bug 1, pixels).
        if let empty = emptyCanvas {
            for shot in introShots {
                let diff = canvasDiff(shot.image, empty.image, canvas: canvasRect, masking: overlayControls, app: app)
                XCTContext.runActivity(named: "\(shot.name) vs \(empty.name): \(diff) changed canvas samples") { _ in }
                XCTAssertGreaterThanOrEqual(diff, 0, "[\(arm)] \(shot.name): the screenshot does not map onto the app's screen")
                XCTAssertLessThan(diff, 200,
                    "[\(arm)] Bug 1 (pixels): the intro canvas (\(shot.name)) is not empty, \(diff) samples differ from \(empty.name)")
            }
        }

        // 7. The whole session, from the timeline.
        guard let final = currentState(app) else { return XCTFail("[\(arm)] the hook is gone at the end") }
        attachText("hook-final.json", final.raw)
        assertScreenEdges(final, arm: arm)
        assertGlimpseFrames(final, arm: arm, tested: tested)
        assertAudio(final, arm: arm, trained: trained)
    }

    // MARK: - Screen edges, from the timeline

    private func assertScreenEdges(_ s: SessionState, arm: String) {
        let tl = s.timeline
        XCTContext.runActivity(named: "timeline (\(tl.count) states)") { activity in
            let text = tl.map { $0.line }.joined(separator: "\n")
            let a = XCTAttachment(string: text); a.name = "timeline.txt"; a.lifetime = .keepAlways
            activity.add(a)
        }
        // The ink readout is the canvas's LATEST frame, and the hook samples
        // the model on its own render, which runs before the canvas redraws
        // for the same change. So the first entry after a stage (or end
        // screen) flip can still carry the previous frame's ink. Measured
        // on the iPad (2026-11-23): such an entry is superseded by the same
        // state with the redrawn ink 0.02 s later. An entry counts as ink on
        // screen unless the very next entry is that redraw (same state,
        // ink 0) within one hook tick (0.25 s). A stale canvas that is NOT
        // redrawn (the defect) never gets that successor, so it still fails.
        let preRedraw: Set<Int> = Set(tl.indices.filter { i in
            guard i > 0, i + 1 < tl.count, tl[i].ink > 0 else { return false }
            let prev = tl[i - 1], cur = tl[i], next = tl[i + 1]
            let flipped = prev.stage != cur.stage || prev.end != cur.end || prev.pause != cur.pause
            let sameButInk = next.stage == cur.stage && next.end == cur.end && next.pause == cur.pause
                && next.chrome == cur.chrome && next.letter == cur.letter
            return flipped && sameButInk && next.ink == 0 && next.t - cur.t <= 0.25
        })
        if !preRedraw.isEmpty {
            XCTContext.runActivity(named: "pre-redraw samples (previous frame's ink, redrawn within a tick): "
                + preRedraw.sorted().map { "\(tl[$0].line) -> t=\(tl[$0 + 1].t) ink=\(tl[$0 + 1].ink)" }
                    .joined(separator: " | ")) { _ in }
        }
        let onScreen = tl.indices.filter { !preRedraw.contains($0) }.map { tl[$0] }
        // Bug 1: no ink drawn from the pause until a test letter is loaded.
        let inkInPauseOrIntro = onScreen.filter { ($0.stage == "pause" || $0.stage == "intro") && $0.ink > 0 }
        XCTAssertTrue(inkInPauseOrIntro.isEmpty,
            "[\(arm)] Bug 1: ink drawn on the canvas during the final test's pause/intro: "
            + inkInPauseOrIntro.prefix(4).map { $0.line }.joined(separator: " | "))
        // Bug 2: nothing of the practice screen while the end screen is up.
        let endLeaks = tl.indices.filter { tl[$0].end && (tl[$0].chrome || (tl[$0].ink > 0 && !preRedraw.contains($0))) }
            .map { tl[$0] }
        XCTAssertTrue(endLeaks.isEmpty,
            "[\(arm)] Bug 2: chrome or ink on screen while the end screen comes up: "
            + endLeaks.prefix(4).map { $0.line }.joined(separator: " | "))
        // The test runs chrome-free from the pause on.
        let chromeInTest = tl.filter { ["pause", "intro", "glimpse", "writing"].contains($0.stage) && $0.chrome }
        XCTAssertTrue(chromeInTest.isEmpty, "[\(arm)] chrome on screen inside the final test: "
            + chromeInTest.prefix(4).map { $0.line }.joined(separator: " | "))
        // The glyph shows in the glimpse and nowhere else in the test.
        let glyphOutsideGlimpse = tl.filter { $0.probe == "finalTest" && $0.stage != "glimpse" && $0.glyph }
        XCTAssertTrue(glyphOutsideGlimpse.isEmpty, "[\(arm)] the test glyph shows outside its glimpse: "
            + glyphOutsideGlimpse.prefix(4).map { $0.line }.joined(separator: " | "))
        let glimpses = tl.filter { $0.stage == "glimpse" }
        XCTAssertFalse(glimpses.isEmpty, "[\(arm)] no glimpse in the timeline")
        XCTAssertTrue(glimpses.allSatisfy { $0.glyph && !$0.check },
                      "[\(arm)] a glimpse without its glyph, or with the check: " + glimpses.map { $0.line }.joined(separator: " | "))
        // The check only while writing.
        let checkElsewhere = tl.filter { $0.check && $0.stage != "writing" }
        XCTAssertTrue(checkElsewhere.isEmpty, "[\(arm)] check button outside writing: "
            + checkElsewhere.prefix(4).map { $0.line }.joined(separator: " | "))
        // The pause view only in the pause.
        let pauseElsewhere = tl.filter { $0.pause != ($0.stage == "pause") }
        XCTAssertTrue(pauseElsewhere.isEmpty, "[\(arm)] the pause view out of step with the stage: "
            + pauseElsewhere.prefix(4).map { $0.line }.joined(separator: " | "))
    }

    // MARK: - The glimpse, frame by frame

    /// A glimpse shows the current letter's glyph and nothing else: no frame
    /// the canvas draws in a glimpse may stroke ink, the FIRST one above all
    /// (the previous letter's ink must not flash up as the glyph appears).
    /// Read from the canvas's own frame log (`TracingInkDrawProbe`), recorded
    /// inside the draw closure, so a frame is judged by what it drew, not by
    /// a model sample paired with the frame before (the timeline's limit,
    /// see `assertScreenEdges`).
    ///
    /// MEASURED 2026-11-24 on the physical iPad (Debug-Study), one run per
    /// arm: every glimpse frame of I, F and A drew the glyph and ink=0 in the
    /// phoneme, spatial and silent arms; the first one came 16-26 ms after
    /// the model entered `.glimpse`. The "previous letter's ink for up to
    /// ~0.16 s" reading came from the TIMELINE: the hook tick that first sees
    /// `stage=glimpse` reads `TracingInkDrawProbe.latest`, the ink of the last
    /// frame drawn, which can still be the previous letter's writing frame
    /// (e.g. `t=119.72 F stage=glimpse ink=1` against a frame log whose first
    /// F glimpse frame at t=119.721 has ink=0). It is instrument lag, not
    /// a frame the child saw. Kept as a regression guard.
    ///
    /// Mutation check (same day): removing `freeWriteRecorder.clearAll()`
    /// from `load(letter:)` ALONE stays green, because a test letter
    /// lands in free writing and `freeWriteRecorder.startSession()` empties
    /// the same buffers. With both removed this assertion went RED for all
    /// three letters (first glimpse frame ink=1).
    private func assertGlimpseFrames(_ s: SessionState, arm: String, tested: [String]) {
        XCTContext.runActivity(named: "canvas frames (\(s.frames.count) content changes)") { activity in
            let a = XCTAttachment(string: s.frames.map { $0.line }.joined(separator: "\n"))
            a.name = "frames.txt"; a.lifetime = .keepAlways
            activity.add(a)
        }
        XCTAssertFalse(s.frames.isEmpty, "[\(arm)] the canvas frame log is empty (probe not armed?)")
        for letter in tested {
            let glimpse = s.frames.filter { $0.stage == "glimpse" && $0.letter == letter }
            guard let first = glimpse.first else {
                XCTFail("[\(arm)] \(letter): no canvas frame was drawn in its glimpse"); continue
            }
            let modelAt = s.stageChanges.first { $0.stage == "glimpse" && $0.letter == letter }?.t
            XCTContext.runActivity(named: "[\(arm)] \(letter) first glimpse frame: \(first.line); "
                + "model entered glimpse at t=\(modelAt.map { "\($0)" } ?? "?")") { _ in }
            XCTAssertTrue(first.glyph, "[\(arm)] \(letter): the first glimpse frame must draw the glyph: \(first.line)")
            XCTAssertEqual(first.ink, 0,
                "[\(arm)] \(letter): the FIRST glimpse frame strokes ink (the previous letter's): \(first.line)")
            let inked = glimpse.filter { $0.ink != 0 }
            XCTAssertTrue(inked.isEmpty, "[\(arm)] \(letter): glimpse frames stroke ink: "
                + inked.prefix(4).map { $0.line }.joined(separator: " | "))
        }
    }

    // MARK: - Audio

    private func assertAudio(_ s: SessionState, arm: String, trained: [String]) {
        XCTContext.runActivity(named: "audio segments (\(s.audio.count)) and prompts (\(s.prompts.count))") { activity in
            let a = XCTAttachment(string: s.audio.map { $0.line }.joined(separator: "\n"))
            a.name = "audio-segments.txt"; a.lifetime = .keepAlways
            activity.add(a)
            let p = XCTAttachment(string: s.prompts.map { "\($0.t)\t\($0.kind)\t\($0.key)\t\($0.stage)" }.joined(separator: "\n"))
            p.name = "prompts.txt"; p.lifetime = .keepAlways
            activity.add(p)
        }
        guard s.audioMeasured else {
            return XCTFail("[\(arm)] the mixer was not measured (PopCapture's tap is not installed)")
        }
        let inTest: (SessionState.AudioSeg) -> Bool = { $0.stage != "inactive" || $0.probe == "finalTest" }
        // The arm's sound, training only.
        for letter in trained {
            let training = s.audio.filter { $0.letter == letter && $0.probe.isEmpty && !inTest($0) }
            let loud: Int = training.map { $0.settledLoud }.reduce(0, +)
            let observe: Int = training.filter { $0.phase == "observe" }.map { $0.settledLoud }.reduce(0, +)
            let guided: Int = training.filter { $0.phase == "guided" }.map { $0.settledLoud }.reduce(0, +)
            XCTContext.runActivity(named: "[\(arm)] \(letter) training: loud ticks observe=\(observe) guided=\(guided) all=\(loud)") { _ in }
            switch arm {
            case "silent":
                XCTAssertEqual(loud, 0, "[\(arm)] \(letter): the silent arm's training must be silent at the mixer: "
                    + training.map { $0.line }.joined(separator: " | "))
            default:
                XCTAssertGreaterThan(observe, 0, "[\(arm)] \(letter): no arm sound measured during observe: "
                    + training.map { $0.line }.joined(separator: " | "))
                XCTAssertGreaterThan(guided, 0, "[\(arm)] \(letter): no arm sound measured while tracing guided: "
                    + training.map { $0.line }.joined(separator: " | "))
            }
        }
        // No arm sound from the pause to the end screen, in any arm.
        let testLoud = s.audio.filter { inTest($0) && $0.settledLoud > 0 }
        XCTAssertTrue(testLoud.isEmpty, "[\(arm)] arm sound measured in the final test: "
            + testLoud.map { $0.line }.joined(separator: " | "))

        // The prompts from the pause on: none in the pause, then the intro,
        // a glimpse phrase and a writing phrase per letter, the celebration.
        guard let pauseStart = s.timeline.first(where: { $0.stage == "pause" })?.t,
              let introStart = s.timeline.first(where: { $0.stage == "intro" })?.t else {
            return XCTFail("[\(arm)] no pause/intro in the timeline")
        }
        // By the model's stage AT the play call: the render-sampled timeline
        // lags the pause -> intro change by a frame, and the intro prompt is
        // played in that same transition.
        let duringPause = s.prompts.filter { $0.kind == "play" && $0.stage == "pause" }
        XCTAssertTrue(duringPause.isEmpty, "[\(arm)] the bubble pause must be silent, played: \(duringPause.map { $0.key })")
        let plays = s.prompts.filter { $0.kind == "play" && $0.t >= pauseStart }.map { $0.key }
        let expected = ["final_intro"] + Array(repeating: ["final_glimpse", "phase_freewrite"], count: trained.count).flatMap { $0 }
            + ["celebration"]
        XCTAssertEqual(plays, expected, "[\(arm)] the final test's prompt sequence")
        let missing = s.prompts.filter { $0.kind == "missing" }
        XCTAssertTrue(missing.isEmpty, "[\(arm)] recorded prompts missing: \(missing.map { $0.key })")
        for key in ["final_intro", "celebration"] {
            let ended = s.prompts.contains { $0.kind == "end" && $0.key == key && $0.t >= pauseStart }
            XCTAssertTrue(ended, "[\(arm)] \(key) must play to its end (the player's own finish report)")
        }
        // The first glimpse waits for the intro to end.
        if let introEnd = s.prompts.first(where: { $0.key == "final_intro" && ($0.kind == "end" || $0.kind == "cut") }),
           let firstGlimpse = s.timeline.first(where: { $0.stage == "glimpse" }) {
            XCTContext.runActivity(named: "intro \(introStart)s, intro prompt \(introEnd.kind) at \(introEnd.t)s, first glimpse \(firstGlimpse.t)s") { _ in }
            XCTAssertEqual(introEnd.kind, "end", "[\(arm)] the intro prompt was cut")
            XCTAssertGreaterThanOrEqual(firstGlimpse.t, introEnd.t, "[\(arm)] the first glimpse came before the intro ended")
        }
    }

    // MARK: - Helpers

    /// Frames of the controls over the canvas (window points), recorded with
    /// their labels so a masked region is never anonymous.
    @MainActor
    private func controlsOver(_ canvas: CGRect, in app: XCUIApplication) -> [CGRect] {
        guard !canvas.isEmpty else { return [] }
        let hits = app.buttons.allElementsBoundByIndex
            .filter { $0.exists && $0.frame.intersects(canvas) && !$0.frame.contains(canvas) }
            .map { (label: $0.label, frame: $0.frame) }
        XCTContext.runActivity(named: "masked over the canvas: "
            + hits.map { "'\($0.label)' \($0.frame)" }.joined(separator: ", ")) { _ in }
        return hits.map { $0.frame }
    }

    /// Practice-screen chrome present in the accessibility tree.
    @MainActor
    private func chromePresent(_ app: XCUIApplication) -> [String] {
        var out: [String] = []
        let any = app.descendants(matching: .any)
        for id in ["Nächster Buchstabe", "Vorheriger Buchstabe", "Beobachtungsphase"] where any[id].exists {
            out.append(id)
        }
        for prefix in ["Aktueller Buchstabe", "Lernphase"] {
            if any.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch.exists { out.append(prefix) }
        }
        return out
    }

    @discardableResult @MainActor
    private func attach(_ name: String) -> XCUIScreenshot {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return shot
    }

    private func attachText(_ name: String, _ text: String) {
        let a = XCTAttachment(string: text)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    @MainActor
    private func currentState(_ app: XCUIApplication) -> SessionState? {
        let element = app.descendants(matching: .any)["tracing-geometry-hook"]
        guard element.exists else { return nil }
        return SessionState(json: element.label)
    }

    @MainActor
    private func waitForState(_ app: XCUIApplication, timeout: TimeInterval,
                              where condition: (SessionState) -> Bool) -> SessionState? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let s = currentState(app), condition(s) { return s }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        return nil
    }

    @MainActor
    private func stateSummary(_ app: XCUIApplication) -> String {
        guard let s = currentState(app) else { return "no hook" }
        return "letter=\(s.letter) phase=\(s.phase) probe=\(s.probe) stage=\(s.stage) chrome=\(s.chrome) "
            + "ink=\(s.inkLayers) glyph=\(s.glyph) end=\(s.endScreen) check=\(s.check)"
    }

    /// How many sampled canvas pixels differ between two screenshots (any
    /// channel by more than 40/255), every 3rd pixel in each direction. The
    /// canvas frame is in window points; the screenshot is in interface
    /// orientation at the screen scale (checked against the app's frame).
    @MainActor
    private func canvasDiff(_ a: UIImage, _ b: UIImage, canvas: CGRect, masking: [CGRect] = [],
                            app: XCUIApplication) -> Int {
        guard let ca = a.cgImage, let cb = b.cgImage, ca.width == cb.width, ca.height == cb.height else { return -1 }
        let w = ca.width, h = ca.height
        // The screenshot is in the device's NATIVE (portrait) screen space,
        // the canvas frame in interface (landscape) window points: map with
        // XCUITest's own transform (LetterTracer.screenTransform), never by
        // orientation arithmetic. -1 when the two do not line up.
        let t = LetterTracer.screenTransform(app)
        let screen = CGRect(origin: .zero, size: app.frame.size).applying(t)
        let scale = CGFloat(w) / max(screen.width, 1)
        guard abs(CGFloat(h) / scale - screen.height) <= 4 else { return -1 }
        func native(_ rect: CGRect) -> CGRect {
            let n = rect.applying(t).offsetBy(dx: -screen.minX, dy: -screen.minY)
            return CGRect(x: n.minX * scale, y: n.minY * scale, width: n.width * scale, height: n.height * scale)
        }
        // Inset 8 pt so the canvas edge (shadows, the chrome beside it) is out.
        let r = native(canvas.insetBy(dx: 8, dy: 8))
        guard !r.isEmpty else { return -1 }
        var masks = masking.map { native($0.insetBy(dx: -6, dy: -6)) }
        func pixels(_ img: CGImage) -> [UInt8] {
            var buf = [UInt8](repeating: 0, count: w * h * 4)
            let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ctx?.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return buf
        }
        let pa = pixels(ca), pb = pixels(cb)
        let x0 = max(0, Int(r.minX)), x1 = min(w, Int(r.maxX))
        let y0 = max(0, Int(r.minY)), y1 = min(h, Int(r.maxY))
        // The writing-turn cue (the 👆 pill, `writingCueOverlay`) sits over
        // the canvas in the writing stage and is accessibility-HIDDEN, so no
        // query finds it: locate it by its brand fill (#2563EB) in either
        // image and mask its box plus its shadow. Measured on the iPad: it
        // is the only strongly blue blob inside the canvas.
        for (p, tag) in [(pa, "a"), (pb, "b")] {
            var bx0 = Int.max, bx1 = -1, by0 = Int.max, by1 = -1
            var y = y0
            while y < y1 {
                var x = x0
                while x < x1 {
                    let i = (y * w + x) * 4
                    let rr = Int(p[i]), gg = Int(p[i + 1]), bb = Int(p[i + 2])
                    if bb > 180 && bb - rr > 80 && bb - gg > 60 {
                        bx0 = min(bx0, x); bx1 = max(bx1, x); by0 = min(by0, y); by1 = max(by1, y)
                    }
                    x += 3
                }
                y += 3
            }
            if bx1 >= 0 {
                let pad = 48.0
                let box = CGRect(x: Double(bx0) - pad, y: Double(by0) - pad,
                                 width: Double(bx1 - bx0) + 2 * pad, height: Double(by1 - by0) + 2 * pad)
                // A box this big is not the cue: refuse rather than mask the canvas away.
                guard box.width * box.height < 0.05 * r.width * r.height else { return -1 }
                masks.append(box)
                XCTContext.runActivity(named: "masked the writing cue in image \(tag): \(box) (native px)") { _ in }
            }
        }
        var changed = 0
        var y = y0
        while y < y1 {
            var x = x0
            while x < x1 {
                if masks.contains(where: { $0.contains(CGPoint(x: x, y: y)) }) { x += 3; continue }
                let i = (y * w + x) * 4
                if abs(Int(pa[i]) - Int(pb[i])) > 40 || abs(Int(pa[i + 1]) - Int(pb[i + 1])) > 40
                    || abs(Int(pa[i + 2]) - Int(pb[i + 2])) > 40 {
                    changed += 1
                }
                x += 3
            }
            y += 3
        }
        return changed
    }
}

// MARK: - The hook's session readout

/// The fields of the `tracing-geometry-hook` JSON this suite reads
/// (`TracingGeometryTestHookView.snapshot`, `TracingSessionTimeline.json`).
struct SessionState {
    let raw: String
    let letter: String
    let phase: String
    let probe: String
    let stage: String
    let chrome: Bool
    let inkLayers: Int
    let glyph: Bool
    let endScreen: Bool
    let check: Bool
    let canvasFrame: CGRect
    let timeline: [TimelineEntry]
    let audioMeasured: Bool
    let audio: [AudioSeg]
    let prompts: [PromptEvent]
    /// Every canvas frame whose content changed (`TracingInkDrawProbe`):
    /// what the Canvas closure drew, read inside it.
    let frames: [Frame]
    /// The model's final-test stage changes, stamped at the assignment.
    let stageChanges: [StageChange]

    init?(json: String) {
        guard let data = json.data(using: .utf8),
              let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let stage = d["stage"] as? String else { return nil }
        raw = json
        letter = d["letter"] as? String ?? ""
        phase = d["phase"] as? String ?? ""
        probe = d["probe"] as? String ?? ""
        self.stage = stage
        chrome = d["chrome"] as? Bool ?? false
        inkLayers = d["inkLayers"] as? Int ?? -1
        glyph = d["glyph"] as? Bool ?? false
        endScreen = d["endScreen"] as? Bool ?? false
        check = d["check"] as? Bool ?? false
        let c = d["canvas"] as? [Double] ?? [0, 0, 0, 0]
        canvasFrame = c.count == 4 ? CGRect(x: c[0], y: c[1], width: c[2], height: c[3]) : .zero
        timeline = (d["timeline"] as? [[String: Any]] ?? []).map(TimelineEntry.init)
        audioMeasured = d["audioMeasured"] as? Bool ?? false
        audio = (d["audio"] as? [[String: Any]] ?? []).map(AudioSeg.init)
        prompts = (d["prompts"] as? [[String: Any]] ?? []).map(PromptEvent.init)
        frames = (d["frames"] as? [[String: Any]] ?? []).map(Frame.init)
        stageChanges = (d["stageChanges"] as? [[String: Any]] ?? []).map(StageChange.init)
    }

    struct Frame {
        let t: Double, letter: String, stage: String, glyph: Bool, ink: Int
        init(_ d: [String: Any]) {
            t = d["t"] as? Double ?? -1; letter = d["letter"] as? String ?? ""
            stage = d["stage"] as? String ?? ""; glyph = d["glyph"] as? Bool ?? false
            ink = d["ink"] as? Int ?? -1
        }
        var line: String { "t=\(t) \(letter) stage=\(stage) glyph=\(glyph) ink=\(ink)" }
    }

    struct StageChange {
        let t: Double, letter: String, stage: String
        init(_ d: [String: Any]) {
            t = d["t"] as? Double ?? -1; letter = d["letter"] as? String ?? ""
            stage = d["stage"] as? String ?? ""
        }
    }

    struct TimelineEntry {
        let t: Double, letter: String, phase: String, probe: String, stage: String
        let chrome: Bool, ink: Int, glyph: Bool, pause: Bool, end: Bool, check: Bool
        init(_ d: [String: Any]) {
            t = d["t"] as? Double ?? -1
            letter = d["letter"] as? String ?? ""; phase = d["phase"] as? String ?? ""
            probe = d["probe"] as? String ?? ""; stage = d["stage"] as? String ?? ""
            chrome = d["chrome"] as? Bool ?? false; ink = d["ink"] as? Int ?? -1
            glyph = d["glyph"] as? Bool ?? false; pause = d["pause"] as? Bool ?? false
            end = d["end"] as? Bool ?? false; check = d["check"] as? Bool ?? false
        }
        var line: String {
            "t=\(t) \(letter) \(phase) probe=\(probe.isEmpty ? "-" : probe) stage=\(stage) chrome=\(chrome) "
            + "ink=\(ink) glyph=\(glyph) pause=\(pause) end=\(end) check=\(check)"
        }
    }

    struct AudioSeg {
        let letter: String, phase: String, probe: String, stage: String
        let start: Double, end: Double, samples: Int, loud: Int, peak: Double, settledLoud: Int, settledPeak: Double
        init(_ d: [String: Any]) {
            let parts = (d["key"] as? String ?? "").split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            letter = parts.count > 0 ? parts[0] : ""; phase = parts.count > 1 ? parts[1] : ""
            probe = parts.count > 2 ? parts[2] : ""; stage = parts.count > 3 ? parts[3] : ""
            start = d["start"] as? Double ?? 0; end = d["end"] as? Double ?? 0
            samples = d["samples"] as? Int ?? 0; loud = d["loud"] as? Int ?? 0
            peak = d["peak"] as? Double ?? 0
            settledLoud = d["settledLoud"] as? Int ?? 0; settledPeak = d["settledPeak"] as? Double ?? 0
        }
        var line: String {
            "\(start)-\(end)s \(letter) \(phase) probe=\(probe.isEmpty ? "-" : probe) stage=\(stage) "
            + "samples=\(samples) loud=\(loud) peak=\(peak) settledLoud=\(settledLoud) settledPeak=\(settledPeak)"
        }
    }

    struct PromptEvent {
        let t: Double, kind: String, key: String, stage: String
        init(_ d: [String: Any]) {
            t = d["t"] as? Double ?? -1; kind = d["kind"] as? String ?? ""; key = d["key"] as? String ?? ""
            stage = d["stage"] as? String ?? ""
        }
    }
}
