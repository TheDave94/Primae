// LetterSwitchCaptureUITests.swift
// PrimaeUITests
//
// R-072 (rebuilt by lane FOLLOWUP-r31, 2026-11-27): does a LETTER SWITCH click,
// in each arm, while the arm's sound is PLAYING? The integration seat's first
// instrument (a scratch clone plus `tools/r072_switch.py`, both lost with their
// scratchpads) tapped the chevron on a timer, so the sound was playing at only
// 2 of 4 phoneme switches and 1 of 4 spatial ones. This one waits until the
// main mixer is actually sounding (the DEBUG hook's `mixerPeak`, from
// PopCapture's tap) in the observe phase, and only then taps "Nächster
// Buchstabe". It records the peak it saw, so the analysis can refuse a switch
// that was not exercised.
//
// R072FIX (2026-11-28): the new letter's sound counts only after the mixer has
// read SILENT on that letter first. The first capture (fa31b72d) counted the
// OUTGOING letter's 0.4 s stop fade as the new letter's sound: the hook already
// showed the new letter while the old one faded, two polls 0.25 s apart fit
// inside the fade, and the tap landed before the new letter's observe sound
// started (phoneme switches 2 and 4: recorded peaks 0.16 and 0.10, kernel and
// mixer at -240 dB at the switch). The observe sound starts only after the
// spoken cue plus 1 s, so a new letter always has that silence first. The
// recorded prompts do not reach the main mixer (silent-arm capture: peak
// -240 dBFS over the whole run), so the mixer reads the arm's voice alone.
//
// One launch per arm, under `-popCapture` (Documents/popcap/r072_<arm>-<time>/:
// kernel.wav, mixer.wav, rt.tsv, events.tsv, meta.txt). Pull the directory with
// `xcrun devicectl device copy from` and run `scripts/r072_switch.py` on it.
//
// Physical iPad only (not in CI), like the rest of PrimaeUITests.

import XCTest
import Foundation

final class LetterSwitchCaptureUITests: XCTestCase {

    /// Switches per run.
    static let switches = 4
    /// The mixer peak that counts as "the arm's sound is playing" (-40 dBFS); the observe sound sits near -17 dBFS.
    static let soundingPeak = 0.01
    /// The mixer must read sounding on this many consecutive hook polls (0.25 s apart) before the tap.
    static let soundingPolls = 2

    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testPhoneme() { run(arm: "phoneme") }
    @MainActor func testSpatial() { run(arm: "spatial") }
    @MainActor func testSilent() { run(arm: "silent") }

    @MainActor
    private func run(arm: String) {
        let app = XCUIApplication.primaeUnderTest()
        app.launchArguments += [
            LetterTracer.launchArgument,
            "-popCapture", "-popCaptureTag", "r072_\(arm)",
            "-de.flamingistan.primae.audioConditionOverride", arm,
            "-de.flamingistan.primae.trainedSubsetOverride", "AFILM",
        ]
        app.launch()
        XCTAssertTrue(app.enrolNextChildViaRail(), "the child must be enrolled")
        var last: TracingHookSnapshot?
        if let s = LetterTracer.waitForSnapshot(app, timeout: 10, last: &last, where: { _ in true }), s.parked {
            let observe = app.descendants(matching: .any)["Beobachtungsphase"]
            if observe.waitForExistence(timeout: 5) { observe.tap() }
        }
        let next = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Nächster Buchstabe")).firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 10), "the chevron must exist")
        var record: [String] = []
        for i in 0..<Self.switches {
            guard let s = LetterTracer.waitForSnapshot(app, timeout: 20, last: &last, where: { $0.phase == "observe" }) else {
                XCTFail("switch \(i + 1): no observe phase; last \(last?.summary ?? "-")"); return
            }
            let before = s.letter
            var peak = 0.0
            if arm != "silent" {
                // Wait until THIS letter's observe sound plays (after the spoken instruction), on consecutive
                // polls: first silence on this letter (the previous letter's fade is over), then sounding.
                var run = 0
                var sawSilence = false
                let deadline = Date().addingTimeInterval(25)
                while run < Self.soundingPolls && Date() < deadline {
                    if let n = LetterTracer.snapshot(app), n.letter == before, n.phase == "observe", let p = n.mixerPeak {
                        if p < Self.soundingPeak { sawSilence = true; run = 0 }
                        else if sawSilence { run += 1; peak = p }
                    } else { run = 0 }
                    Thread.sleep(forTimeInterval: 0.25)
                }
                XCTAssertGreaterThanOrEqual(run, Self.soundingPolls,
                    "switch \(i + 1) (\(before)): the \(arm) arm's observe sound never played (silence seen first: \(sawSilence)); last peak \(LetterTracer.snapshot(app)?.mixerPeak ?? -1)")
                if run < Self.soundingPolls { return }
            } else {
                // The silent arm has nothing to wait for; switch inside the observe animation.
                Thread.sleep(forTimeInterval: 3)
                peak = LetterTracer.snapshot(app)?.mixerPeak ?? -1
                XCTAssertGreaterThanOrEqual(peak, 0, "switch \(i + 1) (\(before)): the hook reported no mixer peak")
                XCTAssertLessThan(peak, Self.soundingPeak, "switch \(i + 1) (\(before)): the silent arm's mixer is sounding (\(peak))")
            }
            next.tap()
            guard let after = LetterTracer.waitForSnapshot(app, timeout: 10, last: &last, where: { $0.letter != before }) else {
                XCTFail("switch \(i + 1): the letter did not change from \(before)"); return
            }
            record.append("switch \(i + 1): \(before) -> \(after.letter), mixer peak before the tap \(peak)")
        }
        Thread.sleep(forTimeInterval: 1.5)   // the last switch's fade into the capture
        let note = XCTAttachment(string: record.joined(separator: "\n"))
        note.name = "r072_\(arm)_switches"
        note.lifetime = .keepAlways
        add(note)
        print("R072 \(arm): " + record.joined(separator: " | "))
    }
}
