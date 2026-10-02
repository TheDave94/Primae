// NextParticipantControl.swift
// PrimaeNative
//
// The proctor's "next child" action, in ONE place, used from both the
// Research Dashboard and the rail's reveal gesture (2026-10-01).
//
// WHY IT EXISTS AS A SHARED TYPE. Running 30-40 children back to back
// meant seven steps per child: hold the gear, navigate to the Research
// Dashboard, tap "Neuer Teilnehmer", SAVE A SHARE-SHEET FILE, confirm
// the wipe, then force-quit and relaunch. Two of those were defects,
// not requirements:
//
// 1. THE PER-CHILD EXPORT WAS REDUNDANT. The old flow forced a JSON
//    share sheet before every wipe, on the reasoning that a proctor
//    might not finish saving the file. But `resetForNewParticipant()`
//    already seals the outgoing child's COMPLETE record to
//    `ParticipantArchive/` before any store is touched, and
//    `ArchivedParticipant` is documented as "everything
//    `ParentDashboardExporter` needs to reproduce that participant's
//    per-row CSV/JSON output stand-alone". `allParticipantExportSources`
//    is `archived + [current]`, so the end-of-session combined export
//    already carries every child in one `primae_progress_ALL_…_all<N>`
//    file. Forcing 30-40 share sheets bought no data safety.
//
// 2. THE RESTART PROMPT WAS OBSOLETE. The flow ended in a "Neustart
//    erforderlich" alert telling the proctor to fully close and reopen
//    the app so the new arm assignment would take effect. It no longer
//    needs to: `resetForNewParticipant()` calls
//    `reapplyParticipantIdentity()`, which re-derives the live arm
//    assignment IN PLACE and loads the incoming child's first trained
//    letter. `NewParticipantResetTests.reappliesIdentityWithoutRelaunch`
//    pins that (participantIdentityChanged == false, live audioCondition
//    and trainedSubset already reflecting the NEW child, sessionBlockReason
//    == nil). The capability landed 2026-09-14; this alert was simply
//    never removed, so the app kept instructing a proctor through a
//    force-quit per child.
//
// The control keeps BOTH data guarantees and drops both frictions: the
// destructive step is still behind a confirmation dialog naming what is
// preserved, and the per-child export is gone because the seal already
// preserves it.

import SwiftUI

/// A button that runs the "seal the outgoing child, wipe, enrol the next"
/// flow behind a confirmation, then confirms the new child is ready
/// WITHOUT asking for a relaunch.
///
/// Generic over its label so the same control renders as the wide
/// dashboard button and the compact rail icon.
///
/// The rail keeps this view MOUNTED and toggles its visibility with
/// `opacity`/`allowsHitTesting` rather than removing it from the tree —
/// see `WorldSwitcherRail`. An earlier version had the rail remove it
/// (`if showNextChild`), and the "ready" alert then never appeared:
/// removing a view also removes the alert it presents, and the rail was
/// hiding the button in the same update cycle that set `showReady`.
/// Anything that unmounts this control at the wrong moment silently
/// eats the confirmation.
struct NextParticipantControl<Label: View>: View {
    @Environment(TracingViewModel.self) private var vm

    @ViewBuilder private var label: Label
    private let onReset: () -> Void

    @State private var showConfirm = false
    @State private var showReady = false

    init(onReset: @escaping () -> Void = {}, @ViewBuilder label: () -> Label) {
        self.onReset = onReset
        self.label = label()
    }

    var body: some View {
        Button {
            showConfirm = true
        } label: {
            label
        }
        .confirmationDialog(
            "Neuen Teilnehmer beginnen?",
            isPresented: $showConfirm,
            titleVisibility: .visible
        ) {
            Button("Neues Kind starten", role: .destructive) {
                vm.resetForNewParticipant()
                showReady = true
                // Fired AFTER showReady, and safe only because the rail
                // keeps this control mounted — an earlier version called
                // it while the rail was still UNMOUNTING the control, and
                // that removed the very alert `showReady` had just set.
                onReset()
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            // Says what SURVIVES, not just what is destroyed: the
            // destructive step is one a proctor does 30-40 times, and
            // the honest reason to confirm is "this ends the current
            // child's session", not "this may lose data".
            Text("Die Daten des aktuellen Kindes werden unverändert archiviert und sind im Sammel-Export am Ende weiterhin enthalten. Anschließend werden Fortschritt, Sterne, Sessions und gespeicherte Schrift-Kalibrierungen gelöscht und ein neuer Teilnehmer mit neuer ID und neuer Studienarm-Zuordnung angelegt. Geräte-Einstellungen bleiben erhalten. Ein Neustart ist nicht nötig — das Gerät kann direkt dem nächsten Kind gegeben werden.")
        }
        .alert("Neues Kind bereit", isPresented: $showReady) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Studienarm-Zuordnung ist neu abgeleitet und die App ist sofort startklar.")
        }
    }
}
