// FinalTest.swift
// PrimaeNative
//
// The closing part of a study session (protocol r27, David's design,
// 2026-11-23): after the child's third trained letter a silent bubble pause,
// then a FINAL TEST — each trained letter once more, in the SAME order as
// training, shown as a plain glyph for a moment, hidden, and written from
// memory. No sound, no feedback, no retry; the child ends each letter by
// tapping a check button.
//
// Every DECISION of that flow lives here as plain Swift values, because the
// views that show it cannot be driven from a test (CLAUDE.md, "Test
// Infrastructure" 3: `CanvasDrawPlan` is the pattern). The view model owns the
// state and the timers; this file owns what the state MEANS.
//
// Full rationale: docs/DECISIONS.md, "Protocol revision 27".

import Foundation

/// Where the child is in the closing part of the session.
enum FinalTestStage: Equatable, Sendable {
    /// Training (or a session that has not reached the end of it).
    case inactive
    /// The silent bubble screen after the last training letter.
    case pause
    /// The recorded "Jetzt schreibst du sie alle noch einmal." is playing;
    /// no letter is loaded yet.
    case intro
    /// A test letter's plain glyph is on screen. Touches are ignored.
    case glimpse
    /// The glyph is hidden; the child writes from memory until the check.
    case writing
    /// The last test letter is recorded and the session end screen is on its
    /// way up (it fades in over `SessionEndScreenView.lead`). Nothing of the
    /// practice screen comes back underneath it: no chrome, no scaffolding,
    /// no ink, no touch. Left only for a new child or a letter load
    /// (a cold probe), both of which return to `.inactive`.
    case ended
}

/// What the final test shows, accepts and ends on, per stage. Plain values.
enum FinalTestRules {

    /// The letters of the final test: the child's trained letters in the
    /// order they were TRAINED (`visibleLetterNames`, the `.motorSimilarity`
    /// order filtered to the child's subset). The same order gives no arm an
    /// order advantage and maximises the shortest lag between a letter's
    /// training and its test (DECISIONS r27).
    static func letters(trainingOrder: [String]) -> [String] {
        var seen = Set<String>()
        return trainingOrder.filter { seen.insert($0).inserted }
    }

    /// Whether the canvas takes a touch. Not while the glyph is on screen
    /// (the child is to look, not to trace) nor during the pause or the intro.
    static func acceptsTouch(_ stage: FinalTestStage) -> Bool {
        switch stage {
        case .inactive, .writing:                return true
        case .pause, .intro, .glimpse, .ended:   return false
        }
    }

    /// Whether the plain glyph is drawn: only during the glimpse in the final
    /// test. (Outside it the study freeWrite rule applies: no glyph.)
    static func showsGlimpseGlyph(_ stage: FinalTestStage) -> Bool {
        stage == .glimpse
    }

    /// Whether the guide line, start dots, endpoint ring and the turn cue are
    /// drawn. Never in the final test: the glimpse is the glyph ONLY.
    static func showsScaffolding(_ stage: FinalTestStage) -> Bool {
        stage == .inactive
    }

    /// Whether the check button is shown: while writing, once the child has
    /// put a stroke on the canvas. An icon, no text (a 5-6-year-old reads
    /// none).
    static func showsCheckButton(stage: FinalTestStage, hasInk: Bool) -> Bool {
        stage == .writing && hasInk
    }

    /// Whether the letter ends on the quiet window after a lift (the 2 s
    /// window the TRAINING free-writing uses). Not in the final test: writing
    /// from memory invites longer pauses between strokes, and a window would
    /// cut a letter off mid-recall. The final test ends on the check.
    static func endsOnQuietWindow(probe: StudyProbe?) -> Bool {
        probe != .finalTest
    }

    /// Whether the stage hides the rest of the chrome (letter pill, phase
    /// dots, chevrons): from the pause on the child sees the task only, and
    /// through the end (`.ended`) until the end screen covers the canvas.
    /// The hidden chrome is out of the view tree, so it takes no tap either.
    static func hidesChrome(_ stage: FinalTestStage) -> Bool {
        stage != .inactive
    }

    /// Whether the canvas draws the child's ink. Not during the pause or the
    /// intro (the last TRAINING letter's ink is still in the buffers until
    /// the first test letter loads, and must not show while the test is
    /// introduced), and not once the test has ended (the end screen fades in
    /// over an empty task canvas, not over the last test letter).
    static func showsInk(_ stage: FinalTestStage) -> Bool {
        switch stage {
        case .inactive, .glimpse, .writing:   return true
        case .pause, .intro, .ended:          return false
        }
    }

    /// Whether the whole-screen bubble pause is up.
    static func showsPause(_ stage: FinalTestStage) -> Bool {
        stage == .pause
    }

    /// The test letter after `index`, or nil at the end.
    static func nextIndex(after index: Int, count: Int) -> Int? {
        index + 1 < count ? index + 1 : nil
    }

    /// How long the intro prompt may take before the first glimpse starts
    /// anyway (the recording's end report is the normal trigger; this is the
    /// fallback when none arrives, like the observe cue's).
    static let introFallbackSeconds: TimeInterval = 4.0
    /// The breath between the intro prompt's end and the first glimpse.
    static let introEndToGlimpseSeconds: TimeInterval = 0.5
}

/// What one final-test row records about the test's own timing (protocol r27).
/// Planned values are the researcher settings in force; `glimpseSecondsShown`
/// and the latency are MEASURED on the monotonic clock.
struct FinalTestFacts: Equatable, Sendable {
    var glimpseSecondsPlanned: Double
    /// From the glyph appearing to it hiding. Nil when it was never measured.
    var glimpseSecondsShown: Double?
    var pauseSecondsPlanned: Double
    /// From the glyph hiding to the child's first touch of the letter.
    /// Nil when the child never touched the canvas.
    var glimpseHiddenToFirstTouchSeconds: Double?
    /// How many times an interruption (a scene leaving `.active`, the parent
    /// area, the headphones) cut this letter's glimpse and it restarted in
    /// full. 0 for an uninterrupted glimpse; `glimpseSecondsShown` is the
    /// last, uncut showing. An interruption of the pause, the intro or the
    /// writing is not counted here.
    var glimpseRestarts: Int = 0
}
