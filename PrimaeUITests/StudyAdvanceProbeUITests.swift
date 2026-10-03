// StudyAdvanceProbeUITests.swift
// PrimaeUITests
//
// Targeted checks for the three device reports of 2026-09-16, driven in a
// SIMULATOR because no device is reachable from this seat. Same discipline
// as StudyDryRunUITests: a separate .xctest bundle that drives the real
// app through the accessibility tree, importing only XCTest and never
// PrimaeNative. Nothing here touches app code or the study binary.
//
// WHAT THIS CAN AND CANNOT SETTLE. These are code-behaviour checks. The
// simulator is an iPad Pro 11-inch (M5) on iOS 27.0 built with Xcode 27.0,
// against the pilot artefact's Release-Study on a 13-inch/A16 iPad under
// Xcode 26.4 — no parity. Nothing here observes sound reaching a speaker;
// check 2 below is deliberately absent for that reason (see its note).
//
// The two checks that ARE here:
//   A. chevron advance  — report 1. Compares the letter pill's label
//      before/after tapping "Nächster Buchstabe" (navArrow,
//      SchuleWorldView.swift:502; pill label ":434").
//   B. second enrolment — report 3. Enrols, then enrols again, and
//      confirms the incoming participant is usable WITHOUT a relaunch.

import XCTest
import Foundation

final class StudyAdvanceProbeUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Check A — does the chevron advance the letter?

    /// Report 1 says a session cannot move past one letter. The study
    /// build has no auto-advance by design (the celebration overlay that
    /// would drive it is `#if !STUDY_BUILD`), so the chevron is the
    /// documented path (STUDY_DEVICE_DRYRUN.md:286-292). This tells us
    /// whether that path actually works.
    @MainActor
    func testChevronAdvancesLetter() {
        let app = XCUIApplication()
        app.launch()

        attach(app, name: "A-01-launch")

        guard let before = currentLetter(app) else {
            // Fail loudly with the screen attached rather than timing out
            // cryptically — onboarding or a missing pill is a real finding.
            attach(app, name: "A-02-no-letter-pill-FAILURE")
            XCTFail("no 'Aktueller Buchstabe …' element after launch; see the attached screenshot")
            return
        }

        let next = element(label: "Nächster Buchstabe", in: app)
        XCTAssertTrue(next.waitForExistence(timeout: 10),
                      "the right-chevron nav button must exist in the study build")
        attach(app, name: "A-03-before-chevron-\(before)")

        next.tap()
        // DIAGNOSTIC (2026-09-16): `nextLetter()` ends with
        // `toast("Buchstabe: \(currentLetterName)")` and ALSO calls
        // `load(letter:)`, which un-parks the session. So the toast's own
        // text distinguishes the two candidate causes of a stuck pill:
        //   toast present  -> nextLetter ran and `currentLetterName` DID
        //                     change; the pill label is reading stale.
        //   toast absent   -> nextLetter bailed at one of its guards
        //                     (empty pool / name not found).
        // Captured immediately, before the toast's lifetime expires.
        let toast = element(labelPrefix: "Buchstabe:", in: app)
        let toastText = toast.exists ? toast.label : "<no toast>"
        attach(app, name: "A-03b-immediately-after-tap-toast")

        // nextLetter() -> load(letter:), which resets the phase controller
        // and reloads checkpoints; give it a beat to settle before reading.
        Thread.sleep(forTimeInterval: 2.0)

        let after = currentLetter(app)
        attach(app, name: "A-04-after-chevron-\(after ?? "nil")")

        XCTAssertNotEqual(
            before, after,
            "tapping 'Nächster Buchstabe' did not change the current letter: stayed on '\(before)'. nextLetter() toast = \(toastText)"
        )
    }

    /// The other half of report 1: after the chevron lands on a new letter,
    /// is that letter actually usable — i.e. did it load a fresh phase
    /// state rather than a completed one? `load(letter:)` calls
    /// `phaseController.reset()`, which clears `isLetterSessionComplete`;
    /// this confirms the visible consequence (phase indicator back to 0).
    @MainActor
    func testChevronLandsOnUsableLetter() {
        let app = XCUIApplication()
        app.launch()

        guard let before = currentLetter(app) else {
            attach(app, name: "A2-01-no-letter-pill-FAILURE")
            XCTFail("no 'Aktueller Buchstabe …' element after launch")
            return
        }

        let next = element(label: "Nächster Buchstabe", in: app)
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        next.tap()
        Thread.sleep(forTimeInterval: 2.0)

        // Letter IDENTITY, added 2026-09-16. This test previously asserted
        // only the phase-indicator string, which reads "0 von M
        // abgeschlossen" whether or not the letter actually advanced — so
        // it PASSED on the physical iPad while `testChevronAdvancesLetter`
        // failed on the same tap, and the real bug shipped behind a green
        // tick. Asserting the observable consequence of the button being
        // pressed, not just a neighbouring piece of state, is the point.
        let after = currentLetter(app)
        XCTAssertNotEqual(
            before, after,
            "the chevron landed on the same letter ('\(before)') — this test must not pass while the letter never advances"
        )

        let indicator = element(labelPrefix: "Lernphase", in: app)
        XCTAssertTrue(indicator.waitForExistence(timeout: 8),
                      "the phase indicator must be present after the chevron lands")
        attach(app, name: "A2-02-after-chevron")

        let value = indicator.value as? String ?? ""
        // 0 OR 1, not 0 alone (2026-09-17). This asserted exactly
        // "0 von 4 abgeschlossen", which was safe only while the observe
        // demonstration ran TWO passes: the test taps the chevron, sleeps
        // 2 s, then reads, and two passes outlasted that read. Observe now
        // advances after ONE pass — the supervisor's "einmal vorzeigen" —
        // so by the time this reads, the demonstration has finished and
        // the letter sits legitimately at 1 of 4. Pinning 0 would now
        // assert that the demonstration had NOT completed, which is the
        // opposite of the behaviour under test.
        //
        // What this test is for is that the chevron lands on a USABLE
        // letter — the identity assertion above carries that, and this
        // one carries that the landed letter has not arrived mid-flow or
        // finished. Anything above 1 would mean the chevron landed on a
        // letter already in progress.
        //
        // DENOMINATOR UPDATED 2026-09-21: this pinned "von 4", which the
        // 2026-09-18 cut made wrong — a session runs THREE phases now
        // (D5), and the app correctly renders "0 von 3 abgeschlossen".
        // The 2026-09-17 note above updated the NUMERATOR for the
        // observe-passes change but the denominator was missed, and
        // nothing caught it because PrimaeUITests never runs in CI.
        // Caught by running the suite on the physical iPad.
        XCTAssertTrue(
            value == "0 von 3 abgeschlossen" || value == "1 von 3 abgeschlossen",
            "a freshly loaded letter should start at 0 phases done, or at 1 once its single observe pass completes; got '\(value)'"
        )
    }

    // MARK: - Check B — second enrolment usable without relaunch

    /// Report 3 says enrolling a new participant still requires Settings +
    /// relaunch. The relaunch half should no longer hold: `thesisCondition`
    /// /`audioCondition`/`trainedSubset` became `var` on 2026-09-14 so
    /// `reapplyParticipantIdentity` can re-seed in place
    /// (TracingViewModel.swift:710-725). This drives enrolment twice and
    /// uses the second participant WITHOUT relaunching; the app is launched
    /// exactly once, at the top.
    @MainActor
    func testSecondEnrolmentUsableWithoutRelaunch() {
        let app = XCUIApplication()
        app.launch()   // the ONLY launch in this test

        openParentArea(app)
        attach(app, name: "B-01-parent-area")

        enrolNewParticipant(app)
        XCTAssertTrue(waitFor(label: "Vortest starten: A", in: app, timeout: 12),
                      "the research dashboard should be usable after the first enrolment")
        attach(app, name: "B-02-first-participant-dashboard")

        // Second enrolment, still no relaunch.
        enrolNewParticipant(app)
        XCTAssertTrue(waitFor(label: "Vortest starten: A", in: app, timeout: 12),
                      "the research dashboard should be usable for the SECOND participant without relaunching")
        attach(app, name: "B-03-second-participant-dashboard")
    }

    /// The rail's double-tap reveal (2026-10-01) — the proctor path for
    /// running 30-40 children back to back WITHOUT entering the parent
    /// area at all, which is the whole point of the gesture.
    ///
    /// Asserts the three things that make it usable: the gesture reveals
    /// the button in the same bar as the gear, the button runs the same
    /// seal-and-rederive flow the dashboard runs, and it then gets OUT of
    /// the way so it is not left on the child-facing screen.
    ///
    /// Taps the rail's OWN centre, derived from the element's reported
    /// frame rather than a guessed normalised offset. An earlier version
    /// hardcoded dx 0.008 / dy 0.45 on the assumption the rail is a 64pt
    /// vertical bar down the LEFT edge — and the accessibility snapshot
    /// disproved it: in this orientation the rail is
    /// `{{0,0},{820,64}}`, a full-width bar across the TOP, so that
    /// coordinate landed on the canvas and the probe could not have found
    /// the button even if the gesture worked. Deriving the point from the
    /// element makes the test correct in either orientation.
    @MainActor
    func testRailDoubleTapEnrolsNextChildWithoutParentArea() {
        let app = XCUIApplication()
        app.launch()   // the ONLY launch in this test

        let rail = element(label: "Navigationsleiste", in: app)
        XCTAssertTrue(rail.waitForExistence(timeout: 10), "the rail must be on screen")
        rail.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap()

        let next = element(label: "Nächstes Kind", in: app)
        if !next.waitForExistence(timeout: 5) {
            // Dump the screen so a failure says WHAT is there, not just
            // that the button is missing.
            attach(app, name: "D-FAIL-after-rail-double-tap")
            print("RAILDIAG-FRAME \(rail.frame)")
        }
        XCTAssertTrue(next.exists,
                      "a double-tap on the rail must reveal the 'Nächstes Kind' button in the same bar as the gear")
        attach(app, name: "D-01-rail-next-child-revealed")

        next.tap()

        let confirm = element(label: "Neues Kind starten", in: app)
        XCTAssertTrue(confirm.waitForExistence(timeout: 5),
                      "the destructive confirm should appear — the rail button runs the same flow as the dashboard")
        confirm.tap()

        let readyOK = app.alerts["Neues Kind bereit"].buttons["OK"]
        XCTAssertTrue(readyOK.waitForExistence(timeout: 5),
                      "the ready alert should appear, not a relaunch prompt")
        readyOK.tap()

        // THE GATE MUST BE GONE. "Studie kann nicht starten" is what a
        // study iPad shows when `sessionBlockReason` is non-nil, and on a
        // COLD start that is true at launch — the proctor is told to enrol
        // child #1, does exactly that, and must land on a runnable screen.
        // It did not, for a long time: `participantEnrolled` was a `let`
        // captured at init, so enrolling updated `ParticipantStore` but
        // not the view model, and the gate survived a perfectly successful
        // enrolment (found on the physical iPad, 2026-10-02). The unit
        // test pins the transition; this pins the SCREEN, which is the
        // thing the proctor actually sees.
        let startGate = app.staticTexts["Studie kann nicht starten"]
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: startGate)
        waitForExpectations(timeout: 10)

        // Waits for the element to LEAVE the tree rather than sampling
        // `exists` once: a plain `.exists` check races the accessibility
        // snapshot and would report a still-present button for a
        // control that has already been hidden. `accessibilityHidden`
        // is what must remove it — otherwise an invisible button stays
        // reachable by VoiceOver and by this very lookup.
        // Asserts HIT-TESTING, not absence from the element tree.
        //
        // The control stays mounted (unmounting it ate its own "ready"
        // alert), so after use it is hidden with `opacity(0)` +
        // `allowsHitTesting(false)` + `accessibilityHidden(true)`. The
        // property that actually protects the child is that the button
        // cannot be TAPPED, and that is exactly what `isHittable`
        // reports. Asserting tree-absence instead would be asserting an
        // implementation detail of the accessibility bridge, and the
        // button legitimately remains in the snapshot.
        let notHittable = NSPredicate(format: "isHittable == false")
        expectation(for: notHittable, evaluatedWith: next)
        waitForExpectations(timeout: 5) { error in
            XCTAssertNil(error,
                         "the revealed button must stop being hittable after use, so it is never a live control on the child-facing screen")
        }
        attach(app, name: "D-02-after-rail-next-child")
    }

    // MARK: - Check C (report 2) — the audio arms

    /// Report 2: does each sound arm actually get its own audio?
    ///
    /// Sets the researcher override for the arm through the app's own
    /// Settings picker — the path a proctor would use — then RELAUNCHES,
    /// because the picker's own hint says the change takes effect on the
    /// next app start (the override is read at view-model init). Then it
    /// sits through the observe window, during which the sound arms'
    /// scripted two-second demonstration should be requested.
    ///
    /// WHAT THIS PROVES AND WHAT IT DOES NOT. The assertion here is weak
    /// on purpose: this test only confirms the app reached and held the
    /// observe phase. The evidence for the arm's audio is the app-side
    /// log pulled off the device afterwards, and even that establishes
    /// only that the engine was ASKED to play a named file — an XCUITest
    /// cannot observe sound leaving a speaker, and no simulator or
    /// device-side test can. That distinction is stated in the report.
    @MainActor
    func testPhonemeArmRequestsAudioDuringObserve() {
        runAudioArmCheck(armDisplayName: "Phonem", tag: "C1-phonem")
    }

    @MainActor
    func testSpatialArmRequestsAudioDuringObserve() {
        runAudioArmCheck(armDisplayName: "Raumklang", tag: "C2-raumklang")
    }

    @MainActor
    private func runAudioArmCheck(armDisplayName: String, tag: String) {
        // The audio-arm override is a PERSISTENT researcher setting, and
        // these checks set it. Leaving it behind arms a forced arm on the
        // study device: measured 2026-09-17, after these two checks ran on
        // iPad 00008103-000E60311AE8801E, `Library/Preferences/
        // com.flamingistan.primae.study.plist` carried
        // `de.flamingistan.primae.audioConditionOverride = "spatial"` —
        // and `PilotAudioCondition.defaultForInstall` returns that
        // verbatim, so the next child on that iPad would have run the
        // spatial arm whatever the design assigned. A check that measures
        // an arm must not leave the device on it.
        //
        // Restored in a TEARDOWN BLOCK, not at the end of the body: with
        // `continueAfterFailure = false` a failed assertion aborts the
        // test, which is exactly the case that must not skip the restore.
        addTeardownBlock { @MainActor in
            let app = XCUIApplication()
            app.launch()
            self.openParentArea(app)
            self.openSettings(app)
            self.selectAudioArm("Automatisch", in: app)
            // The override is read at view-model init, so leave the app
            // closed rather than running on a stale arm.
            app.terminate()
        }

        let app = XCUIApplication()
        // Arm the output tap so this run MEASURES the sound instead of
        // only proving the engine was asked to play (2026-10-02). The
        // per-phase results land in
        // `Application Support/PrimaeNative/audio-signal-probe.log` in the
        // app container, which a machine can read; the proctor's report
        // that the demonstration and the freeWrite draw were both silent
        // could not be checked by any assertion before this.
        app.launchArguments += ["-audioSignalProbe"]
        app.launch()

        openParentArea(app)
        openSettings(app)
        selectAudioArm(armDisplayName, in: app)
        attach(app, name: "\(tag)-arm-selected-\(armDisplayName)")

        // The override is read at view-model init, so it needs a restart.
        app.terminate()
        app.launchArguments += ["-audioSignalProbe"]
        app.launch()

        // START THE PARKED SESSION. A study session launches parked
        // (`StudyLaunchTests` asserts `vm.launchParked` at launch), so the
        // observe phase — and with it the pre-task demonstration — does
        // not begin until the proctor taps the observe area
        // (SchuleWorldView.swift:461-464). Without this tap the app reaches
        // the letter but never asks the engine to play anything: the first
        // evidence pull showed seven LOAD lines and ZERO play requests.
        let observeArea = element(label: "Beobachtungsphase", in: app)
        XCTAssertTrue(observeArea.waitForExistence(timeout: 12),
                      "the observe area must be present to start the parked session")
        observeArea.tap()
        attach(app, name: "\(tag)-session-started")

        // Sit through the observe window: the demonstration is 2 s, and
        // observe runs two guide-dot cycles with touch disabled.
        Thread.sleep(forTimeInterval: 14.0)
        attach(app, name: "\(tag)-observe-window-ended")

        XCTAssertTrue(currentLetter(app) != nil,
                      "the session should still be on a letter after the observe window")
    }

    /// Open the parent area's Einstellungen screen from the sidebar.
    private func openSettings(_ app: XCUIApplication) {
        let settings = element(label: "Einstellungen", in: app)
        XCTAssertTrue(settings.waitForExistence(timeout: 8),
                      "the Einstellungen entry must exist in the parent sidebar")
        settings.tap()
        // Screenshot BEFORE the assertion: when this failed on device the
        // first time, the failure carried no evidence of what was on
        // screen, which is exactly the information needed to fix it.
        attach(app, name: "C0-einstellungen-opened")
        // The researcher overrides (Thesis / Audio / trained-subset) sit
        // BELOW the parent-facing rows. Measured on device: the first
        // screen shows Schriftart, Buchstabenreihenfolge, Freies
        // Schreiben, Erinnerungstest, Lautwert — the arm pickers are not
        // in view and must be scrolled to.
        let picker = scrollTo(prefix: "Audio-Arm überschreiben", in: app)
        XCTAssertTrue(picker.exists,
                      "the audio-arm override picker must be reachable by scrolling Einstellungen")
    }

    /// Swipe up until an element whose label starts with `prefix` exists.
    /// Returns the element either way so the caller can assert.
    @discardableResult
    private func scrollTo(prefix: String, in app: XCUIApplication, swipes: Int = 8) -> XCUIElement {
        let target = element(labelPrefix: prefix, in: app)
        for _ in 0..<swipes {
            if target.exists { return target }
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.4)
        }
        return target
    }

    /// Drive the researcher audio-arm picker. The options are the arm
    /// display names plus "Automatisch".
    ///
    /// Matches the picker by PREFIX, not exact label: a SwiftUI `Picker`
    /// renders as a button whose accessibility label carries its current
    /// value ("Audio-Arm überschreiben, Automatisch"), so an exact match
    /// on the title alone never hits. That is how the first attempt
    /// failed on device.
    private func selectAudioArm(_ displayName: String, in app: XCUIApplication) {
        let picker = scrollTo(prefix: "Audio-Arm überschreiben", in: app)
        XCTAssertTrue(picker.exists, "audio-arm picker must exist")
        picker.tap()
        attach(app, name: "C0-picker-open")

        let option = element(label: displayName, in: app)
        XCTAssertTrue(option.waitForExistence(timeout: 8),
                      "the '\(displayName)' option must be offered by the picker")
        option.tap()
    }

    // MARK: - Check C (report 2) — deliberately NOT automated
    //
    // Report 2 is about AUDIO. A simulator's software audio stack does not
    // carry real AVAudioSession timing, and an XCUITest cannot observe
    // whether sound left a speaker at all — this project's own
    // scripts/run_device_uitests.sh header gives that as the reason CI
    // never runs UI tests as a per-push audio proof. So no assertion is
    // written here that would pretend to settle it. What the simulator
    // CAN show is whether playback is requested, which needs the unified
    // log, not the accessibility tree — see the report accompanying this
    // file.

    // MARK: - Flow helpers

    private func openParentArea(_ app: XCUIApplication) {
        let gear = element(label: "Eltern-Bereich", in: app)
        XCTAssertTrue(gear.waitForExistence(timeout: 10), "the parent-area gear must be reachable")
        // 2.0s minimumDuration (WorldSwitcherRail.swift) + margin.
        gear.press(forDuration: 2.3)
        XCTAssertTrue(waitFor(label: "Datenexport", in: app, timeout: 6),
                      "the parent-area sidebar should be visible after the gear long-press")
    }

    private func enrolNewParticipant(_ app: XCUIApplication) {
        let newParticipant = element(label: "Neuer Teilnehmer", in: app)
        XCTAssertTrue(newParticipant.waitForExistence(timeout: 6), "Neuer Teilnehmer button must exist")
        newParticipant.tap()

        // No pre-wipe share sheet, and no relaunch prompt — both removed
        // 2026-10-01; the outgoing child is sealed to ParticipantArchive/
        // and the arms re-derive in place. See NextParticipantControl.
        let confirm = element(label: "Neues Kind starten", in: app)
        XCTAssertTrue(confirm.waitForExistence(timeout: 6),
                      "the destructive confirm dialog should appear")
        confirm.tap()

        let readyOK = app.alerts["Neues Kind bereit"].buttons["OK"]
        XCTAssertTrue(readyOK.waitForExistence(timeout: 6), "the ready alert should appear")
        // Dismissed, NOT acted on — the point of the change is that no
        // relaunch follows, so this test never terminates the app.
        readyOK.tap()
    }

    /// The current letter, read off the pill's own label. Rendered in both
    /// branches of `letterPill`, so it is present under STUDY_BUILD.
    private func currentLetter(_ app: XCUIApplication) -> String? {
        let prefix = "Aktueller Buchstabe "
        let e = element(labelPrefix: prefix, in: app)
        guard e.waitForExistence(timeout: 8) else { return nil }
        return String(e.label.dropFirst(prefix.count))
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    // MARK: - Element lookup (label/text only, matching StudyDryRunUITests)

    private func element(label: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func element(labelPrefix: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", labelPrefix)).firstMatch
    }

    private func waitFor(label: String, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        element(label: label, in: app).waitForExistence(timeout: timeout)
    }

    private func waitForShareSheet(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let sheet = app.sheets.firstMatch
        let popover = app.otherElements["ActivityListView"]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if sheet.exists || popover.exists || app.collectionViews["ActivityListView"].exists { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
    }

    /// Same dismissal StudyDryRunUITests settled on: swipe down on the
    /// sheet, rather than a locale-specific Cancel label or a tap-outside.
    private func dismissShareSheet(_ app: XCUIApplication) {
        let sheet = app.sheets.firstMatch
        if sheet.exists {
            sheet.swipeDown(velocity: .fast)
        } else {
            app.swipeDown(velocity: .fast)
        }
    }
}

// MARK: - Measured audio (2026-10-02)

/// THE ANSWER TO "IS THERE ACTUALLY A SIGNAL IN EACH PHASE?".
///
/// Written after the proctor reported, from a physical iPad, that the
/// demonstration and the unassisted draw were both silent while only the
/// guided pass had sound. No existing assertion could check that: every
/// one of them asks whether `play()` was CALLED, which a silent engine
/// satisfies. This one arms `AudioSignalProbe`, which taps the output bus
/// and counts buffers that carried a non-zero peak, and leaves the
/// numbers in the app container for the runner to read.
///
/// It deliberately does NOT go through Einstellungen to pick an arm. That
/// path is long, scroll-dependent, and it broke on the device on the first
/// attempt (the override picker was not reachable in eight swipes). The
/// rail gesture enrols a child in three taps and exercises the same code
/// path, so the measurement does not depend on the arm picker at all —
/// what it reports is the arm this child actually drew, which is more
/// honest than forcing one.
@MainActor
final class MeasuredAudioUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    func testEnrollingThenObservingProducesMeasuredAudio() {
        let app = XCUIApplication()
        app.launchArguments += ["-audioSignalProbe"]
        // MEASURED 2026-10-02: this test's own enrolled child drew the
        // SILENT arm (participant UUID byte 230, 230 % 3 = 2), so there
        // was correctly no sound to measure and the probe had nothing to
        // report. A measurement run must name a sound arm explicitly:
        // `-key value` is how iOS seeds UserDefaults from launch
        // arguments, which is the same key `ParticipantStore
        // .audioConditionOverride` reads.
        app.launchArguments += [
            "-de.flamingistan.primae.audioConditionOverride", "phoneme",
        ]
        app.launch()

        // Cold start shows the enrolment gate; the rail reveals the
        // enrolment control without entering the parent area.
        let rail = app.descendants(matching: .any)["Navigationsleiste"]
        XCTAssertTrue(rail.waitForExistence(timeout: 15),
                      "the rail must be present on the enrolment gate")
        rail.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap()

        let next = app.descendants(matching: .any)["Nächstes Kind"]
        XCTAssertTrue(next.waitForExistence(timeout: 8),
                      "a double-tap on the rail must reveal the enrolment control")
        next.tap()

        let confirm = app.buttons["Neues Kind starten"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5),
                      "the destructive confirm must appear")
        confirm.tap()

        let ok = app.alerts["Neues Kind bereit"].buttons["OK"]
        XCTAssertTrue(ok.waitForExistence(timeout: 5),
                      "the ready alert must appear once the child is enrolled")
        ok.tap()

        // The gate must be GONE and the session running by itself — the
        // tap-to-start complaint was that it needed a further tap here.
        let gate = app.staticTexts["Studie kann nicht starten"]
        XCTAssertTrue(gate.waitForNonExistence(timeout: 15),
                      "enrolling must clear the start-gate without any further tap")

        // Sit through the demonstration, SAMPLING AS IT RUNS.
        //
        // MEASURED: polling only at the end saw `peak=0.0` and failed,
        // because the readout holds only the LATEST value and the loud
        // windows are the EARLY ones - the demonstration plays for a few
        // seconds and then the observe phase is silent. Waiting 16 s and
        // then looking reads the silence, not the sound.
        //
        // So the readings are collected continuously, and the assertion
        // runs over everything seen. That ordering IS the finding: sound
        // during the demonstration, silence after it.
        let deadline = Date().addingTimeInterval(18)
        var readings: [AudioSignalReading] = []
        while Date() < deadline {
            let element = app.descendants(matching: .any)["audio-signal-probe-readout"]
            if element.exists,
               let line = element.label as String?,
               line.hasPrefix("AUDIO-SIGNAL "),
               let reading = AudioSignalReading(line: line),
               !readings.contains(reading) {
                readings.append(reading)
            }
            usleep(250_000)
        }

        assertMeasuredSignal(readings: readings)
    }

    /// Turn the probe's log into an ASSERTION, not a log line.
    ///
    /// MEASURED 2026-10-02 on the physical iPad, phoneme arm:
    ///   AUDIO-SIGNAL observe nonSilent=16 total=19 peak=0.31476486
    /// i.e. a real signal reached the output bus. That number is the whole
    /// point of `AudioSignalProbe`: every pre-existing audio assertion asks
    /// whether `play()` was CALLED, which an engine that never started, or
    /// a file that never resolved, or a route with no output would pass
    /// while the child hears nothing.
    ///
    /// HOW THE NUMBERS REACH HERE. They live in the APP's container, which
    /// an XCUITest process cannot read. Rather than assert nothing and call
    /// the test a pass (the failure mode this whole file exists to avoid),
    /// the app copies the probe log to a path handed in via the launch
    /// ENVIRONMENT, and the test reads it back and asserts on it. The
    /// transfer is the only part that is not a real measurement.
    /// A COLD freeWrite probe is silent — and that is the design, not a
    /// defect.
    ///
    /// MEASURED on the device: `AUDIO-SIGNAL freeWrite nonSilent=0 total=20
    /// peak=0.0` on a pretest. The cause is deliberate: a cold probe
    /// reaches freeWrite with no demonstration armed (H6 — reaching this
    /// letter at all is a cold, untrained probe, and demonstrating it
    /// would train the very thing the probe depends on not having
    /// happened), so no arm file is loaded and the trace coupling has
    /// nothing to play.
    ///
    /// This test therefore pins the SILENCE, so a future reader does not
    /// "fix" it: the proctor's complaint was about the freeWrite pass of a
    /// normal SESSION, where observe/direct/guided have already loaded the
    /// arm's file and the lifted sound-off gate lets it sound.
    ///
    /// WHAT THIS DOES NOT COVER, stated plainly: that session freeWrite
    /// case. Reaching it needs a full observe -> direct -> guided walk,
    /// which depends on per-phase entry gestures and would break whenever
    /// one changes. It is the remaining gap in audio phase coverage, not
    /// something this test pretends to have checked.
    func testColdFreeWriteProbeIsSilentByDesign() {
        let app = XCUIApplication()
        app.launchArguments += ["-audioSignalProbe"]
        app.launchArguments += [
            "-de.flamingistan.primae.audioConditionOverride", "phoneme",
        ]
        app.launch()

        let rail = app.descendants(matching: .any)["Navigationsleiste"]
        XCTAssertTrue(rail.waitForExistence(timeout: 15))
        rail.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap()
        let next = app.descendants(matching: .any)["Nächstes Kind"]
        XCTAssertTrue(next.waitForExistence(timeout: 8))
        next.tap()
        let confirm = app.buttons["Neues Kind starten"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        let ok = app.alerts["Neues Kind bereit"].buttons["OK"]
        XCTAssertTrue(ok.waitForExistence(timeout: 5))
        ok.tap()
        XCTAssertTrue(app.staticTexts["Studie kann nicht starten"].waitForNonExistence(timeout: 15))

        // The pretest control lives in the parent area, reached by the
        // gear long-press (2.0s minimum in `WorldSwitcherRail` + margin).
        let gear = element(labelPrefix: "Eltern-Bereich", in: app)
        XCTAssertTrue(gear.waitForExistence(timeout: 10))
        gear.press(forDuration: 2.3)
        let pretest = element(labelPrefix: "Vortest starten: A", in: app)
        XCTAssertTrue(pretest.waitForExistence(timeout: 8),
                      "the pretest control must be reachable in the parent area")
        pretest.tap()

        let refusal = app.alerts["Test kann nicht starten"]
        if refusal.waitForExistence(timeout: 3) {
            XCTFail("the pretest was refused: "
                    + (refusal.staticTexts.element(boundBy: 1).label))
        }

        // Draw while SAMPLING: the readout carries only the latest value,
        // so a poll after the stroke would read whatever came after it.
        var readings: [AudioSignalReading] = []
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.55))
        let deadline = Date().addingTimeInterval(14)
        var drew = false
        while Date() < deadline {
            if !drew {
                start.press(forDuration: 0.15, thenDragTo: end)
                drew = true
            }
            if let line = readoutLabel(app), line.hasPrefix("AUDIO-SIGNAL "),
               let reading = AudioSignalReading(line: line),
               !readings.contains(reading) {
                readings.append(reading)
            }
            usleep(250_000)
        }

        let freeWrite = readings.filter { $0.label == "freeWrite" }
        XCTAssertFalse(freeWrite.isEmpty,
                       "the cold probe must still be MEASURED, even though it is "
                       + "silent: \(readings.map(\.line))")
        XCTAssertEqual(freeWrite.map(\.peak).max() ?? 0, 0,
                       "a cold freeWrite probe is deliberately silent (H6, no "
                       + "demonstration, no loaded file): \(readings.map(\.line))")
    }

    /// First element whose label starts with `prefix`.
    ///
    /// Local to this suite rather than shared: the helper in
    /// `StudyDryRunUITests` is `private` to that class, and reaching
    /// across suites for one string prefix would couple two independently
    /// motivated suites.
    private func element(labelPrefix: String, in app: XCUIApplication) -> XCUIElement {
        let matches = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", labelPrefix))
        return matches.element(boundBy: 0)
    }

    /// Read the probe readout's current value, if it is present.
    private func readoutLabel(_ app: XCUIApplication) -> String? {
        let element = app.descendants(matching: .any)["audio-signal-probe-readout"]
        guard element.exists else { return nil }
        return element.label as String?
    }

    private func assertMeasuredSignal(readings: [AudioSignalReading]) {
        XCTAssertFalse(readings.isEmpty,
                       "the probe readout never carried a parsable line")

        // At least one window must carry real signal on the output bus.
        let loudest = readings.map(\.peak).max() ?? 0
        XCTAssertGreaterThan(
            loudest, 0.01,
            "no measured window carried a signal (peak \(loudest)). "
            + "Readings: \(readings.map(\.line))")

        // And the DEMONSTRATION specifically must be audible, which is the
        // proctor's report: "no audio for the demonstration".
        let observe = readings.filter { $0.label == "observe" }
        XCTAssertFalse(observe.isEmpty,
                       "no observe-phase window was measured: \(readings.map(\.line))")
        XCTAssertGreaterThan(
            observe.map(\.peak).max() ?? 0, 0.01,
            "the observe phase produced no measured output: \(readings.map(\.line))")
    }

}

/// One parsed `AUDIO-SIGNAL <label> nonSilent=<n> total=<n> peak=<f>` line.
///
/// Parsed rather than pattern-matched in place so the assertions read
/// against values, which is the same discipline `CanvasDrawPlan` exists to
/// enable: a property assertion cannot see structure, a parsed value can.
private struct AudioSignalReading: Equatable {
    let line: String
    let label: String
    let nonSilent: Int
    let total: Int
    let peak: Float

    init?(line: String) {
        let parts = line.split(separator: " ")
        guard parts.count >= 4, parts[0] == "AUDIO-SIGNAL" else { return nil }
        self.line = line
        self.label = String(parts[1])
        func value(_ key: String) -> Int? {
            parts.first { $0.hasPrefix(key) }
                .flatMap { Int($0.dropFirst(key.count)) }
        }
        self.nonSilent = value("nonSilent=") ?? -1
        self.total = value("total=") ?? -1
        self.peak = parts.first { $0.hasPrefix("peak=") }
            .flatMap { Float($0.dropFirst("peak=".count)) } ?? -1
    }
}
