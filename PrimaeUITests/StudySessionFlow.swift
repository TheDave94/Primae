// StudySessionFlow.swift
// PrimaeUITests
//
// The protocol r27 session, driven the way a child goes through it, for the
// suites that need to get PAST training (2026-11-23, currency of the UI tests
// against r27): training on the three trained letters, the silent bubble
// pause, then the final test (Abschlusstest) from memory, after which the end
// screen follows. Every letter is drawn along its real strokes
// (`LetterTracer`; never a straight drag).
//
// Reads only what main's `-tracingGeometryHook` publishes (letter, phase,
// probe, strokes, completed sessions) and the accessibility identifiers the
// app sets (`finalTestPause`, `finalTestCheck`). The final test's stage is
// NOT in that hook, so the glimpse's end is inferred: a test letter's strokes
// are traced after the glimpse has had time to hide, and the check button
// (which shows only after an accepted stroke in the writing stage) is the
// proof that the writing reached the app. A trace that landed in the glimpse
// is ignored by the app, so it is traced once more.

import XCTest
import Foundation

enum StudySessionFlow {

    /// The shortest bubble pause the researcher setting allows (30-60 s).
    static let pauseSeconds = 30
    /// The shortest glimpse the researcher setting allows (1-3 s).
    static let glimpseSeconds = 1.0

    /// Launch arguments that keep the pause and the glimpse at the bottom of
    /// their ranges, so a whole session fits a per-class device run.
    static var shortTimingArguments: [String] {
        ["-de.flamingistan.primae.comparison.pauseSeconds", "\(pauseSeconds)",
         "-de.flamingistan.primae.comparison.glimpseSeconds", "\(glimpseSeconds)"]
    }

    /// Train the three trained letters (guided, then free writing), each
    /// completion recorded. Returns the letters in the order trained, or nil
    /// after a failure is recorded. `afterLetter` runs after each letter's
    /// completion, with its 1-based round.
    @MainActor
    static func trainThreeLetters(_ app: XCUIApplication,
                                  afterLetter: (Int, String) -> Void = { _, _ in },
                                  file: StaticString = #filePath, line: UInt = #line) -> [String]? {
        var traced: [String] = []
        var last: TracingHookSnapshot?
        for round in 1...3 {
            guard let guided = LetterTracer.waitForSnapshot(app, timeout: 60, last: &last, where: {
                $0.phase == "guided" && $0.probe.isEmpty && !$0.strokes.isEmpty && !$0.blocked
                    && !traced.contains($0.letter)
            }) else {
                XCTFail("training letter \(round) never reached guided after \(traced): \(last?.summary ?? "no hook")",
                        file: file, line: line)
                return nil
            }
            let letter = guided.letter
            Thread.sleep(forTimeInterval: 1.0)
            LetterTracer.traceLetter(guided, in: app)
            guard let fw = LetterTracer.waitForSnapshot(app, timeout: 8, last: &last, where: {
                $0.letter == letter && $0.phase == "freeWrite" && $0.checkpointsHit == 0
            }) else {
                XCTFail("\(letter): guided did not advance to freeWrite: \(last?.summary ?? "no hook")",
                        file: file, line: line)
                return nil
            }
            Thread.sleep(forTimeInterval: 1.0)
            LetterTracer.traceLetter(fw, in: app)
            guard LetterTracer.waitForCompletion(app, letter: letter, probe: nil, file: file, line: line) != nil else {
                return nil
            }
            traced.append(letter)
            afterLetter(round, letter)
        }
        return traced
    }

    /// The bubble pause must come up after the third training letter, then
    /// go. Returns false after a failure is recorded.
    @MainActor
    static func waitThroughPause(_ app: XCUIApplication,
                                 file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let pause = app.descendants(matching: .any)["finalTestPause"]
        guard pause.waitForExistence(timeout: 15) else {
            XCTFail("the bubble pause never came up after training: \(LetterTracer.snapshot(app)?.summary ?? "no hook")",
                    file: file, line: line)
            return false
        }
        guard pause.waitForNonExistence(timeout: Double(pauseSeconds) + 20) else {
            XCTFail("the bubble pause did not end within \(pauseSeconds) s + margin", file: file, line: line)
            return false
        }
        return true
    }

    /// The final test: each test letter (in training order) is written from
    /// memory once its glimpse has hidden, and closed with the check button.
    /// `whileWriting` runs after each letter's writing, before the check is
    /// tapped. Returns the letters tested, or nil after a failure is recorded.
    @MainActor
    static func writeFinalTest(_ app: XCUIApplication, expected: [String],
                               whileWriting: (String) -> Void = { _ in },
                               file: StaticString = #filePath, line: UInt = #line) -> [String]? {
        var tested: [String] = []
        var last: TracingHookSnapshot?
        let check = app.descendants(matching: .any)["finalTestCheck"]
        for k in 1...expected.count {
            guard let ready = LetterTracer.waitForSnapshot(app, timeout: 30, last: &last, where: {
                $0.probe == "finalTest" && $0.phase == "freeWrite" && !$0.strokes.isEmpty
                    && !tested.contains($0.letter)
            }) else {
                XCTFail("final-test letter \(k) never loaded after \(tested): \(last?.summary ?? "no hook")",
                        file: file, line: line)
                return nil
            }
            let letter = ready.letter
            XCTAssertEqual(letter, expected[k - 1], "the final test must follow the training order \(expected)",
                           file: file, line: line)
            XCTAssertFalse(check.exists, "\(letter): no check button before the child writes", file: file, line: line)
            // The glimpse (glyph shown, no touch) hides after `glimpseSeconds`.
            Thread.sleep(forTimeInterval: glimpseSeconds + 1.5)
            var attempts = 0
            while !check.isHittable, attempts < 2 {
                attempts += 1
                guard let now = LetterTracer.snapshot(app), now.letter == letter, now.probe == "finalTest" else { break }
                LetterTracer.traceLetter(now, in: app)
                _ = check.waitUntilHittable(timeout: 5)
            }
            guard check.isHittable else {
                XCTFail("\(letter): the check button never came up after writing: \(LetterTracer.snapshot(app)?.summary ?? "no hook")",
                        file: file, line: line)
                return nil
            }
            whileWriting(letter)
            check.tap()
            guard LetterTracer.waitForSnapshot(app, timeout: 10, last: &last, where: {
                $0.completed.contains { $0.letter == letter && $0.probe == "finalTest" }
            }) != nil else {
                XCTFail("\(letter): the final-test letter was not recorded after the check: \(last?.summary ?? "no hook")",
                        file: file, line: line)
                return nil
            }
            tested.append(letter)
        }
        return tested
    }
}
