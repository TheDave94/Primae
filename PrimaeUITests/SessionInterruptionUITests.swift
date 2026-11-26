// SessionInterruptionUITests.swift
// PrimaeUITests: SDK27 (2026-11-24)
//
// A REAL system interruption on the physical iPad, for the iOS 27 session
// notifications `AudioSessionInterruption` reads. The app runs with
// `-popCapture` (DEBUG only), whose events.tsv logs `session.inactive`
// (didBecomeInactive: source 1 = app, 2 = system) and `session.resumption`
// (recommendation 1 = shouldResume, 0 = shouldNotResume) plus the voice's
// play/stop. The interruption is Siri, raised by XCUITest's own
// `XCUIDevice.siriService` (no human, no alarm). The capture is pulled
// afterwards with `xcrun devicectl device copy from` and read by hand; this
// test asserts only that the flow reached the tracing screen.
//
// It also attaches a screenshot of the tracing screen ("tracing-screen"), the
// on-device look of the registered Primae faces after R-099's async
// registration gate.
//
// Physical iPad only (not in CI), like the rest of PrimaeUITests.

import XCTest

final class SessionInterruptionUITests: XCTestCase {

    override func setUpWithError() throws { continueAfterFailure = true }

    @MainActor func testSiriInterruptionIsLogged() throws {
        let app = XCUIApplication.primaeUnderTest()
        app.launchArguments += [
            LetterTracer.launchArgument,
            "-popCapture", "-popCaptureTag", "sdk27siri",
            "-de.flamingistan.primae.audioConditionOverride", "phoneme",
        ]
        app.launch()
        XCTAssertTrue(app.enrolNextChildViaRail(), "the child must be enrolled")
        var last: TracingHookSnapshot?
        let snap = LetterTracer.waitForSnapshot(app, timeout: 15, last: &last, where: { _ in true })
        XCTAssertNotNil(snap, "the tracing screen never published its geometry")
        if let s = snap, s.parked {
            let observe = app.descendants(matching: .any)["Beobachtungsphase"]
            if observe.waitForExistence(timeout: 5) { observe.tap() }
        }
        Thread.sleep(forTimeInterval: 1.0)   // observe's demonstration is sounding now
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "tracing-screen"
        shot.lifetime = .keepAlways
        add(shot)

        XCUIDevice.shared.siriService.activate(voiceRecognitionText: "Wie spät ist es")
        Thread.sleep(forTimeInterval: 8)
        app.activate()
        Thread.sleep(forTimeInterval: 6)     // a resumption recommendation, if any, arrives here
        let after = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        after.name = "after-siri"
        after.lifetime = .keepAlways
        add(after)
    }

    // MARK: - Real-interruption instrument (SDK27 ruling, 2026-11-24)
    //
    // `XCUIDevice.siriService` never reached the app (no session.inactive in
    // events.tsv), so these raise a real competing audio client instead. Both
    // launch with `-popCapture`; the capture logs the system notifications
    // (`session.inactive`/`session.resumption` on the iOS 27 path,
    // `session.interruption` on the old one) and the voice's own handling
    // (`voice.interruption began intent=… / ended shouldResume=… playing=…`).
    // The capture is pulled with `xcrun devicectl device copy from` and read
    // by hand: these tests assert only that each step was driven.

    /// (a) Voice Memos records for ~4 s while the observe voice sounds.
    @MainActor func testVoiceMemosRecordingInterruptsVoice() throws {
        let app = launchAtTracingScreen(tag: "sdk27vm")
        startObserve(app)
        Thread.sleep(forTimeInterval: 0.6)    // the observe voice is sounding
        let memos = XCUIApplication(bundleIdentifier: "com.apple.VoiceMemos")
        memos.activate()
        let proceed = memos.buttons["Continue"]
        if proceed.waitForExistence(timeout: 3) { proceed.tap() }
        let record = memos.buttons["RecordButton"]
        XCTAssertTrue(record.waitForExistence(timeout: 5), "Voice Memos shows no record button")
        record.tap()
        acceptSystemAlertIfAny()
        Thread.sleep(forTimeInterval: 4)
        attachState(of: memos, as: "voicememos-recording")
        record.tap()                           // the same control stops the recording
        Thread.sleep(forTimeInterval: 2)
        attachState(of: memos, as: "voicememos-stopped")
        app.activate()
        Thread.sleep(forTimeInterval: 8)       // a resumption recommendation, if any, arrives here
        attachState(of: app, as: "after-voicememos")
    }

    /// (b) A Clock timer fires (its alarm sound plays) while Primae is in the
    /// foreground and the observe voice is sounding; then it is dismissed.
    @MainActor func testClockTimerInterruptsVoice() throws {
        let app = launchAtTracingScreen(tag: "sdk27timer")
        let clock = XCUIApplication(bundleIdentifier: "com.apple.mobiletimer")
        clock.activate()
        clock.buttons["Timers"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 1.5)
        let wheels = clock.pickerWheels
        var values = ""
        for k in 0..<wheels.count { values += "\(k): \(wheels.element(boundBy: k).value ?? "nil")\n" }
        let wheelNote = XCTAttachment(string: values)
        wheelNote.name = "clock-wheels"
        wheelNote.lifetime = .keepAlways
        add(wheelNote)
        attachState(of: clock, as: "clock-timers")
        let fireAfter: TimeInterval = 20
        guard wheels.count >= 3 else { XCTFail("Clock's timer shows \(wheels.count) picker wheels"); return }
        setWheel(wheels.element(boundBy: 0), to: 0)
        setWheel(wheels.element(boundBy: 1), to: 0)
        setWheel(wheels.element(boundBy: 2), to: Int(fireAfter))
        let start = clock.buttons["Start"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 3), "Clock shows no Start button")
        start.tap()
        let firesAt = Date().addingTimeInterval(fireAfter)
        app.activate()
        _ = app.descendants(matching: .any)["Beobachtungsphase"].waitForExistence(timeout: 10)
        // Measured on the iPad (2026-11-24): the chevron's load lands ~0.66 s
        // after the tap, the observe voice starts ~2.43 s after the load
        // (after the spoken prompt) and sounds ~3.2 s. Tapping 4 s ahead puts
        // the alarm ~0.9 s into the voice (3 s ahead put it 0.09 s BEFORE
        // the voice, on the prompt). The load is the study chevron, not the
        // observe pill:
        // whether the enrolled letter is still parked when the app comes
        // back from Clock is a race (measured 2026-11-24 on 8bb28162: twice
        // its observe ran on its own ~4.5 s after reactivation, so the pill
        // was gone at T-3 s), while the chevron always loads a fresh,
        // unparked letter whose observe starts on its own.
        let lead = firesAt.timeIntervalSinceNow - 4.0
        if lead > 0 { Thread.sleep(forTimeInterval: lead) }
        let chevron = app.descendants(matching: .any)["Nächster Buchstabe"]
        if chevron.waitForExistence(timeout: 2) { chevron.tap() } else { XCTFail("no study chevron") }
        Thread.sleep(forTimeInterval: 5)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        attachState(of: springboard, as: "timer-fired")
        stopFiredTimer(in: springboard, from: app)
        Thread.sleep(forTimeInterval: 8)       // a resumption recommendation, if any, arrives here
        attachState(of: app, as: "after-timer")
        // After the interruption the voice must still answer the pen: trace
        // the letter in guided (the capture's rt.tsv then shows kernel voice
        // begins after the alarm, or none if the voice stayed dead).
        var last: TracingHookSnapshot?
        if let guided = LetterTracer.waitForSnapshot(app, timeout: 15, last: &last, where: {
            $0.phase == "guided" && !$0.strokes.isEmpty && !$0.blocked
        }) {
            LetterTracer.traceLetter(guided, in: app)
        } else {
            XCTFail("guided never came after the alarm: \(last?.summary ?? "no hook")")
        }
        Thread.sleep(forTimeInterval: 3)
        attachState(of: app, as: "after-trace")
    }

    /// SDK27 check (a): `AudioEngine.init` activates the session
    /// asynchronously. From a COLD launch in each sound arm, the first sound
    /// must still play: the capture shows `session.activate ok=true`,
    /// `engine.gateStart alreadyRunning=false` (the start followed the activation, SDK27 gate), then the observe voice's `audio.play` and kernel
    /// voice begins (rt.tsv K2). Read with the pulled `sdk27cold*` captures.
    @MainActor func testColdLaunchFirstAudioPerArm() throws {
        for arm in ["phoneme", "spatial"] {
            let app = launchAtTracingScreen(tag: "sdk27cold\(arm)", arm: arm)   // launch() ends any running instance
            startObserve(app)
            Thread.sleep(forTimeInterval: 7)   // prompt, then the observe demonstration
            attachState(of: app, as: "cold-\(arm)")
            app.terminate()
            Thread.sleep(forTimeInterval: 2)
        }
    }

    // MARK: Helpers

    @MainActor private func launchAtTracingScreen(tag: String, arm: String = "phoneme") -> XCUIApplication {
        let app = XCUIApplication.primaeUnderTest()
        app.launchArguments += [
            LetterTracer.launchArgument,
            "-popCapture", "-popCaptureTag", tag,
            "-de.flamingistan.primae.audioConditionOverride", arm,
        ]
        app.launch()
        XCTAssertTrue(app.enrolNextChildViaRail(), "the child must be enrolled")
        var last: TracingHookSnapshot?
        let snap = LetterTracer.waitForSnapshot(app, timeout: 15, last: &last, where: { _ in true })
        XCTAssertNotNil(snap, "the tracing screen never published its geometry")
        return app
    }

    @MainActor private func startObserve(_ app: XCUIApplication) {
        let observe = app.descendants(matching: .any)["Beobachtungsphase"]
        if observe.waitForExistence(timeout: 5) { observe.tap() } else { XCTFail("no observe control") }
    }

    /// Replace the wheel value's leading number ("15 minutes" -> "0 minutes").
    @MainActor private func setWheel(_ wheel: XCUIElement, to n: Int) {
        let current = (wheel.value as? String) ?? ""
        let digits = current.prefix { $0.isNumber }
        let target = digits.isEmpty ? "\(n)" : "\(n)" + current.dropFirst(digits.count)
        wheel.adjust(toPickerWheelValue: target)
    }

    /// Stop the fired Clock timer from its springboard banner. The banner's
    /// Stop button (identifier "xmark", label "Stop") exists when queried but
    /// a plain `tap()` re-resolves it at tap time and finds nothing (measured
    /// on the iPad 2026-11-26, deterministic: "No matches found … \"Stop\" IN
    /// identifiers"). Every synthesized event first waits ~60 s for
    /// springboard to idle, which it does not while the alarm rings, so the
    /// re-resolve runs on a banner that has changed by then. `snapshot()` does not contain it either (measured the
    /// same day: three seconds of snapshots, no match), while
    /// `debugDescription`, which also walks the remote banner hierarchy,
    /// lists it every time as `Button, 0x…, {{x, y}, {w, h}}, identifier:
    /// 'xmark', label: 'Stop'`. So the frame is read from a snapshot if it
    /// has it, else from that line, and ONE tap goes to that point by
    /// coordinate, in the APP's space (the same full 1366x1024 landscape
    /// screen as springboard's), with the quiescence waits skipped. The
    /// banner must then be gone.
    @MainActor private func stopFiredTimer(in springboard: XCUIApplication, from app: XCUIApplication) {
        var source = ""
        func snapshotFrame() -> CGRect? {
            guard let root = try? springboard.snapshot() else { return nil }
            var stack: [XCUIElementSnapshot] = [root]
            while let node = stack.popLast() {
                if node.elementType == .button,
                   node.identifier == "xmark" || node.label == "Stop",
                   !node.frame.isEmpty {
                    return node.frame
                }
                stack.append(contentsOf: node.children)
            }
            return nil
        }
        func treeFrame() -> CGRect? {
            let pattern = #"Button, 0x[0-9a-f]+, \{\{([-0-9.]+), ([-0-9.]+)\}, \{([0-9.]+), ([0-9.]+)\}\}, identifier: 'xmark', label: 'Stop'"#
            guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
            let text = springboard.debugDescription
            guard let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
            let v = (1...4).compactMap { Range(m.range(at: $0), in: text).flatMap { Double(text[$0]) } }
            guard v.count == 4, v[2] > 0, v[3] > 0 else { return nil }
            return CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
        }
        func stopFrame() -> CGRect? {
            if let f = snapshotFrame() { source = "snapshot"; return f }
            if let f = treeFrame() { source = "debugDescription"; return f }
            return nil
        }
        var frame: CGRect?
        let deadline = Date().addingTimeInterval(3)
        while frame == nil, Date() < deadline {
            frame = stopFrame()
            if frame == nil { Thread.sleep(forTimeInterval: 0.25) }
        }
        guard let target = frame else { XCTFail("no Stop control for the fired timer"); return }
        let note = XCTAttachment(string: "Stop frame \(target) from \(source)")
        note.name = "stop-frame"
        note.lifetime = .keepAlways
        add(note)
        let started = Date()
        // ONE tap, with XCUITest's quiescence waits switched off, checked at
        // once. Without that, every synthesized event first waits ~60 s for
        // springboard to idle, which it never does while the alarm rings,
        // and the banner expires by itself about 65 s after firing: the
        // check then raced the expiry and passed a tap aimed 500 pt below
        // Stop (measured twice, 2026-11-26: banner still up at 62.3 s in one
        // run, gone at 62.1 s in the next).
        guard withoutQuiescenceWaits({
            app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: target.midX, dy: target.midY)).tap()
        }) else {
            XCTFail("XCUIApplicationProcess quiescence getters not found; cannot tap the banner before it expires")
            return
        }
        Thread.sleep(forTimeInterval: 1)
        let still = stopFrame()
        let check = XCTAttachment(string: String(format: "banner %@ %.1f s after the tap was requested", still == nil ? "gone" : "still up", Date().timeIntervalSince(started)))
        check.name = "stop-check"
        check.lifetime = .keepAlways
        add(check)
        if still != nil {
            attachState(of: springboard, as: "stop-missed")
            XCTFail("the fired timer's Stop banner is still up after the tap")
        }
    }

    /// Run `body` with XCUITest's pre- and post-event quiescence waits
    /// skipped, by overriding the PRIVATE `XCUIApplicationProcess`
    /// `shouldSkipPreEventQuiescence` / `shouldSkipPostEventQuiescence`
    /// getters (XCUIAutomation, Xcode 27.2; the log then reads "Skipping
    /// pre-event quiescence check"). Test-target only, restored afterwards.
    /// Returns false, running nothing, if either getter is missing, so a
    /// future Xcode that renames them fails the caller loudly.
    @MainActor private func withoutQuiescenceWaits(_ body: () -> Void) -> Bool {
        guard let cls = NSClassFromString("XCUIApplicationProcess") else { return false }
        let selectors = ["shouldSkipPreEventQuiescence", "shouldSkipPostEventQuiescence"].map(NSSelectorFromString)
        let methods = selectors.compactMap { class_getInstanceMethod(cls, $0) }
        guard methods.count == selectors.count else { return false }
        let skip: @convention(block) (AnyObject) -> Bool = { _ in true }
        let skipImp = imp_implementationWithBlock(skip)
        let saved = methods.map { method_setImplementation($0, skipImp) }
        defer { for (m, imp) in zip(methods, saved) { method_setImplementation(m, imp) } }
        body()
        return true
    }

    @MainActor private func acceptSystemAlertIfAny() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow", "OK", "Allow While Using App"] {
            let b = springboard.buttons[label]
            if b.waitForExistence(timeout: 1) {
                attachState(of: springboard, as: "system-alert")
                b.tap()
                return
            }
        }
    }

    // MARK: Probe: what the other apps expose

    /// Probe only: open Voice Memos and Clock and attach each one's screen and
    /// accessibility tree, so the interruption tests can target their controls.
    @MainActor func testProbeOtherAppsAccessibility() throws {
        for (bundle, name) in [("com.apple.VoiceMemos", "voicememos"), ("com.apple.mobiletimer", "clock")] {
            let other = XCUIApplication(bundleIdentifier: bundle)
            other.activate()
            Thread.sleep(forTimeInterval: 4)
            attachState(of: other, as: name)
        }
    }

    @MainActor private func attachState(of other: XCUIApplication, as name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "\(name)-screen"
        shot.lifetime = .keepAlways
        add(shot)
        let tree = XCTAttachment(string: other.debugDescription)
        tree.name = "\(name)-tree"
        tree.lifetime = .keepAlways
        add(tree)
    }
}
