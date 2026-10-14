// ParentAreaView.swift
// PrimaeNative
//
// Parental gate destination. Reached only via the 2-second gear
// long-press on `WorldSwitcherRail`. Plain iOS chrome — no
// child-friendly styling, since a child should never land here.

import SwiftUI
import UIKit

struct ParentAreaView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(TracingViewModel.self) private var vm

    enum Section: String, CaseIterable, Identifiable {
        #if STUDY_BUILD
        case research, settings, export
        #else
        case overview, research, settings, export
        #endif
        var id: String { rawValue }
        var title: String {
            switch self {
            #if !STUDY_BUILD
        case .overview:  return "Übersicht"
        #endif
            case .research:  return "Forschungs-Daten"
            case .settings:  return "Einstellungen"
            case .export:    return "Datenexport"
            }
        }
        var systemImage: String {
            switch self {
            #if !STUDY_BUILD
        case .overview:  return "chart.bar.fill"
        #endif
            case .research:  return "chart.xyaxis.line"
            case .settings:  return "gearshape.fill"
            case .export:    return "square.and.arrow.up"
            }
        }
    }

    #if STUDY_BUILD
    @State private var selection: Section? = .research
    #else
    @State private var selection: Section? = .overview
    #endif

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(Section.allCases) { section in
                    NavigationLink(value: section) {
                        Label(section.title, systemImage: section.systemImage)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Eltern-Bereich")
            // B1 — permanent build-identity marker. A study iPad must
            // never be mistakable for a normal one at a glance, and the
            // proctor sees this screen at every handoff. The whole
            // modifier is inside the #if, so the normal build's view
            // tree is untouched rather than carrying an empty inset.
            #if STUDY_BUILD
            .safeAreaInset(edge: .top) { studyBuildBanner }
            #endif
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Zurück zur App") { dismiss() }
                        .accessibilityLabel("Zurück zur App")
                }
            }
        } detail: {
            #if STUDY_BUILD
            detailView(for: selection ?? .research)
            #else
            detailView(for: selection ?? .overview)
            #endif
        }
    }

    #if STUDY_BUILD
    /// Red band naming the binary. Reads the identity from
    /// `StudyBuild.marker` rather than a literal, so the text cannot
    /// drift away from what was actually compiled.
    private var studyBuildBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "testtube.2")
            Text("STUDY BUILD")
                .font(.system(.subheadline, design: .monospaced).weight(.bold))
            Spacer()
            Text(StudyBuild.marker)
                .font(.system(.caption2, design: .monospaced))
                .opacity(0.85)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color.red.opacity(0.85))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Studien-Build. Nicht-Studien-Funktionen sind in diesem Build nicht enthalten.")
    }
    #endif

    @ViewBuilder
    private func detailView(for section: Section) -> some View {
        switch section {
        #if !STUDY_BUILD
        case .overview:
            ParentDashboardView()
        #endif
        case .research:
            // ResearchDashboardView lives in the NavigationSplitView's
            // detail column — ITS `@Environment(\.dismiss)` only pops
            // that column, not this view's own root presentation. Pass
            // THIS view's dismiss (the one bound to the enclosing
            // `.fullScreenCover` in MainAppView) so a probe button can
            // close the whole parent area (2026-09-15).
            ResearchDashboardView(onLeaveParentArea: { dismiss() })
        case .settings:
            SettingsView()
        case .export:
            ExportCenterView()
        }
    }
}

// MARK: - Export center

private struct ExportCenterView: View {
    @Environment(TracingViewModel.self) private var vm
    @State private var shareURL: URL?
    @State private var showError = false

    var body: some View {
        Form {
            Section("Forschungs-Export") {
                Button {
                    export(format: .csv)
                } label: {
                    Label("CSV exportieren", systemImage: "doc.text")
                }
                Button {
                    export(format: .tsv)
                } label: {
                    Label("TSV exportieren", systemImage: "doc.plaintext")
                }
                Button {
                    export(format: .json)
                } label: {
                    Label("JSON exportieren", systemImage: "curlybraces")
                }
            }
            Section("Hinweis") {
                Text("Exportiert die Daten ALLER auf diesem Gerät erfassten Teilnehmer in einer Datei — sowohl den aktuellen als auch jeden zuvor über „Neuer Teilnehmer“ abgeschlossenen, jeweils mit eigener Teilnehmer-ID (\(ParentDashboardExporter.distinctParticipantCount(vm.allParticipantExportSources)) Teilnehmer aktuell gespeichert). Enthält Phasen-Daten, Schreibmotorik-Dimensionen (Form, Tempo, Druck, Rhythmus) und KI-Erkennungs-Konfidenzen. TSV passt am besten zu SPSS/R, CSV zu Excel/pandas.")
                    .font(.footnote)
                    .foregroundStyle(Color.inkSoft)
            }
        }
        .navigationTitle("Datenexport")
        .sheet(isPresented: Binding(
            get: { shareURL != nil },
            set: { if !$0 { shareURL = nil } }
        )) {
            if let url = shareURL {
                ActivitySheet(items: [url], temporaryExport: url)
            }
        }
        .alert("Export fehlgeschlagen", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Die Datei konnte nicht erstellt werden.")
        }
    }

    private func export(format: DashboardExportFormat) {
        do {
            shareURL = try ParentDashboardExporter.combinedExportForSharing(
                participants: vm.allParticipantExportSources,
                enrolments: vm.enrolmentRecords,
                format: format
            )
        } catch {
            showError = true
        }
    }
}

/// Share-sheet wrapper for the research export (its only caller since the
/// per-child export was removed in #22).
struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]
    /// The tmp/ export being shared; deleted when the sheet reports the
    /// activity completed (R-062).
    var temporaryExport: URL? = nil
    var locations: ExportFileRetention.Locations = .live

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        Self.configure(vc, temporaryExport: temporaryExport, locations: locations)
        return vc
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}

    /// Activities the export must not be offered to (R-062). The file holds
    /// every child recorded on this iPad. Kept: AirDrop (shows the receiving
    /// device and needs it to accept) and Save to Files (no ActivityType
    /// constant exists for it, so it cannot be excluded by mistake here).
    /// Excluded, besides the pointless targets (social posts, contacts,
    /// reading list, Photos, print, Books, markup, SharePlay, collaboration,
    /// home screen):
    /// - Mail and Messages: one mis-tap on a contact sends all children's
    ///   data through a third-party server to whoever that is; neither is a
    ///   documented retrieval path (AirDrop, Files, devicectl are).
    /// - Copy: Universal Clipboard puts the data on other devices signed in
    ///   to the same Apple Account.
    static let excludedActivityTypes: [UIActivity.ActivityType] = [
        .mail, .message, .copyToPasteboard,
        .postToFacebook, .postToTwitter, .postToWeibo, .postToTencentWeibo,
        .postToFlickr, .postToVimeo,
        .assignToContact, .addToReadingList, .saveToCameraRoll, .print,
        .openInIBooks, .markupAsPDF, .sharePlay,
        .collaborationInviteWithLink, .collaborationCopyLink, .addToHomeScreen,
    ]

    /// Applies the exclusions and the tmp/ cleanup. Separate from
    /// `makeUIViewController` so a test can drive it without a SwiftUI
    /// context.
    static func configure(_ vc: UIActivityViewController, temporaryExport: URL?,
                          locations: ExportFileRetention.Locations = .live) {
        vc.excludedActivityTypes = excludedActivityTypes
        vc.completionWithItemsHandler = { _, completed, _, _ in
            if let temporaryExport {
                ExportFileRetention.finishSharing(temporaryExport, completed: completed,
                                                  locations: locations)
            }
        }
    }
}
