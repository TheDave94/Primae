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
    static let revision: Int = 7

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
        Revision(revision: 5, mergedAtUTC: "2026-10-05 19:38", pullRequest: 42,
                 childFacingChange: "Observe (#39, missed bump): the animation and, in the sound arms, the sound start together after the instruction, sound for the whole pass. Observe sound now TRACKS the animated dot like the pen (rate from dot velocity, pan from x, spatial pitch from y; still dot = slowest rate), reversing D9's steady carrier. The presentation starts 1.0 s after the spoken cue ends (3.0 s fallback from the cue's start), all arms. Envelope in every writing phase of the sound arms: fade-out 0.4 s (was 0.12), stall 0.3 s (was 0.12), lift hold 0.8 s (was 0; a re-touch inside it keeps the sound)."),
        Revision(revision: 6, mergedAtUTC: "2026-10-05 20:36", pullRequest: 43,
                 childFacingChange: "Free-writing (the session free-write and every cold probe) is ungated: in the sound arms the sound follows the pen anywhere on the canvas, no longer only near the reference letter's own position and size; guided keeps the on-letter gate. The free-writing score (and so the stars) and the primary outcome spatialDeviation are measured after fitting the drawn letter's bounding box onto the reference's (translate + uniform scale, aspect kept; a scribble under 2% of the canvas is moved, not scaled); the unnormalised distance is exported as spatialDeviationRaw."),
        Revision(revision: 7, mergedAtUTC: nil, pullRequest: nil,
                 childFacingChange: "Sound arms, every writing phase (guided, free-writing, cold probes): a pen put back down inside the 0.8 s lift hold now keeps the sound, as r5 specified. Under r5-r6 the touch-down reloaded the arm file, which hard-stopped the held sound, and nothing restarted it: the strokes after the first stayed silent for as long as each re-touch came inside the hold, until the pen paused 0.3 s or lifted for longer than the hold. Sound arms after an arm change in the same app run (the next child enrolled in place, or a comparison cycle): the engine follows the arm. Under r1-r6 an app launched in the silent arm kept the silent engine for every later child, so a phoneme or spatial child enrolled after it heard no arm sound at all (observe, guided, free-writing, cold probes) while the rows recorded the sound arm; now they hear it, and the silent arm never reaches the real engine. Every arm change and every new child also stops the previous sound and resets rate, pan and pitch to neutral: under r1-r6 a phoneme child after a spatial child heard every phoneme pitch-shifted by that child's last pen height (up to +-1200 cents). Silent arm unchanged for the child: still silent. Every arm, guided and free-writing (training and cold probes): a slow pen leaves ink and is recorded. The 1.5 pt jitter filter now measures from the last point it kept, not from the previous touch sample; under r1-r6 any motion slower than about 180 pt/s (finger, 120 Hz) or 360 pt/s (Pencil, 240 Hz) drew no ink and was left out of the scored, exported free-writing trace, and so was the slowing end of every stroke. The free-writing trace now also keeps the pen's last position before the lift, so its span runs from the pen-down to the last sample before the lift. A pen held still adds no points: a sample under 1.5 pt from the last kept point is not kept, so jitter around a resting finger records the pen-down alone. A contact that creeps 1.5 pt or more does add points, so a free-writing contact now counts as a production (it starts the 2 s quiet-window advance, and is scored and recorded as a completed trial when the proctor moves on inside that window) only if it has at least two points spanning at least 2% of the canvas (the larger side of its bounding box, canvas-normalised: the r6 scribble extent); under r1-r6 two recorded points were enough. A smaller contact is treated like a one-sample palm. Sound, velocity and the guided checkpoint tracker are unchanged: they always saw every sample. Cold probes (pretest, post-test, delayed), every arm: a probe of the trained set's last letter no longer ends the set; under r2-r6 it spoke \"Super gemacht!\" (all arms), chimed (sound arms) and held the chevron, so training could not be reached by the chevron. A finished probe no longer advances by itself into the next trained letter's demonstration (and, in the sound arms, its sound); the canvas stays on the finished probe until the proctor moves on. After the set ends, the left chevron and the random-letter action hold like the right chevron instead of reopening a trained letter. A chevron (either) or the random-letter action tapped inside the 2 s quiet window after the set's last letter now closes the finished free-write first, so it ends the set and stays on that letter; under r2-r6 the set ended (phrase, chime, hold) and the same tap then opened another trained letter, the first one for the right chevron, starting a second pass under the same participant. Comparison runs only (letter-repeat switch above 1): a finished cold probe is no longer repeated as a demonstration and training pass of that letter."),
    ]
}
