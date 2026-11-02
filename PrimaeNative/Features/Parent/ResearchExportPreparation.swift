// ResearchExportPreparation.swift
// What the research export screen (`ExportCenterView`) runs when the
// proctor taps an export button (B4, B22; protocol r16). A view cannot be
// tested, so the screen's whole action lives here. Kept out of
// TracingViewModel.swift on purpose: it only calls the coordinator entry
// point the background and navigation paths already use.

import Foundation

extension TracingViewModel {
    /// Records the live child's finished-but-unscored free-writing trial
    /// before an export is built (B22, round-2 VERIFY-14). Opening the
    /// parent area holds the 2.0 s quiet window (`beginInterruption`), so a
    /// proctor who exported right after the last child lifted the pen got a
    /// file without that trial. The row is written `finalizedBy: "export"`.
    /// Study mode only, and a no-op unless such a production is pending
    /// (the same guard the background path applies). Returns true when a
    /// trial was recorded.
    @discardableResult
    func finalizeHeldTrialForExport() -> Bool {
        phaseTransitions.finalizeFinishedFreeWriteIfPending(finalizedBy: .export)
    }

    /// The combined research export the parent area shares: the held
    /// trial is recorded first (B22), then every participant, every
    /// enrolment, and a `# setAside=` line for each archive file that
    /// could not be loaded (B4).
    func makeResearchExport(format: DashboardExportFormat,
                            locations: ExportFileRetention.Locations = .live) throws(ExportError) -> URL {
        finalizeHeldTrialForExport()
        return try ParentDashboardExporter.combinedExportForSharing(
            participants: allParticipantExportSources,
            enrolments: enrolmentRecords,
            setAside: participantArchive.setAsideArchiveFiles,
            format: format,
            locations: locations)
    }
}
