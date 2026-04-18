import SwiftUI

struct PhaseIndicatorView: View {
    let phase: LearningPhase
    let scores: [LearningPhase: CGFloat]

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 14) {
                ForEach(LearningPhase.allCases, id: \.self) { p in
                    phaseDot(for: p)
                }
            }
            Text(phase.displayName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Lernphase: \(phase.displayName)")
    }

    @ViewBuilder
    private func phaseDot(for p: LearningPhase) -> some View {
        let isDone = scores[p] != nil
        let isActive = p == phase

        ZStack {
            Circle()
                .fill(dotColor(isDone: isDone, isActive: isActive))
                .frame(width: 22, height: 22)

            if isDone {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            } else {
                Text(p.icon)
                    .font(.system(size: 10))
            }
        }
        .scaleEffect(isActive ? 1.25 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.65), value: isActive)
    }

    private func dotColor(isDone: Bool, isActive: Bool) -> Color {
        if isDone { return .green }
        if isActive { return .blue }
        return .gray.opacity(0.25)
    }
}
