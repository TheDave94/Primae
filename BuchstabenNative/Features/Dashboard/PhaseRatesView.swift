// PhaseRatesView.swift
// BuchstabenNative
//
// Horizontal bars showing the child's completion rate for each of the four
// pedagogical phases (observe / direct / guided / freeWrite). Sourced from
// `DashboardSnapshot.phaseCompletionRates` — the data is captured per
// session in `phaseSessionRecords` and rolled up here for the parent view.
//
// Per-phase distinct colors (blue / indigo / teal / purple) so the eye reads
// the difference between phases as the visual variable, not the score
// magnitude — for that, the percentage label on the right is enough. Labels
// come from `LearningPhase.displayName` so the dashboard uses the same
// German wording the child sees in-app.

import SwiftUI

struct PhaseRatesView: View {

    let rates: [String: Double]   // keyed by LearningPhase.rawName

    private static func color(for phase: LearningPhase) -> Color {
        switch phase {
        case .observe:   return .blue
        case .direct:    return .indigo
        case .guided:    return .teal
        case .freeWrite: return .purple
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            // Always render every phase even with no data, so the parent sees
            // the full pedagogical arc rather than a row that pops in later.
            ForEach(LearningPhase.allCases, id: \.self) { phase in
                let value = rates[phase.rawName] ?? 0
                let color = Self.color(for: phase)
                HStack(spacing: 12) {
                    Text(phase.displayName)
                        .font(.subheadline)
                        .frame(width: 128, alignment: .leading)

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(color.opacity(0.15))
                            Capsule()
                                .fill(color)
                                .frame(width: max(0, geo.size.width * CGFloat(value)))
                        }
                    }
                    .frame(height: 12)

                    Text("\(Int((value * 100).rounded())) %")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(phase.displayName) \(Int((value * 100).rounded())) Prozent abgeschlossen")
            }
        }
        .padding(.vertical, 4)
    }
}
