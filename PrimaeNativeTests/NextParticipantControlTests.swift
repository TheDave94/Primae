// NextParticipantControlTests.swift
// PrimaeNativeTests
//
// Coverage for the proctor-facing CLAIMS of the "next child" flow
// (`NextParticipantCopy`, extracted from the view body for exactly this
// reason — a `View`'s body vends nothing to a unit test).
//
// WHY THESE STRINGS ARE WORTH A TEST. They are not decoration: this
// dialog is the only place a proctor is told what survives a wipe and
// what does not, and a proctor runs it 30-40 times per batch. One of
// the claims was WRONG until 2026-10-01 — the dialog said font
// calibrations were preserved while `resetForNewParticipant()` calls
// `clearAllCalibrations()`. A wrong claim here is not a cosmetic bug;
// it is the proctor's basis for deciding whether the previous child's
// data is safe. The assertions below are therefore written as CLAIM
// CHECKS (does the sentence that names a thing also name its fate?),
// not as string equality, so an innocent rewording does not break them
// while an inverted claim does.
//
// WHAT THIS FILE CANNOT REACH — measured, not assumed. Everything about
// the control's BEHAVIOUR: that the destructive button calls
// `vm.resetForNewParticipant()`, that `onReset` fires after the ready
// alert is set, and that the rail keeps the control mounted. SwiftUI
// vends no accessibility elements to a unit test in this configuration
// (the same limit `ChildFacingCountsTests` records), so those are held
// by `PrimaeUITests` and by
// `NewParticipantResetTests`, which pins the reset itself. What is
// reachable from here is the copy, and the copy is what was wrong.

import Testing
import Foundation
@testable import PrimaeNative

@MainActor
@Suite struct NextParticipantControlTests {

    // MARK: - Helpers

    /// The sentence (or clause) of `text` that contains `needle`.
    ///
    /// German sentences here are long and the claims are distributed
    /// across them, so a whole-string `contains` would pass on a claim
    /// stated in one sentence and contradicted in the next. Returning
    /// the enclosing sentence is what lets a test assert "the thing
    /// named as deleted really is the thing named as deleted".
    private func sentence(in text: String, containing needle: String) -> String? {
        let separators = CharacterSet(charactersIn: ".!?")
        var current = ""
        var sentences: [String] = []
        for character in text {
            current.append(character)
            if String(character).unicodeScalars.contains(where: separators.contains) {
                sentences.append(current)
                current = ""
            }
        }
        if !current.isEmpty { sentences.append(current) }
        return sentences.first { $0.contains(needle) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - The confirmation's claims

    /// The outgoing child's data survives — that is the whole reason the
    /// per-child export could be dropped. `resetForNewParticipant()`
    /// seals the child to `ParticipantArchive/` before any store is
    /// touched, and `allParticipantExportSources` is `archived +
    /// [current]`, so the end-of-session combined export carries every
    /// child. If this claim were ever removed from the dialog, a proctor
    /// would be right to worry that the wipe destroys the session.
    @Test func confirmMessageStatesTheChildIsArchivedAndStillExported() throws {
        let text = NextParticipantCopy.confirmMessage
        let archived = try #require(sentence(in: text, containing: "archiviert"))
        #expect(archived.contains("unverändert"),
                "the dialog should say the archive is COMPLETE, not partial")
        #expect(archived.contains("Sammel-Export"),
                "the dialog should say where the data can still be found")
    }

    /// REGRESSION GUARD for the inverted claim. The sentence that names
    /// the font calibrations must be the sentence that says they are
    /// deleted. The old dialog asserted the opposite of both.
    ///
    /// Written against the sentence rather than the whole string on
    /// purpose: "Geräte-Einstellungen bleiben erhalten" is a DIFFERENT
    /// sentence carrying a DIFFERENT (and true) preservation claim, so a
    /// whole-string check on "bleiben erhalten" would be ambiguous while
    /// a sentence-scoped one is exact.
    @Test func confirmMessageSaysCalibrationsAreDeleted() throws {
        let text = NextParticipantCopy.confirmMessage
        let calibrations = try #require(sentence(in: text, containing: "Kalibrierungen"))
        #expect(calibrations.contains("gelöscht"),
                "resetForNewParticipant() calls clearAllCalibrations(); the dialog must say so")
        #expect(!calibrations.lowercased().contains("bleiben erhalten"),
                "the calibrations claim was inverted once already — it must not be restored")
    }

    /// The settings that genuinely do survive must keep saying so. This
    /// is the control on the previous test: a fix that deleted every
    /// preservation claim would pass it, and the proctor would lose the
    /// one reassurance that is true.
    @Test func confirmMessageStatesDeviceSettingsSurvive() throws {
        let text = NextParticipantCopy.confirmMessage
        let settings = try #require(sentence(in: text, containing: "Geräte-Einstellungen"))
        #expect(settings.contains("bleiben erhalten"))
    }

    /// No relaunch. `reapplyParticipantIdentity()` re-derives the arms in
    /// place (pinned by `NewParticipantResetTests.reappliesIdentityWithoutRelaunch`),
    /// so telling a proctor to force-quit would be false instruction —
    /// and it was, until PR #22.
    @Test func confirmMessageStatesNoRelaunchIsNeeded() {
        let text = NextParticipantCopy.confirmMessage
        #expect(text.contains("Ein Neustart ist nicht nötig"))
        #expect(!text.contains("Neustart erforderlich"),
                "the obsolete relaunch instruction must not come back")
    }

    // MARK: - The ready alert

    /// The second dialog confirms READINESS. It must not have been
    /// turned back into a relaunch prompt — the defect PR #22 fixed was
    /// an alert that told the proctor to close and reopen the app.
    @Test func readyAlertConfirmsReadinessAndNotRelaunch() {
        #expect(NextParticipantCopy.readyTitle == "Neues Kind bereit")
        #expect(!NextParticipantCopy.readyTitle.contains("Neustart"))
        #expect(NextParticipantCopy.readyMessage.contains("sofort startklar"),
                "the alert's whole job is to say the next child can start now")
    }

    /// The destructive button must be identifiable by name from both
    /// entry points (the rail button and the dashboard button share this
    /// control), because `StudyAdvanceProbeUITests` drives the flow by
    /// exactly this string.
    @Test func theDestructiveActionHasOneStableName() {
        #expect(NextParticipantCopy.startButton == "Neues Kind starten")
        #expect(NextParticipantCopy.confirmTitle == "Neuen Teilnehmer beginnen?")
        #expect(NextParticipantCopy.cancelButton == "Abbrechen")
    }
}
