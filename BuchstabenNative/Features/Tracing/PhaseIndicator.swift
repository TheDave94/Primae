// PhaseIndicator.swift
// BuchstabenNative
//
// Compact visual indicator showing the current learning phase
// with dots for each phase (green = done, blue = active, gray = upcoming).

import SwiftUI

struct PhaseIndicator: View {
    let currentPhase: LearningPhase
    let scores: [LearningPhase: CGFloat]

    init(phase: LearningPhase, scores: [LearningPhase: CGFloat] = [:]) {
        self.currentPhase = phase
        self.scores = scores
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(LearningPhase.allCases, id: \.self) { phase in
                phaseDot(for: phase)
            }

            Text(currentPhase.displayName)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Lernphase")
        .accessibilityValue(accessibilityDescription)
    }

    @ViewBuilder
    private func phaseDot(for phase: LearningPhase) -> some View {
        let isComplete = scores[phase] != nil
        let isActive = phase == currentPhase

        Circle()
            .fill(dotColor(isComplete: isComplete, isActive: isActive))
            .frame(width: 10, height: 10)
            .overlay {
                if isComplete {
                    Image(systemName: "checkmark")
                        .font(.system(size: 6, weight: .bold))
                        .foregroundColor(.white)
                }
            }
    }

    private func dotColor(isComplete: Bool, isActive: Bool) -> Color {
        if isComplete { return .green }
        if isActive { return .blue }
        return .gray.opacity(0.3)
    }

    private var accessibilityDescription: String {
        let completed = scores.count
        let total = LearningPhase.allCases.count
        return "\(currentPhase.displayName), \(completed) von \(total) abgeschlossen"
    }
}
