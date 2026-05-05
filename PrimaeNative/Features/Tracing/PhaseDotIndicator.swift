// PhaseDotIndicator.swift
// PrimaeNative
//
// Minimal horizontal row of dots representing the learning phases.
// Visual is just coloured circles; labels are accessibility-only.

import SwiftUI

struct PhaseDotIndicator: View {
    let phase: LearningPhase
    let scores: [LearningPhase: CGFloat]
    /// Phases the current thesis condition actually runs.
    /// `.guidedOnly`/`.control` only run `.guided`; rendering four dots
    /// there would show three permanently-empty placeholders.
    var activePhases: [LearningPhase] = LearningPhase.allCases

    private let dotSize: CGFloat = 10
    private let primaryBlue = Color(red: 0.22, green: 0.54, blue: 0.87)

    @State private var pulse = false

    var body: some View {
        HStack(spacing: 14) {
            ForEach(activePhases, id: \.self) { p in
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
        .accessibilityValue("\(completedCount) von \(activePhases.count) abgeschlossen")
    }

    private var completedCount: Int {
        activePhases.filter { scores[$0] != nil }.count
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
