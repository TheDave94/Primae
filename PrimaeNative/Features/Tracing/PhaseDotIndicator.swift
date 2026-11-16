// PhaseDotIndicator.swift
// PrimaeNative
//
// Minimal horizontal row of dots representing the learning phases.
// Visual is just coloured circles; labels are accessibility-only.

import SwiftUI

/// The current phase dot's pulse, decided as plain values so the view only
/// replays them (CLAUDE.md, Test Infrastructure 3). `onAppear` and
/// `onChange(of: reduceMotion)` both ask `step`; the view owns no
/// Reduce Motion decision of its own.
nonisolated enum PhaseDotPulse {
    /// What to do to the view's `pulse` flag: the value to set it to, and
    /// whether the repeat-forever pulse animation drives the change.
    struct Step: Equatable {
        let target: Bool
        let animated: Bool
    }

    /// `appearing`: the indicator just came on screen. Otherwise Reduce
    /// Motion changed while it was shown.
    /// - Reduce Motion on: the dot settles enlarged and does not pulse.
    /// - Reduce Motion off, appearing: the pulse starts toward the enlarged end.
    /// - Reduce Motion off, resuming: `pulse` is true while reduced, so the
    ///   pulse resumes from the enlarged end by animating back to false.
    static func step(reduceMotion: Bool, appearing: Bool) -> Step {
        if reduceMotion { return Step(target: true, animated: false) }
        return Step(target: appearing, animated: true)
    }

    /// Only the current phase dot is scaled, and only while `pulse` is set.
    static func scale(isCurrent: Bool, pulse: Bool) -> CGFloat {
        guard isCurrent, pulse else { return TracingCanvasStyle.phaseDotRestScale }
        return TracingCanvasStyle.phaseDotPulseScale
    }
}

struct PhaseDotIndicator: View {
    let phase: LearningPhase
    let scores: [LearningPhase: CGFloat]
    /// Phases the current thesis condition actually runs.
    /// `.guidedOnly`/`.control` only run `.guided`; rendering four dots
    /// there would show three permanently-empty placeholders.
    var activePhases: [LearningPhase] = LearningPhase.allCases

    // Protocol r23 (design audit finding 7): TracingCanvasStyle.
    private let dotSize: CGFloat = TracingCanvasStyle.phaseDotSize
    private let primaryBlue = Color(hex: TracingCanvasStyle.phaseDotFillHex)

    private static let pulseAnimation = Animation.easeInOut(duration: 0.8).repeatForever(autoreverses: true)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 14) {
            ForEach(activePhases, id: \.self) { p in
                dot(for: p)
            }
        }
        .onAppear {
            // Reduce Motion: the current dot stays enlarged, without the pulse.
            let step = PhaseDotPulse.step(reduceMotion: reduceMotion, appearing: true)
            if step.animated {
                withAnimation(Self.pulseAnimation) { pulse = step.target }
            } else {
                pulse = step.target
            }
        }
        // Reduce Motion can change while the indicator is on screen (Settings,
        // Control Centre): `onAppear` alone read it once.
        .onChange(of: reduceMotion) { _, reduced in
            let step = PhaseDotPulse.step(reduceMotion: reduced, appearing: false)
            if step.animated {
                withAnimation(Self.pulseAnimation) { pulse = step.target }
            } else {
                // A mutation with no animation replaces the running
                // repeat-forever one: the dot settles enlarged and stops.
                withAnimation(nil) { pulse = step.target }
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
                    .scaleEffect(PhaseDotPulse.scale(isCurrent: isCurrent, pulse: pulse))
            } else {
                Circle()
                    .strokeBorder(Color(hex: TracingCanvasStyle.phaseDotPendingHex),
                                  lineWidth: TracingCanvasStyle.phaseDotPendingLineWidth)
                    .frame(width: dotSize, height: dotSize)
            }
        }
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
    }
}
