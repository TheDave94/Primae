// StudyDryRunUITests.swift
// PrimaeUITests
//
// Automates the parts of docs/STUDY_DEVICE_DRYRUN.md that a UI test
// actually CAN drive: enrolment, the Vortest/Post-Test/Nachtest flow, a
// session completing, a second enrolment preserving the first
// participant, and the export containing both. These are the things
// that have broken silently on this project (the letter-set load, the
// cold-probe silent refusal, the participant-archive path) — worth a
// test that can fail, not a procedure a human re-reads and might not
// notice deviate.
//
// Deliberately does NOT test: pencil-specific input (pressure/azimuth —
// this suite drives the canvas with plain coordinate touches, which
// TouchDispatcher accepts identically to a finger; see the guard shape
// in TouchDispatcher.swift), palm rejection, physical audio output, or
// the three-finger proctor gesture. Those stay David's, on-device — see
// docs/STUDY_DEVICE_DRYRUN.md's own coverage table.
//
// This target is a SEPARATE .xctest bundle (product type
// com.apple.product-type.bundle.ui-testing) that drives the real
// Primae.app process via the accessibility tree — XCTest links it into
// no app target, and it ships nothing into the study binary. It imports
// only XCTest, never PrimaeNative — every interaction goes through the
// same accessibility surface a proctor or VoiceOver would use, not
// through @testable internals.

import XCTest

final class StudyDryRunUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// One continuous session, matching what actually happens on the
    /// study binary: `resetForNewParticipant()` reapplies the new
    /// participant's identity IN PLACE under studyMode (TracingViewModel
    /// .swift's `reapplyParticipantIdentity`) — the "Neustart
    /// erforderlich" alert text is shown regardless, but no real
    /// relaunch is required, and this test does not perform one.
    @MainActor
    func testEnrolmentProbeCompletionSecondEnrolmentExport() throws {
        let app = XCUIApplication()
        app.launch()

        openParentArea(app)

        XCTContext.runActivity(named: "1 — enrolment") { _ in
            enrolNewParticipant(app)
            // Lands back on the research dashboard (ParentAreaView's
            // STUDY_BUILD default selection is .research) after the
            // relaunch alert's OK — confirm we're still inside the
            // parent area, on a screen that can see the probe buttons.
            XCTAssertTrue(
                waitFor(label: "Vortest starten: A", in: app, timeout: 10),
                "expected the research dashboard's pretest buttons to be visible after enrolment"
            )
        }

        XCTContext.runActivity(named: "2 — the Vortest/Post-Test/Nachtest flow") { _ in
            let pretestA = element(labelPrefix: "Vortest starten: A", in: app)
            XCTAssertTrue(pretestA.waitForExistence(timeout: 5), "Vortest button for letter A must exist")
            pretestA.tap()
            // A successful cold probe calls onLeaveParentArea() (f08d997,
            // this session) — the parent area's own root dismisses and
            // the canvas becomes visible. A refusal instead shows the
            // "Test kann nicht starten" alert (a5af108) — fail loudly if
            // that's what happened, rather than silently timing out.
            let refusalAlert = app.alerts["Test kann nicht starten"]
            if refusalAlert.waitForExistence(timeout: 3) {
                let message = refusalAlert.staticTexts.element(boundBy: 1).label
                XCTFail("pretest for letter A was refused: \(message)")
            }
            XCTAssertTrue(
                waitFor(labelDisappear: "Vortest starten: A", in: app, timeout: 10),
                "the parent area should have closed onto the canvas after a successful pretest"
            )
        }

        XCTContext.runActivity(named: "3 — a session completing") { _ in
            // The pretest lands cold in freeWrite (resume(at: .freeWrite),
            // TracingViewModel.swift). Completion needs only >=2 points
            // then a lift-then-2s-quiet window (TouchDispatcher.swift:
            // endTouch/scheduleFreeWriteAutoAdvance) — study mode never
            // retries on a low-confidence pass (PhaseTransitionCoordinator
            // .completePostFreeWriteRecognition), so any real drag
            // completes the session regardless of drawn shape.
            drawFreeWriteStroke(app)
            // PhaseDotIndicator's accessibilityValue is unconditional
            // (not studyMode-gated) and reports "N von 4 abgeschlossen".
            // A cold probe only ever completes the one phase it landed
            // in, so the expected value is exactly 1.
            let phaseIndicator = element(labelPrefix: "Lernphase", in: app)
            let deadline = Date().addingTimeInterval(8)   // > 2.0s quiet window + scoring
            var value = phaseIndicator.value as? String ?? ""
            while Date() < deadline, value != "1 von 4 abgeschlossen" {
                Thread.sleep(forTimeInterval: 0.5)
                value = phaseIndicator.value as? String ?? ""
            }
            XCTAssertEqual(value, "1 von 4 abgeschlossen",
                            "the pretest freeWrite pass should have completed and advanced the phase indicator")
        }

        openParentArea(app)

        XCTContext.runActivity(named: "4 — a second enrolment preserving the first participant") { _ in
            enrolNewParticipant(app)
        }

        XCTContext.runActivity(named: "5 — the export containing both") { _ in
            let exportLink = element(label: "Datenexport", in: app)
            XCTAssertTrue(exportLink.waitForExistence(timeout: 5), "Datenexport sidebar entry must exist")
            exportLink.tap()

            let countText = element(labelContains: "Teilnehmer aktuell gespeichert", in: app)
            XCTAssertTrue(countText.waitForExistence(timeout: 5), "the participant-count hint must be visible")
            let count = participantCount(fromHint: countText.label)
            XCTAssertGreaterThanOrEqual(
                count, 2,
                "expected at least the two explicitly-enrolled participants to still be counted, got \(count) from '\(countText.label)'"
            )

            let csvButton = element(label: "CSV exportieren", in: app)
            XCTAssertTrue(csvButton.waitForExistence(timeout: 5))
            csvButton.tap()

            // The share sheet appearing proves ParentDashboardExporter
            // .combinedExportFileURL() succeeded synchronously (export(
            // format:) in ParentAreaView.swift only presents it on
            // success) — read the file it wrote and verify content, not
            // just that a sheet appeared.
            XCTAssertTrue(
                waitForShareSheet(app, timeout: 5),
                "the export share sheet should appear after a successful export"
            )
            let csv = try readNewestExportFile(extension: "csv")
            let distinctParticipants = distinctParticipantIDs(inCSV: csv)
            XCTAssertGreaterThanOrEqual(
                distinctParticipants.count, 2,
                "expected the export to contain rows for at least 2 distinct participant IDs, found \(distinctParticipants.count)"
            )
            XCTAssertTrue(
                csv.contains("freeWrite") || csv.contains("phase"),
                "expected the export to contain at least one real phase row from the completed pretest, not just header/empty rows"
            )
        }
    }

    // MARK: - Flow helpers

    private func openParentArea(_ app: XCUIApplication) {
        let gear = element(label: "Eltern-Bereich", in: app)
        XCTAssertTrue(gear.waitForExistence(timeout: 10), "the parent-area gear must be reachable")
        // 2.0s minimumDuration (WorldSwitcherRail.swift) + margin.
        gear.press(forDuration: 2.3)
        XCTAssertTrue(
            waitFor(label: "Datenexport", in: app, timeout: 5),
            "the parent-area sidebar should be visible after the gear long-press"
        )
    }

    /// Drives the "Neuer Teilnehmer" flow to completion: tap -> dismiss
    /// the pre-wipe export share sheet -> confirm the destructive dialog
    /// -> dismiss the relaunch alert. See ResearchDashboardView.swift's
    /// own ordering comment: export strictly precedes the wipe.
    private func enrolNewParticipant(_ app: XCUIApplication) {
        let newParticipant = element(label: "Neuer Teilnehmer", in: app)
        XCTAssertTrue(newParticipant.waitForExistence(timeout: 5), "Neuer Teilnehmer button must exist")
        newParticipant.tap()

        XCTAssertTrue(waitForShareSheet(app, timeout: 5), "the pre-wipe export share sheet should appear")
        dismissShareSheet(app)

        let confirm = element(label: "Löschen & neu starten", in: app)
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "the destructive confirm dialog should appear after the share sheet closes")
        confirm.tap()

        let relaunchOK = app.alerts["Neustart erforderlich"].buttons["OK"]
        XCTAssertTrue(relaunchOK.waitForExistence(timeout: 5), "the relaunch alert should appear")
        relaunchOK.tap()
    }

    /// A short drag anywhere in the canvas area. `beginTouch`/`endTouch`
    /// (TouchDispatcher.swift) don't care about touch type, only that
    /// `freeWritePoints.count >= 2` before the lift.
    private func drawFreeWriteStroke(_ app: XCUIApplication) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.55))
        start.press(forDuration: 0.15, thenDragTo: end)
    }

    // MARK: - Element lookup (label/text only — no accessibilityIdentifier
    // exists anywhere in this codebase today, per a full-repo grep before
    // writing this file; adding one would be new app-reaching surface
    // for a test to depend on, which this suite deliberately avoids)

    private func element(label: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func element(labelPrefix: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", labelPrefix)).firstMatch
    }

    private func element(labelContains: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", labelContains)).firstMatch
    }

    private func waitFor(label: String, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        element(label: label, in: app).waitForExistence(timeout: timeout)
    }

    private func waitFor(labelDisappear label: String, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate { _, _ in !self.element(label: label, in: app).exists }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// UIActivityViewController on iPad presents as a popover; detecting
    /// it robustly (rather than guessing a locale-specific "Cancel"
    /// label) means checking for ANY new sheet/popover-class element —
    /// the presence of the activity list itself is enough.
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

    /// Dismiss a UIActivityViewController without depending on a
    /// locale-specific "Cancel"/"Abbrechen" label: tap a point clearly
    /// outside the sheet/popover's content (top-left corner), which
    /// dismisses either presentation style on iPad.
    private func dismissShareSheet(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.02)).tap()
    }

    // MARK: - Export file verification (simulator only — this test target
    // never builds into the study binary; reading the app's own sandbox
    // container from the TEST process, via simctl, is the standard way
    // to verify a file an app wrote without a Files-app round trip. The
    // export never reaches ~/Documents (UIFileSharingEnabled doesn't
    // apply to FileManager.default.temporaryDirectory), so this is the
    // only way to check content rather than just "a sheet appeared".)

    private func readNewestExportFile(extension ext: String) throws -> String {
        let container = try simctlAppContainerPath()
        let tmp = container.appendingPathComponent("tmp")
        let files = try FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.pathExtension == ext && $0.lastPathComponent.hasPrefix("primae_progress_ALL_") }
        guard let newest = try files.max(by: {
            let a = try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            let b = try $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            return a < b
        }) else {
            throw NSError(domain: "StudyDryRunUITests", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "no primae_progress_ALL_*.\(ext) file found under \(tmp.path)"])
        }
        return try String(contentsOf: newest, encoding: .utf8)
    }

    private func simctlAppContainerPath() throws -> URL {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "get_app_container", "booted", "com.flamingistan.primae.study", "data"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty, process.terminationStatus == 0 else {
            throw NSError(domain: "StudyDryRunUITests", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "simctl get_app_container failed (status \(process.terminationStatus)): \(path)"])
        }
        return URL(fileURLWithPath: path)
    }

    private func distinctParticipantIDs(inCSV csv: String) -> Set<String> {
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: true)
        guard let header = lines.first else { return [] }
        let columns = header.split(separator: ",").map { $0.trimmingCharacters(in: .init(charactersIn: "\"")) }
        guard let idColumn = columns.firstIndex(where: { $0.localizedCaseInsensitiveContains("participant") }) else {
            return []
        }
        var ids = Set<String>()
        for line in lines.dropFirst() {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard idColumn < fields.count else { continue }
            let value = fields[idColumn].trimmingCharacters(in: .init(charactersIn: "\""))
            if !value.isEmpty { ids.insert(value) }
        }
        return ids
    }

    private func participantCount(fromHint label: String) -> Int {
        // "...(<N> Teilnehmer aktuell gespeichert)..." — extract the
        // integer immediately preceding the marker phrase.
        guard let range = label.range(of: " Teilnehmer aktuell gespeichert") else { return -1 }
        let before = label[..<range.lowerBound]
        let digits = before.reversed().prefix(while: { $0.isNumber }).reversed()
        return Int(String(digits)) ?? -1
    }
}
