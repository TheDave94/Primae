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

/// The proctor-facing copy of the "next child" flow, as plain values.
///
/// WHY IT IS NOT INLINE IN THE VIEW. A `View`'s body is unreachable from
/// a unit test — SwiftUI vends no accessibility elements in this
/// configuration, so `NextParticipantControlTests` could not see a
/// single character of the dialog (the same limit
/// `ChildFacingCountsTests` records for the star/verdict views). But
/// these strings carry CLAIMS, not decoration: the dialog is the only
/// place a proctor is told what survives a wipe and what does not, and
/// one of those claims was WRONG until 2026-10-01 — it said
/// calibrations were preserved while `resetForNewParticipant()` calls
/// `clearAllCalibrations()`. Extracting the values is what makes that
/// class of claim assertable at all.
enum NextParticipantCopy {
    static let confirmTitle = "Neuen Teilnehmer beginnen?"
    static let startButton = "Neues Kind starten"
    static let cancelButton = "Abbrechen"

    /// Says what SURVIVES, not just what is destroyed: the destructive
    /// step is one a proctor does 30-40 times, and the honest reason to
    /// confirm is "this ends the current child's session", not "this may
    /// lose data".
    static let confirmMessage = "Die Daten des aktuellen Kindes werden unverändert archiviert und sind im Sammel-Export am Ende weiterhin enthalten. Anschließend werden Fortschritt, Sterne, Sessions und gespeicherte Schrift-Kalibrierungen gelöscht und ein neuer Teilnehmer mit neuer ID und neuer Studienarm-Zuordnung angelegt. Geräte-Einstellungen bleiben erhalten. Ein Neustart ist nicht nötig — das Gerät kann direkt dem nächsten Kind gegeben werden."

    /// The title of the dashboard's confirmation alert (`.alert`
    /// presentation). The rail path shows only `readyMessage`, as a toast.
    static let readyTitle = "Neues Kind bereit"
    static let readyOKButton = "OK"
    static let readyMessage = "Studienarm-Zuordnung ist neu abgeleitet und die App ist sofort startklar."

    /// Accessibility identifiers for the Schule world's toast. The toast is
    /// child-facing, so nothing here is visible text: the identifier is how
    /// a UI test (and only a UI test) tells the ready confirmation from any
    /// other toast — `PrimaeUITests` waits on it where it used to wait on
    /// the alert #61 removed.
    static let readyToastIdentifier = "newChildReadyToast"
    static let otherToastIdentifier = "transientToast"

    static func toastIdentifier(for message: String) -> String {
        message == readyMessage ? readyToastIdentifier : otherToastIdentifier
    }

    /// Shown INSTEAD of the ready confirmation when the outgoing child could not
    /// be sealed, so nothing was wiped and no child was enrolled (R-050).
    /// The message is `TracingViewModel.participantSealFailure`.
    static let sealFailedTitle = "Kein neues Kind begonnen"
}

/// How the control confirms a successful enrolment. It depends on WHERE the
/// proctor started the flow, not on what was enrolled.
enum NewChildReadyPresentation: Equatable {
    /// The rail: the child's drawing screen is under the proctor's thumb, and
    /// a modal there would block the canvas until dismissed (#61, reported
    /// 2026-10-16). The confirmation is a non-blocking toast in the Schule
    /// world.
    case toast
    /// The Research Dashboard: a parent-area `fullScreenCover` sits OVER the
    /// Schule world, so that toast is not visible there and #61 left the
    /// proctor with no confirmation at all. Nothing is being drawn behind a
    /// parent area, so a modal alert blocks nothing and is the one form that
    /// cannot be missed.
    case alert

    /// Whether the enrolment is announced as a toast. The control shows the
    /// alert in exactly the other case, never both.
    var announcesAsToast: Bool { self == .toast }
}

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

    /// Internal, not `private`, so a test can pin the default.
    let presentation: NewChildReadyPresentation

    @State private var showConfirm = false
    @State private var showReady = false
    @State private var sealFailure: String?

    init(presentation: NewChildReadyPresentation = .toast,
         onReset: @escaping () -> Void = {},
         @ViewBuilder label: () -> Label) {
        self.presentation = presentation
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
            NextParticipantCopy.confirmTitle,
            isPresented: $showConfirm,
            titleVisibility: .visible
        ) {
            Button(NextParticipantCopy.startButton, role: .destructive) {
                vm.resetForNewParticipant()
                // A seal that could not be confirmed changed nothing: say
                // so, and do not claim a new child is ready (R-050).
                if let failure = vm.participantSealFailure {
                    sealFailure = failure
                    return
                }
                // NON-BLOCKING ON THE RAIL. This used to set a modal alert
                // everywhere, and a modal alert BLOCKS the tracing canvas
                // until dismissed — so the proctor had to tap OK before the
                // child could draw, for a message whose whole content is that
                // nothing needs doing ("…die App ist sofort startklar").
                // REPORTED by the proctor 2026-10-16: "when I start a new
                // participant the drawing start waits until the popup is
                // confirmed". The rail therefore confirms with a toast. The
                // dashboard is the other entry point and the toast cannot be
                // seen from there (the parent area covers the Schule world),
                // so it keeps a visible alert — see `NewChildReadyPresentation`.
                // The seal-FAILURE alert below stays modal on both, because
                // that one does require the proctor.
                if presentation.announcesAsToast {
                    vm.announceNewChildReady()
                } else {
                    showReady = true
                }
                onReset()
            }
            Button(NextParticipantCopy.cancelButton, role: .cancel) {}
        } message: {
            // A comparison run is named at the enrolment gate (R-017).
            Text(vm.comparisonRunBanner.map { "\($0)\n\n" + NextParticipantCopy.confirmMessage }
                 ?? NextParticipantCopy.confirmMessage)
        }
        .alert(NextParticipantCopy.readyTitle, isPresented: $showReady) {
            Button(NextParticipantCopy.readyOKButton, role: .cancel) {}
        } message: {
            Text(NextParticipantCopy.readyMessage)
        }
        .alert(NextParticipantCopy.sealFailedTitle, isPresented: Binding(
            get: { sealFailure != nil },
            set: { if !$0 { sealFailure = nil } }
        )) {
            Button(NextParticipantCopy.readyOKButton, role: .cancel) {}
        } message: {
            Text(sealFailure ?? "")
        }
    }
}
