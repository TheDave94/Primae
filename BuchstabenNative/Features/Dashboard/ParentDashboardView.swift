import SwiftUI
import UIKit

// MARK: - Main View

struct ParentDashboardView: View {
    @Environment(TracingViewModel.self) private var vm
    @State private var shareURL: URL?
    @State private var showExportError = false

    private var snapshot: DashboardSnapshot { vm.dashboardSnapshot }

    var body: some View {
        NavigationStack {
            List {
                ubersichtSection
                starksteBuchstabenSection
                ubungNoetigSection
            }
            .navigationTitle("Lernfortschritt")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    exportButton
                }
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
            LabeledContent("Aktueller Streak") {
                Text("\(vm.currentStreak) \(vm.currentStreak == 1 ? "Tag" : "Tage")")
                    .monospacedDigit()
            }
            LabeledContent("Längster Streak") {
                Text("\(vm.longestStreak) \(vm.longestStreak == 1 ? "Tag" : "Tage")")
                    .monospacedDigit()
            }
            LabeledContent("Übungszeit (7 Tage)") {
                Text(formattedDuration(snapshot.totalPracticeTime(recentDays: 7)))
                    .monospacedDigit()
            }
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
                    LetterStatRow(stat: stat)
                }
            }
        }
    }

    private var ubungNoetigSection: some View {
        Section("Übung nötig") {
            let weak = snapshot.lettersBelow(accuracy: 0.70)
            if weak.isEmpty {
                Text("Alle Buchstaben über 70 % – weiter so!")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(weak, id: \.letter) { stat in
                    LetterStatRow(stat: stat)
                }
            }
        }
    }

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

    var body: some View {
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
        } else if stat.trend < -0.02 {
            Image(systemName: "arrow.down")
                .foregroundStyle(.red)
        } else {
            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary)
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
