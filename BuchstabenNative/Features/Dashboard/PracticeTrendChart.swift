// PracticeTrendChart.swift
// BuchstabenNative
//
// Compact bar chart of daily practice minutes for the most recent 30 days.
// Sourced from `DashboardSnapshot.dailyPracticeMinutes` which fills missing
// days with zero so the timeline reads continuously even when a child skips
// a day. Apple's SwiftUI Charts framework (iOS 16+) handles the layout,
// accessibility (rotor traversal of bars), and Dynamic Type scaling for free.

import SwiftUI
import Charts

struct PracticeTrendChart: View {

    /// Oldest-first list of (day, practice-minutes) tuples. Pass exactly what
    /// `DashboardSnapshot.dailyPracticeMinutes(days:)` returns.
    let series: [(date: Date, minutes: Double)]

    private struct Datum: Identifiable {
        let id: Date
        let minutes: Double
    }
    private var data: [Datum] {
        series.map { Datum(id: $0.date, minutes: $0.minutes) }
    }

    /// Show no chart when the entire window is empty — a wall of zero bars
    /// is uglier than a clean placeholder string.
    private var hasAnyPractice: Bool {
        series.contains { $0.minutes > 0 }
    }

    var body: some View {
        if hasAnyPractice {
            Chart(data) { d in
                BarMark(
                    x: .value("Tag", d.id, unit: .day),
                    y: .value("Minuten", d.minutes)
                )
                .foregroundStyle(Color.blue.gradient)
                .cornerRadius(2)
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3))
            }
            .chartXAxis {
                // Sparse week-grain ticks so 30 days fit without overlap.
                AxisMarks(values: .stride(by: .day, count: 7)) { value in
                    AxisValueLabel(format: .dateTime.day().month(.narrow))
                }
            }
            .frame(height: 140)
            .accessibilityLabel("Übungsverlauf der letzten 30 Tage in Minuten pro Tag")
        } else {
            Text("Noch keine Übungsdaten – starte eine Übung!")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 12)
        }
    }
}
