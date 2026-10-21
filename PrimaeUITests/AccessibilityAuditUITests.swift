// AccessibilityAuditUITests.swift
// PrimaeUITests
//
// Automated half of ROADMAP U10 ("Accessibility audit"): runs
// `XCUIApplication.performAccessibilityAudit()` on every screen the STUDY
// build can reach, then again at the largest accessibility Dynamic Type size
// (`AccessibilityAuditXXXLUITests`). It also records, per screen, the
// accessibility-tree order (type, identifier, label, frame) as an attachment
// — a proxy for VoiceOver focus order, NOT a substitute for it: the snapshot
// lists the tree in hierarchy order, while VoiceOver orders by frame/
// `accessibilityElements`.
//
// REACHABLE IN THE STUDY BUILD (everything else is `#if !STUDY_BUILD` and not
// in the binary, so it cannot be audited here): the blocked-start gate, the
// Schule world in observe / direct / guided / freeWrite, the rail (with the
// double-tap "Nächstes Kind" reveal), the parent area (Forschungs-Daten,
// Einstellungen, Datenexport), the "Neuer Teilnehmer" confirm + ready alert.
// NOT reachable: Onboarding, Werkstatt, Fortschritte, the Parent Dashboard
// ("Übersicht"), the celebration overlay and its "Weiter" button.
//
// THE KNOWN-FINDINGS LIST. An audit issue that is left unfixed because the fix
// changes pixels (contrast, size, layout, clipping) is a VISUAL change and
// needs David's approval first (CLAUDE.md visual approval gate). Each such
// issue is listed in `knownVisualFindings` with the screen, the audit type and
// a reason, so the test is green AND still fails on any NEW issue. A false
// positive is listed the same way, with the reason it is false. Nothing is
// ignored without a written reason.

import XCTest
import Foundation

class AccessibilityAuditUITests: XCTestCase {

    /// `nil` = the simulator's default. The XXXL subclass overrides this.
    var contentSizeCategory: String? { nil }
    var sizeTag: String { "default" }

    /// Issues already triaged as VISUAL (not fixed here) or false positives.
    /// Matching is on the screen name, the audit type name and a substring of
    /// the audit's own description. EVERY entry needs a `reason`.
    struct KnownFinding {
        let screen: String          // prefix of the screen name
        let typeRaw: UInt           // XCUIAccessibilityAuditType.rawValue
        let elementContains: String // substring of the element's label ("" = any)
        let reason: String
    }
    var knownVisualFindings: [KnownFinding] { Self.triaged }

    /// Audit-type raw values (measured on iOS 27.2, 2026-10-21).
    static let contrast: UInt = 1, elementDetection: UInt = 2, hitRegion: UInt = 4
    static let dynamicType: UInt = 65536, textClipped: UInt = 131072

    private static let childScreens = ["01", "02", "03", "05", "06", "19"]
    private static let dialogScreens = ["02b", "17", "18"]

    /// TRIAGE, 2026-10-21 (device run, iPad 00008103…, iOS 27.2). Every entry is
    /// either a VISUAL change awaiting David's approval (the receipt names it)
    /// or a false positive with the reason. Types NOT listed here (missing
    /// labels, traits, parent/child, actions) still fail the test.
    private static let triaged: [KnownFinding] = {
        var list: [KnownFinding] = []
        for screen in childScreens {
            list.append(KnownFinding(screen: screen, typeRaw: hitRegion, elementContains: "Lernphase",
                reason: "VISUAL: the phase indicator is a 74×12 pt status element (no action); enlarging its frame changes the pill's size."))
            for type in [contrast, textClipped, dynamicType] {
                list.append(KnownFinding(screen: screen, typeRaw: type, elementContains: "👆",
                    reason: "VISUAL: the 👆 turn cue is a fixed-size 36 pt emoji glyph (no text); scaling/contrast changes pixels. It is also marked accessibilityHidden."))
            }
        }
        list.append(KnownFinding(screen: "03", typeRaw: contrast, elementContains: "",
            reason: "VISUAL, UNATTRIBUTED: the audit names no element on the observe screen; the only coloured chrome there is the 👁️ capsule on Color.brand. Contrast needs a design decision."))
        for screen in dialogScreens {
            list.append(KnownFinding(screen: screen, typeRaw: dynamicType, elementContains: "",
                reason: "System confirmationDialog/alert text: sizes are owned by UIKit; nothing in app code sets them."))
            list.append(KnownFinding(screen: screen, typeRaw: elementDetection, elementContains: "",
                reason: "System alert/dialog: 'potentially inaccessible text' is reported with no element; UIKit-owned."))
        }
        // Proctor-facing parent area (Forschungs-Daten, Einstellungen, Datenexport):
        // contrast / Dynamic Type / clipping are visual by definition.
        for screen in ["10", "11", "12", "13", "14", "15", "16", "17", "18"] {
            for type in [contrast, dynamicType, textClipped] {
                list.append(KnownFinding(screen: screen, typeRaw: type, elementContains: "",
                    reason: "VISUAL (proctor-facing parent area): contrast, fixed fonts and nav-title clipping need a design change, listed in the receipt."))
            }
        }
        return list
    }()

    private var issuesSeen: [String] = []
    private var orderLog: [String] = []

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    override func tearDown() {
        attachText(issuesSeen.joined(separator: "\n"), name: "audit-issues-\(sizeTag)")
        attachText(orderLog.joined(separator: "\n"), name: "element-order-\(sizeTag)")
        super.tearDown()
    }

    // MARK: - Tests

    /// A cold device has no participant: the screen a proctor sees first.
    @MainActor
    func testBlockedStartGate() throws {
        let app = launch()
        let gate = app.staticTexts["Studie kann nicht starten"]
        // The gate only exists while NO participant is enrolled. A device that
        // has run a session (the pilot iPad) is enrolled and cannot be reset
        // without wiping it, so this is skipped, not passed: the gate screen
        // is then UNAUDITED (receipt §1).
        try XCTSkipUnless(gate.waitForExistence(timeout: 20),
                          "a participant is already enrolled; the start gate is not on screen")
        try audit(app, screen: "01-gate")
    }

    /// Enrol through the rail, then walk the child-facing session.
    ///
    /// MEASURED on the iPad 2026-10-21: a study session runs THREE phases —
    /// Anschauen (observe), Nachspuren (guided), Selbst schreiben (freeWrite).
    /// `direct` ("Richtung lernen", numbered start dots) is not in the study
    /// session's `activePhases`, so there is no direct screen to audit.
    @MainActor
    func testChildSession() throws {
        let app = launch()
        try enrolViaRail(app, auditDialogs: true)

        // Observe is short and already running when enrolment returns: the
        // full-screen "Beobachtungsphase" element is its screen.
        if element(label: "Beobachtungsphase", in: app).exists {
            try audit(app, screen: "03-schule-observe")
        } else {
            attachText("observe had already ended", name: "observe-missed-\(sizeTag)")
        }

        XCTAssertTrue(waitForPhase(app, "Nachspuren", timeout: 40),
                      "observe should advance to guided by itself")
        try audit(app, screen: "05-schule-guided")

        // Best effort: trace the letter so the natural session reaches
        // freeWrite. The fallback (the parent-area cold probe in
        // `testParentArea`) reaches freeWrite without a trace.
        traceCurrentLetter(app)
        if waitForPhase(app, "Selbst schreiben", timeout: 15) {
            try audit(app, screen: "06-schule-freewrite-natural")
        } else {
            attachText("guided trace did not reach freeWrite; see testParentArea for the probe route",
                       name: "freewrite-natural-not-reached-\(sizeTag)")
        }
    }

    /// Parent area, dashboards, export, the new-child confirm, and the
    /// cold-probe freeWrite screen.
    @MainActor
    func testParentArea() throws {
        let app = launch()
        try enrolViaRail(app, auditDialogs: false)
        openParentArea(app)

        // Research dashboard is the STUDY_BUILD default selection.
        XCTAssertTrue(element(labelPrefix: "Vortest starten: A", in: app).waitForExistence(timeout: 10))
        try audit(app, screen: "10-parent-research-top")
        scrollAndAudit(app, screen: "11-parent-research-scrolled", swipes: 2)
        scrollAndAudit(app, screen: "12-parent-research-scrolled2", swipes: 2)

        tap(label: "Einstellungen", in: app)
        try audit(app, screen: "13-parent-settings-top")
        scrollAndAudit(app, screen: "14-parent-settings-scrolled", swipes: 3)
        scrollAndAudit(app, screen: "15-parent-settings-scrolled2", swipes: 3)

        tap(label: "Datenexport", in: app)
        XCTAssertTrue(element(label: "CSV exportieren", in: app).waitForExistence(timeout: 5))
        try audit(app, screen: "16-parent-export")

        tap(label: "Forschungs-Daten", in: app)
        // The confirm dialog and the ready alert (the dashboard path keeps
        // the modal alert). The sim is disposable, so confirming is fine.
        let newParticipant = element(label: "Neuer Teilnehmer", in: app)
        if !newParticipant.waitForExistence(timeout: 5) {
            _ = scrollTo(label: "Neuer Teilnehmer", in: app)
        }
        XCTAssertTrue(newParticipant.exists, "Neuer Teilnehmer must exist on the research dashboard")
        newParticipant.tap()
        let confirm = element(label: "Neues Kind starten", in: app)
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        // At AX-XXXL this used to be unreachable (popover 288×960 with the
        // button at y=812…1044 on a 1024 pt screen, `not hittable`): the
        // confirm now keeps its buttons pinned (`NextParticipantControl`, U10
        // follow-up). Must hold at EVERY size, so it fails here on regression.
        // Asserted BEFORE the audit: the audit's own gestures can dismiss a sheet.
        XCTAssertTrue(confirm.isHittable,
                      "'Neues Kind starten' must be hittable at \(sizeTag); frame=\(confirm.frame)")
        // `isHittable` alone did not fire under the mutation (the system dialog's button,
        // off screen at y=1655, still reported hittable until the tap failed), so also
        // require the button's frame to lie inside the window.
        XCTAssertTrue(app.windows.firstMatch.frame.contains(confirm.frame),
                      "'Neues Kind starten' must lie on screen at \(sizeTag); frame=\(confirm.frame), window=\(app.windows.firstMatch.frame)")
        try audit(app, screen: "17-parent-new-child-confirm")
        if !confirm.waitForExistence(timeout: 3) {
            attachText("the audit dismissed the confirm; reopening", name: "confirm-dismissed-by-audit-\(sizeTag)")
            newParticipant.tap()
            XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        }
        confirm.tap()
        let readyOK = app.alerts["Neues Kind bereit"].buttons["OK"]
        XCTAssertTrue(readyOK.waitForExistence(timeout: 5))
        try audit(app, screen: "18-parent-new-child-ready-alert")
        readyOK.tap()

        // Cold pretest probe: closes the parent area onto freeWrite.
        let pretest = element(labelPrefix: "Vortest starten: A", in: app)
        if !pretest.waitForExistence(timeout: 10) {
            _ = scrollTo(labelPrefix: "Vortest starten: A", in: app)
        }
        XCTAssertTrue(pretest.exists)
        pretest.tap()
        XCTAssertTrue(waitForPhase(app, "Selbst schreiben", timeout: 15),
                      "the cold probe should land in freeWrite")
        try audit(app, screen: "19-schule-freewrite-probe")
    }

    // MARK: - Launch & navigation

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        if let category = contentSizeCategory {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", category]
        }
        app.launch()
        return app
    }

    /// Double-tap the rail → "Nächstes Kind" → confirm → toast. The
    /// confirm dialog and the revealed rail are audited when asked.
    @MainActor
    private func enrolViaRail(_ app: XCUIApplication, auditDialogs: Bool) throws {
        let rail = element(label: "Navigationsleiste", in: app)
        XCTAssertTrue(rail.waitForExistence(timeout: 20), "the rail must be on screen")
        rail.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap()
        let next = element(label: "Nächstes Kind", in: app)
        XCTAssertTrue(next.waitForExistence(timeout: 5), "double-tap must reveal 'Nächstes Kind'")
        if auditDialogs { try audit(app, screen: "02a-gate-rail-revealed") }
        next.tap()
        let confirm = element(label: "Neues Kind starten", in: app)
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        if auditDialogs { try audit(app, screen: "02b-rail-new-child-confirm") }
        confirm.tap()
        XCTAssertTrue(app.descendants(matching: .any)["newChildReadyToast"].waitForExistence(timeout: 5),
                      "the ready toast should appear")
        if auditDialogs { try audit(app, screen: "02c-rail-ready-toast") }
        XCTAssertTrue(app.staticTexts["Studie kann nicht starten"].waitForNonExistence(timeout: 20),
                      "enrolling must clear the start gate")
    }

    private func openParentArea(_ app: XCUIApplication) {
        let gear = element(labelPrefix: "Eltern-Bereich", in: app)
        XCTAssertTrue(gear.waitForExistence(timeout: 10))
        gear.press(forDuration: 2.3)
        XCTAssertTrue(element(label: "Datenexport", in: app).waitForExistence(timeout: 8),
                      "the parent area sidebar should be visible")
    }

    private func tap(label: String, in app: XCUIApplication) {
        let e = element(label: label, in: app)
        XCTAssertTrue(e.waitForExistence(timeout: 8), "'\(label)' must exist")
        e.tap()
    }

    @discardableResult
    private func scrollTo(label: String, in app: XCUIApplication, swipes: Int = 8) -> XCUIElement {
        let target = element(label: label, in: app)
        for _ in 0..<swipes {
            if target.exists { return target }
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.4)
        }
        return target
    }

    @discardableResult
    private func scrollTo(labelPrefix: String, in app: XCUIApplication, swipes: Int = 8) -> XCUIElement {
        let target = element(labelPrefix: labelPrefix, in: app)
        for _ in 0..<swipes {
            if target.exists { return target }
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.4)
        }
        return target
    }

    /// Swipe up `swipes` times, then audit what is on screen.
    @MainActor
    private func scrollAndAudit(_ app: XCUIApplication, screen: String, swipes: Int) {
        for _ in 0..<swipes {
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.4)
        }
        try? audit(app, screen: screen)
    }

    // MARK: - Session driving

    /// True once the phase indicator ("Lernphase <name>") names `phase`.
    private func waitForPhase(_ app: XCUIApplication, _ phase: String, timeout: TimeInterval) -> Bool {
        let target = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Lernphase \(phase)")).firstMatch
        return target.waitForExistence(timeout: timeout)
    }

    /// Chained straight drags through a downsampled polyline of the current
    /// letter (see `LetterPolylines`). Best effort.
    @MainActor
    private func traceCurrentLetter(_ app: XCUIApplication) {
        let prefix = "Aktueller Buchstabe "
        let pill = element(labelPrefix: prefix, in: app)
        guard pill.waitForExistence(timeout: 5) else { return }
        let letter = String(pill.label.dropFirst(prefix.count))
        guard let strokes = LetterPolylines.table[letter] else {
            attachText("no polyline for letter \(letter)", name: "trace-skipped-\(sizeTag)")
            return
        }
        let canvas = element(labelPrefix: "Schreibfläche", in: app)
        guard canvas.waitForExistence(timeout: 5) else { return }
        for stroke in strokes {
            guard let first = stroke.first, let last = stroke.last else { continue }
            let from = canvas.coordinate(withNormalizedOffset: CGVector(dx: first.0, dy: first.1))
            if LetterPolylines.isNearlyStraight(stroke) {
                // One continuous touch: a chain of separate touches did not
                // advance the tracker on the device (measured 2026-10-21).
                let to = canvas.coordinate(withNormalizedOffset: CGVector(dx: last.0, dy: last.1))
                from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0)
            } else {
                for (a, b) in zip(stroke, stroke.dropFirst()) {
                    let p = canvas.coordinate(withNormalizedOffset: CGVector(dx: a.0, dy: a.1))
                    let q = canvas.coordinate(withNormalizedOffset: CGVector(dx: b.0, dy: b.1))
                    p.press(forDuration: 0.05, thenDragTo: q)
                }
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
    }

    // MARK: - Audit & records

    @MainActor
    private func audit(_ app: XCUIApplication, screen: String) throws {
        record(app, screen: screen)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "\(screen)-\(sizeTag)"
        shot.lifetime = .keepAlways
        add(shot)

        var unexpected: [String] = []
        try app.performAccessibilityAudit(for: .all) { issue in
            let line = "\(screen) [\(self.sizeTag)] | \(issue.auditType) | "
                + "\(issue.compactDescription) | "
                + "element: \(Self.describe(issue.element)) | "
                + "detail: \(issue.detailedDescription)"
            self.issuesSeen.append(line)
            if self.knownVisualFindings.contains(where: {
                screen.hasPrefix($0.screen)
                    && issue.auditType.rawValue == $0.typeRaw
                    && ($0.elementContains.isEmpty
                        || (issue.element?.label ?? "").contains($0.elementContains))
            }) { return true }
            unexpected.append(line)
            return true   // collected; judged below so one run lists them all
        }
        XCTAssertTrue(unexpected.isEmpty,
                      "\(unexpected.count) untriaged accessibility issue(s) on \(screen):\n"
                      + unexpected.joined(separator: "\n"))
    }

    private static func describe(_ element: XCUIElement?) -> String {
        guard let element else { return "<none>" }
        return "\(typeName(element.elementType)) id='\(element.identifier)' label='\(element.label)' frame=\(element.frame)"
    }

    /// Depth-first dump of the accessibility tree: one line per node that
    /// carries a label, value or identifier, or is interactive.
    @MainActor
    private func record(_ app: XCUIApplication, screen: String) {
        orderLog.append("== \(screen) [\(sizeTag)] ==")
        guard let snapshot = try? app.snapshot() else {
            orderLog.append("  <snapshot failed>")
            return
        }
        var index = 0
        func walk(_ node: XCUIElementSnapshot, depth: Int) {
            let interactive: Set<XCUIElement.ElementType> = [.button, .link, .slider, .switch, .textField, .picker, .cell]
            let hasText = !node.label.isEmpty || !node.identifier.isEmpty
                || ((node.value as? String)?.isEmpty == false)
            if hasText || interactive.contains(node.elementType) {
                index += 1
                let f = node.frame
                orderLog.append(String(
                    format: "%@%3d %@ id='%@' label='%@' value='%@' frame=(%.0f,%.0f %.0fx%.0f)",
                    String(repeating: "  ", count: depth), index,
                    Self.typeName(node.elementType), node.identifier, node.label,
                    (node.value as? String) ?? "", f.minX, f.minY, f.width, f.height))
            }
            if ["Nächstes Kind", "👆", "Eltern-Bereich"].contains(node.label) {
                orderLog.append("      attrs: \(node.dictionaryRepresentation)")
            }
            for child in node.children { walk(child, depth: depth + 1) }
        }
        walk(snapshot, depth: 0)
    }

    private static func typeName(_ type: XCUIElement.ElementType) -> String {
        switch type {
        case .application: return "application"
        case .window: return "window"
        case .button: return "button"
        case .staticText: return "staticText"
        case .image: return "image"
        case .other: return "other"
        case .alert: return "alert"
        case .sheet: return "sheet"
        case .popover: return "popover"
        case .cell: return "cell"
        case .table: return "table"
        case .collectionView: return "collectionView"
        case .scrollView: return "scrollView"
        case .navigationBar: return "navigationBar"
        case .switch: return "switch"
        case .textField: return "textField"
        case .picker: return "picker"
        case .link: return "link"
        case .slider: return "slider"
        case .toolbar: return "toolbar"
        default: return "type\(type.rawValue)"
        }
    }

    private func attachText(_ text: String, name: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Element lookup (label-based, as in the sibling suites)

    private func element(label: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func element(labelPrefix: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", labelPrefix)).firstMatch
    }
}

/// Pins the non-visual accessibility fixes made from the U10 audit, so they
/// can fail (mutation-checked: remove the fix, this goes red).
final class AccessibilityFixesUITests: XCTestCase {

    /// The parent-area gear carries a long-press only. It was exposed as an
    /// `Image` (measured on the iPad, 2026-10-21); VoiceOver then announces no
    /// control. It must be a button.
    @MainActor
    func testParentAreaGearIsExposedAsAButton() {
        let app = XCUIApplication()
        app.launch()
        let gear = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Eltern-Bereich")).firstMatch
        XCTAssertTrue(gear.waitForExistence(timeout: 20), "the gear must exist")
        XCTAssertEqual(gear.elementType, .button,
                       "the parent-area gear must be exposed as a button, not \(gear.elementType.rawValue)")
    }
}

/// The largest accessibility Dynamic Type size. Same tests, same screens.
final class AccessibilityAuditXXXLUITests: AccessibilityAuditUITests {
    override var contentSizeCategory: String? { "UICTContentSizeCategoryAccessibilityXXXL" }
    override var sizeTag: String { "AX-XXXL" }
}

/// Downsampled stroke polylines (normalised 0…1 of the canvas) for the
/// letters a study subset can contain, taken from
/// `PrimaeNative/Resources/Letters/Regular/<L>/strokes.json`. A UI test
/// cannot read the repo, so they are inlined; they only need to be close
/// enough to pass the checkpoint radius (0.1).
private enum LetterPolylines {
    /// True when every point lies within 0.04 (normalised) of the chord.
    static func isNearlyStraight(_ stroke: [(Double, Double)]) -> Bool {
        guard let a = stroke.first, let b = stroke.last else { return true }
        let dx = b.0 - a.0, dy = b.1 - a.1
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0 else { return true }
        return stroke.allSatisfy { p in
            abs(dy * (p.0 - a.0) - dx * (p.1 - a.1)) / length < 0.04
        }
    }

    static let table: [String: [[(Double, Double)]]] = [
        "A": [
            [(0.583, 0.031), (0.516, 0.150), (0.448, 0.269), (0.381, 0.388), (0.313, 0.506), (0.259, 0.602), (0.192, 0.721), (0.125, 0.840), (0.058, 0.959)],
            [(0.587, 0.039), (0.632, 0.156), (0.676, 0.274), (0.721, 0.391), (0.766, 0.508), (0.801, 0.602), (0.846, 0.719), (0.891, 0.836), (0.936, 0.953)],
            [(0.286, 0.588), (0.351, 0.588), (0.417, 0.589), (0.483, 0.589), (0.549, 0.590), (0.601, 0.591), (0.667, 0.590), (0.733, 0.589), (0.798, 0.588)],
        ],
        "F": [
            [(0.190, 0.040), (0.176, 0.157), (0.162, 0.273), (0.147, 0.390), (0.133, 0.506), (0.121, 0.599), (0.107, 0.716), (0.093, 0.832), (0.078, 0.949)],
            [(0.190, 0.041), (0.286, 0.041), (0.383, 0.041), (0.479, 0.041), (0.575, 0.040), (0.652, 0.039), (0.748, 0.039), (0.844, 0.039), (0.940, 0.040)],
            [(0.150, 0.480), (0.231, 0.480), (0.312, 0.480), (0.392, 0.480), (0.473, 0.480), (0.538, 0.480), (0.618, 0.480), (0.699, 0.480), (0.780, 0.480)],
        ],
        "I": [
            [(0.710, 0.040), (0.654, 0.156), (0.599, 0.272), (0.544, 0.389), (0.489, 0.505), (0.446, 0.599), (0.398, 0.718), (0.354, 0.839), (0.310, 0.960)],
        ],
        "K": [
            [(0.160, 0.040), (0.148, 0.158), (0.136, 0.276), (0.124, 0.394), (0.112, 0.512), (0.102, 0.606), (0.091, 0.724), (0.080, 0.842), (0.070, 0.960)],
            [(0.931, 0.043), (0.847, 0.097), (0.762, 0.150), (0.678, 0.204), (0.594, 0.258), (0.513, 0.310), (0.429, 0.363), (0.345, 0.417), (0.260, 0.470)],
            [(0.260, 0.480), (0.336, 0.543), (0.412, 0.605), (0.489, 0.667), (0.566, 0.728), (0.628, 0.777), (0.705, 0.838), (0.783, 0.899), (0.860, 0.960)],
        ],
        "L": [
            [(0.200, 0.050), (0.184, 0.165), (0.167, 0.280), (0.152, 0.395), (0.138, 0.511), (0.128, 0.603), (0.115, 0.719), (0.102, 0.834), (0.090, 0.950)],
            [(0.090, 0.950), (0.199, 0.950), (0.308, 0.950), (0.417, 0.950), (0.526, 0.950), (0.613, 0.950), (0.722, 0.950), (0.831, 0.950), (0.940, 0.950)],
        ],
        "M": [
            [(0.050, 0.957), (0.117, 0.492), (0.206, 0.050), (0.355, 0.495), (0.506, 0.889), (0.695, 0.480), (0.894, 0.055), (0.935, 0.482), (0.949, 0.951)],
        ],
        "O": [
            [(0.540, 0.040), (0.222, 0.167), (0.070, 0.476), (0.132, 0.813), (0.437, 0.956), (0.750, 0.853), (0.928, 0.558), (0.888, 0.217), (0.600, 0.040)],
        ],
    ]
}
