import SwiftUI
import UIKit

// MARK: - Main View

struct ParentDashboardView: View {
    @Environment(TracingViewModel.self) private var vm
    @State private var shareURL: URL?
    @State private var showExportError = false
    @State private var showSettings = false

    private var snapshot: DashboardSnapshot { vm.dashboardSnapshot }

    var body: some View {
        NavigationStack {
            List {
                ubersichtSection
                phasenSection
                ubungsverlaufSection
                starksteBuchstabenSection
                ubungNoetigSection
                papierUebertragungSection
                #if DEBUG
                if vm.showDebug {
                    forschungsmetrikenSection
                }
                #endif
            }
            .navigationTitle("Lernfortschritt")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    exportButton
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Einstellungen") {
                        showSettings = true
                    }
                }
            }
            .navigationDestination(isPresented: $showSettings) {
                SettingsView()
            }
        }
        .sheet(isPresented: Binding(
            get: { shareURL != nil },
            set: { if !$0 { shareURL = nil } }
        )) {
            if let url = shareURL {
                ActivityViewController(activityItems: [url])
            }
        }
        .alert("Export fehlgeschlagen", isPresented: $showExportError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Die Datei konnte nicht erstellt werden.")
        }
    }

    // MARK: Sections

    private var ubersichtSection: some View {
        Section("Übersicht") {
            LabeledContent("Buchstaben geübt") {
                Text("\(snapshot.letterStats.filter { !$0.value.accuracySamples.isEmpty }.count)")
                    .monospacedDigit()
            }
            LabeledContent("Tage in Folge") {
                Text("\(vm.currentStreak) \(vm.currentStreak == 1 ? "Tag" : "Tage")")
                    .monospacedDigit()
            }
            LabeledContent("Beste Serie") {
                Text("\(vm.longestStreak) \(vm.longestStreak == 1 ? "Tag" : "Tage")")
                    .monospacedDigit()
            }
            LabeledContent("Übungszeit (7 Tage)") {
                Text(formattedDuration(snapshot.totalPracticeTime(recentDays: 7)))
                    .monospacedDigit()
            }
            LabeledContent("Schreibqualität") {
                Text("\(Int(snapshot.averageFreeWriteScore * 100)) %")
                    .monospacedDigit()
            }
            if let trend = vm.writingSpeedTrend {
                LabeledContent("Schreibflüssigkeit") {
                    switch trend {
                    case .improving:
                        Text("↑ zunehmend").foregroundStyle(.green)
                    case .stable:
                        Text("→ stabil").foregroundStyle(.secondary)
                    case .declining:
                        Text("↓ abnehmend").foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    private var phasenSection: some View {
        Section("Phasen-Erfolgsquote") {
            PhaseRatesView(rates: snapshot.phaseCompletionRates)
        }
    }

    private var ubungsverlaufSection: some View {
        Section("Übungsverlauf (30 Tage)") {
            PracticeTrendChart(series: snapshot.dailyPracticeMinutes(days: 30))
        }
    }

    private var starksteBuchstabenSection: some View {
        Section("Stärkste Buchstaben") {
            let top = snapshot.topLetters
            if top.isEmpty {
                Text("Noch keine Daten vorhanden.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(top, id: \.letter) { stat in
                    LetterStatRow(stat: stat, phaseScores: snapshot.phaseScores(for: stat.letter))
                }
            }
        }
    }

    private var ubungNoetigSection: some View {
        Section("Noch zu üben") {
            let weak = snapshot.lettersBelow(accuracy: 0.70)
            if weak.isEmpty {
                Text("Alle Buchstaben über 70 % – weiter so!")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(weak, id: \.letter) { stat in
                    LetterStatRow(stat: stat, phaseScores: snapshot.phaseScores(for: stat.letter))
                }
            }
        }
    }

    @ViewBuilder
    private var papierUebertragungSection: some View {
        let entries = vm.progressStore.allProgress
            .compactMap { letter, prog -> (String, Double)? in
                guard let score = prog.paperTransferScore else { return nil }
                return (letter, score)
            }
            .sorted(by: { $0.0 < $1.0 })
        if !entries.isEmpty {
            Section("Schreiben auf Papier") {
                ForEach(entries, id: \.0) { letter, score in
                    LabeledContent(letter) {
                        Text(paperTransferLabel(score))
                    }
                }
            }
        }
    }

    private func paperTransferLabel(_ score: Double) -> String {
        if score >= 0.9 { return "😊 super" }
        if score >= 0.4 { return "😐 okay" }
        return "😟 nochmal üben"
    }

    #if DEBUG
    private var forschungsmetrikenSection: some View {
        // Debug-only: research-internal correlations the parent has no use
        // for. Toggled via vm.showDebug (long-press on the phase indicator).
        Section("Forschungsmetriken (Debug)") {
            LabeledContent("Scheduler-Effektivität (r)") {
                Text(String(format: "%.3f", snapshot.schedulerEffectivenessProxy))
                    .monospacedDigit()
            }
            LabeledContent("Ø Schreibqualität (gesamt)") {
                Text(String(format: "%.3f", snapshot.averageFreeWriteScore))
                    .monospacedDigit()
            }
            if let dims = snapshot.averageWritingDimensions {
                LabeledContent("  Ø Form") {
                    Text(String(format: "%.3f", dims.form)).monospacedDigit()
                }
                LabeledContent("  Ø Tempo") {
                    Text(String(format: "%.3f", dims.tempo)).monospacedDigit()
                }
                LabeledContent("  Ø Druck") {
                    Text(String(format: "%.3f", dims.pressure)).monospacedDigit()
                }
                LabeledContent("  Ø Rhythmus") {
                    Text(String(format: "%.3f", dims.rhythm)).monospacedDigit()
                }
            }
            LabeledContent("Phasensitzungen gesamt") {
                Text("\(snapshot.phaseSessionRecords.count)")
                    .monospacedDigit()
            }
            LabeledContent("Aktuelle Bedingung") {
                Text(vm.thesisConditionRawName)
                    .monospacedDigit()
            }
        }
    }
    #endif

    // MARK: Export

    private var exportButton: some View {
        Button {
            do {
                shareURL = try ParentDashboardExporter.exportFileURL(
                    from: snapshot,
                    format: .csv
                )
            } catch {
                showExportError = true
            }
        } label: {
            Label("Exportieren", systemImage: "square.and.arrow.up")
        }
        .accessibilityLabel("Daten exportieren")
        .accessibilityHint("Erstellt eine CSV-Datei mit dem Lernfortschritt")
    }

    // MARK: Helpers

    private func formattedDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return "\(h) h \(m) min" }
        if m > 0 { return "\(m) min \(s) s" }
        return "\(s) s"
    }
}

// MARK: - Letter row

private struct LetterStatRow: View {
    let stat: LetterAccuracyStat
    /// Per-phase mean scores for this letter, keyed by LearningPhase.rawName.
    /// Empty when the child hasn't completed any phase sessions yet.
    let phaseScores: [String: Double]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text(stat.letter)
                    .font(.headline)
                    .frame(width: 32, alignment: .leading)

                Text("\(Int(stat.averageAccuracy * 100)) %")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(accuracyColor)

                Spacer()

                trendIcon
                    .font(.subheadline)
            }

            if !phaseScores.isEmpty {
                HStack(spacing: 10) {
                    Spacer().frame(width: 32)  // align under the letter glyph
                    ForEach(LearningPhase.allCases, id: \.self) { phase in
                        phaseChip(for: phase, value: phaseScores[phase.rawName])
                    }
                    Spacer()
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// One-letter abbreviation shown inside a chip. Uppercase initial of the
    /// phase's `displayName` keeps the chip compact; the full name is in the
    /// accessibilityLabel so VoiceOver still reads it out.
    private func abbreviation(for phase: LearningPhase) -> String {
        switch phase {
        case .observe:   return "A"   // Anschauen
        case .direct:    return "R"   // Richtung lernen
        case .guided:    return "N"   // Nachspuren
        case .freeWrite: return "S"   // Selbst schreiben
        }
    }

    private func chipColor(for phase: LearningPhase) -> Color {
        switch phase {
        case .observe:   return .blue
        case .direct:    return .indigo
        case .guided:    return .teal
        case .freeWrite: return .purple
        }
    }

    @ViewBuilder
    private func phaseChip(for phase: LearningPhase, value: Double?) -> some View {
        if let value {
            HStack(spacing: 3) {
                Circle()
                    .fill(chipColor(for: phase))
                    .frame(width: 6, height: 6)
                Text("\(abbreviation(for: phase)) \(Int((value * 100).rounded()))%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("\(phase.displayName) \(Int((value * 100).rounded())) Prozent")
        }
    }

    private var accuracyColor: Color {
        let a = stat.averageAccuracy
        if a >= 0.85 { return .green }
        if a >= 0.70 { return .orange }
        return .red
    }

    @ViewBuilder
    private var trendIcon: some View {
        if stat.trend > 0.02 {
            Image(systemName: "arrow.up")
                .foregroundStyle(.green)
                .accessibilityLabel("steigend")
        } else if stat.trend < -0.02 {
            Image(systemName: "arrow.down")
                .foregroundStyle(.red)
                .accessibilityLabel("fallend")
        } else {
            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary)
                .accessibilityLabel("stabil")
        }
    }
}

// MARK: - Share sheet wrapper

private struct ActivityViewController: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
