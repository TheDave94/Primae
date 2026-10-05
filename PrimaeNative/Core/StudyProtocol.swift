// StudyProtocol.swift
// PrimaeNative
//
// WHICH VERSION OF THE CHILD'S EXPERIENCE A ROW WAS RECORDED UNDER
// (2026-10-04).
//
// The export carried no build identity at all: the app version is the
// constant "1.0-1" in every configuration, and the comparison stamp
// (`StudyComparisonConfiguration.nonDefaultStamp`) lists switches that
// DIFFER FROM THE CURRENT DEFAULTS — so when a default itself moves, a
// row from before the move and a row from after it both stamp nothing,
// although the children heard different things. Two such moves happened
// mid-pilot (#27 and #32, below), and one change (#27's free-writing
// sound) is not a switch at all, so no stamp could ever show it.
//
// `revision` is a hand-bumped integer, stamped onto every
// `PhaseSessionRecord` WHEN THE RECORD IS CREATED (never at export time,
// for the same reason as `comparisonConfiguration`: an export can run
// days later on a build that has moved on). Bump it, and append a row
// to `history`, in the same PR as ANY change to what a study child
// sees, hears or does. `StudyProtocolTests` pins that the history is
// contiguous from 1 and ends at `revision`.
//
// Rows written before this field existed decode as nil. They are r1–r3
// and can only be told apart by `recordedAt` against the dates below
// and the device's install log — merge time is not install time.

import Foundation

nonisolated enum StudyProtocol {

    /// One child-facing protocol change.
    nonisolated struct Revision: Sendable, Equatable {
        let revision: Int
        /// Merge to main, UTC. Nil until the revision's PR is merged.
        let mergedAtUTC: String?
        /// Pull request on the forge. Nil until the PR exists.
        let pullRequest: Int?
        let childFacingChange: String
    }

    /// The protocol revision this build records. Always the last entry
    /// of `history`.
    static let revision: Int = 5

    static let history: [Revision] = [
        Revision(revision: 1, mergedAtUTC: "2026-10-01 22:33", pullRequest: 21,
                 childFacingChange: "Baseline as of the Xcode 27 pin. Study free-writing and every cold probe are sound-off; speech is off in every arm; guided sound needs the pen on the path at >= 22 pt/s."),
        Revision(revision: 2, mergedAtUTC: "2026-10-03 16:12", pullRequest: 27,
                 childFacingChange: "Sound arms hear their sound while free-writing, including the outcome passes (gate removed). Spoken prompts on for the phoneme and spatial arms only; prompts reworded. End-of-set celebration and hold. Observe starts on enrolment. No ink carried into free-writing."),
        Revision(revision: 3, mergedAtUTC: "2026-10-04 09:38", pullRequest: 32,
                 childFacingChange: "Guided and free-writing sound gated on the pen being on the path only: velocity floor 22 -> 0 pt/s."),
        Revision(revision: 4, mergedAtUTC: "2026-10-04 21:11", pullRequest: 34,
                 childFacingChange: "Spoken content identical in all three arms, the silent arm included: the phase prompts, \"Probier's nochmal\" and the end-of-set \"Super gemacht!\" (score-dependent praise stays unreachable); the end-of-set chime and the stroke tick stay sound-arm only. The observe prompt is spoken once per observe phase and finishes before the arm's observe sound starts — prompt first, then sound, where both used to fire together; the sound arms then hear their sound, steady, for the rest of the observe animation, replacing the 2 s demonstration in observe. A cold probe is refused when the current arm's recording for that letter is missing, so no outcome pass runs silent in a sound arm."),
        // r5 also records #39 (2026-10-05), which changed what the child
        // sees and hears in observe and missed its own bump: rows written
        // between #39 and this revision carry 4 but heard the #39 observe.
        Revision(revision: 5, mergedAtUTC: nil, pullRequest: nil,
                 childFacingChange: "Observe (#39, missed bump): the animation and, in the sound arms, the sound start together after the instruction, sound for the whole pass. Observe sound now TRACKS the animated dot like the pen (rate from dot velocity, pan from x, spatial pitch from y; still dot = slowest rate), reversing D9's steady carrier. The presentation starts 1.0 s after the spoken cue ends (3.0 s fallback from the cue's start), all arms. Envelope in every writing phase of the sound arms: fade-out 0.4 s (was 0.12), stall 0.3 s (was 0.12), lift hold 0.8 s (was 0; a re-touch inside it keeps the sound)."),
    ]
}
