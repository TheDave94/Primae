// PhaseDotIndicator.swift
// BuchstabenNative
//
// Minimal horizontal row of four dots representing the learning phases
// (observe / direct / guided / freeWrite). Replaces the older
// PhaseIndicatorView's larger pill layout when the redesigned worlds
// want a tighter, icon-free HUD. Labels are only exposed via
// accessibilityLabel / long-press peek — the visual is just coloured
// circles so a 5-year-old sees progress at a glance.

import SwiftUI

struct PhaseDotIndicator: View {
    let phase: LearningPhase
    let scores: [LearningPhase: CGFloat]

    private let dotSize: CGFloat = 10

    /// Primary blue used for filled (completed + current) dots.
    private let primaryBlue = Color(red: 0.22, green: 0.54, blue: 0.87)

    @State private var pulse = false

    var body: some View {
        HStack(spacing: 14) {
            ForEach(LearningPhase.allCases, id: \.self) { p in
                dot(for: p)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Lernphase \(phase.displayName)")
        .accessibilityValue("\(completedCount) von \(LearningPhase.allCases.count) abgeschlossen")
    }

    private var completedCount: Int {
        LearningPhase.allCases.filter { scores[$0] != nil }.count
    }

    @ViewBuilder
    private func dot(for p: LearningPhase) -> some View {
        let isCompleted = scores[p] != nil
        let isCurrent = p == phase

        ZStack {
            if isCompleted || isCurrent {
                Circle()
                    .fill(primaryBlue)
                    .frame(width: dotSize, height: dotSize)
                    .scaleEffect(isCurrent ? (pulse ? 1.18 : 1.0) : 1.0)
            } else {
                Circle()
                    .strokeBorder(Color.gray.opacity(0.55), lineWidth: 1.5)
                    .frame(width: dotSize, height: dotSize)
            }
        }
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
    }
}
