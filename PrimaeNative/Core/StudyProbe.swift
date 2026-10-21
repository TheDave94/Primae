// StudyProbe.swift
// PrimaeNative
//
// The three COLD free-writing probes of the pilot (2026-09-04): a letter
// opened directly in the freeWrite phase — no observe, no direct, no
// guided, no demonstration — so that production is measured without
// training. Every probe is SOUND-OFF in every arm (protocol r12, David
// 2026-10-21, "probes silent"): the pen drives no arm sound while the
// child writes a probe (`TouchDispatcher.updateAdaptivePlayback`), so
// every outcome measure is sound-off; the session's practice
// free-writing keeps its sound. The spoken content is identical in every
// arm — a probe phase has no phase-entry cue.
// Each probe stamps its kind on the phase
// row (`PhaseSessionRecord.probe`), which is what lets the analysis tell
// a pretest from a post-test from a delayed test on the same letter.
// Until this existed only the untrained-pair post-test route was built
// (H6), the pretest the thesis describes had no route for a TRAINED
// letter, and no row said which timepoint it belonged to.

import Foundation

enum StudyProbe: String, Codable, CaseIterable, Sendable {
    /// Before training: every child writes all five study letters once.
    /// The ANCOVA covariate (thesis Ch.6). Any study letter.
    case pretest
    /// After the training passes: all five study letters, cold and
    /// sound-off, trained and untrained alike (David, 2026-10-21, "Cold
    /// probe for all"; protocol r12). A trained letter's final training
    /// free-writing is practice, not its post-test.
    case posttest
    /// The delayed retention test some weeks later: all five letters,
    /// cold, on a participant whose identity was restored from the
    /// pseudonymous identifier (`ParticipantStore.restoreParticipant`).
    case delayed

    /// Which of the study letters this kind may open. Since r12 every
    /// kind accepts any study letter; `untrained` is kept in the
    /// signature (no kind reads it now) so the callers stay unchanged.
    func permits(letter: String, untrained: Set<String>, studyLetters: Set<String>) -> Bool {
        studyLetters.contains(letter)
    }

    /// Proctor-facing German label.
    var displayName: String {
        switch self {
        case .pretest:  return "Vortest"
        case .posttest: return "Post-Test"
        case .delayed:  return "Nachtest (verzögert)"
        }
    }
}
