// PhaseRatesView.swift
// BuchstabenNative
//
// Three horizontal bars showing the child's completion rate for each of the
// pedagogical phases (observe / guided / freeWrite). Sourced from
// `DashboardSnapshot.phaseCompletionRates` — the data is captured per
// session in `phaseSessionRecords` and rolled up here for the parent view.
//
// Per-phase distinct colors (blue / teal / purple) so the eye reads the
// difference between phases as the visual variable, not the score
// magnitude — for that, the percentage label on the right is enough.

import SwiftUI

struct PhaseRatesView: View {

    let rates: [String: Double]   // keyed by LearningPhase.rawName

    private struct PhaseRow: Identifiable {
        let id: String
        let label: String
        let color: Color
        let value: Double
    }

    private var rows: [PhaseRow] {
        // Fixed order: observe → guided → freeWrite. Always render all three
        // rows, even when a phase has no data yet, so the parent sees the
        // full pedagogical arc rather than a row that pops in later.
        [
            PhaseRow(id: "observe",
                     label: "Beobachten",
                     color: .blue,
                     value: rates["observe"] ?? 0),
            PhaseRow(id: "guided",
                     label: "Geführt",
                     color: .teal,
                     value: rates["guided"] ?? 0),
            PhaseRow(id: "freeWrite",
                     label: "Frei",
                     color: .purple,
                     value: rates["freeWrite"] ?? 0),
        ]
    }

    var body: some View {
        VStack(spacing: 12) {
            ForEach(rows) { row in
                HStack(spacing: 12) {
                    Text(row.label)
                        .font(.subheadline)
                        .frame(width: 96, alignment: .leading)

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(row.color.opacity(0.15))
                            Capsule()
                                .fill(row.color)
                                .frame(width: max(0, geo.size.width * CGFloat(row.value)))
                        }
                    }
                    .frame(height: 12)

                    Text("\(Int((row.value * 100).rounded())) %")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(row.label) \(Int((row.value * 100).rounded())) Prozent abgeschlossen")
            }
        }
        .padding(.vertical, 4)
    }
}
