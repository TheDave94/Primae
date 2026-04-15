// OnboardingFlowView.swift
// BuchstabenNative
//
// First-run onboarding experience with child-friendly colors,
// animated stroke demo, and proper dark-mode support.

import SwiftUI

// MARK: - Main flow container

struct OnboardingFlowView: View {
    @Environment(TracingViewModel.self) private var vm

    var body: some View {
        ZStack {
            // Use a gradient background that works in both light/dark mode
            LinearGradient(
                colors: [Color(red: 0.93, green: 0.95, blue: 1.0),
                         Color(red: 0.98, green: 0.94, blue: 0.96)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // Progress bar
                OnboardingProgressBar(progress: vm.onboardingProgress)
                    .padding(.horizontal, 24)
                    .padding(.top, 16)

                Spacer()

                // Step content
                stepContent

                Spacer()

                // Skip button
                Button("Überspringen") {
                    vm.skipOnboarding()
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.bottom, 24)
            }
        }
        .preferredColorScheme(.light)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch vm.onboardingStep {
        case .welcome:
            WelcomeStepView(onNext: { vm.advanceOnboarding() })
        case .traceDemo:
            TraceDemoStepView(onNext: { vm.advanceOnboarding() })
        case .firstTrace:
            FirstTraceStepView(onNext: { vm.advanceOnboarding() })
        case .rewardIntro:
            RewardIntroStepView(onNext: { vm.advanceOnboarding() })
        case .complete:
            EmptyView()
        }
    }
}

// MARK: - Progress bar

private struct OnboardingProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.black.opacity(0.08))
                    .frame(height: 6)
                Capsule()
                    .fill(Color.blue)
                    .frame(width: geo.size.width * max(0, min(1, progress)), height: 6)
                    .animation(.easeInOut(duration: 0.3), value: progress)
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

// MARK: - Step 1: Welcome

private struct WelcomeStepView: View {
    let onNext: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Text("✏️")
                .font(.system(size: 80))

            Text("Willkommen!")
                .font(.largeTitle.bold())
                .foregroundStyle(.primary)

            Text("Lerne Schritt für Schritt\nBuchstaben zu schreiben")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button(action: onNext) {
                Text("Los geht's!")
                    .font(.headline)
                    .frame(maxWidth: 240)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(32)
    }
}

// MARK: - Step 2: Trace Demo (with animated stroke)

private struct TraceDemoStepView: View {
    let onNext: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Text("👁️")
                .font(.system(size: 64))

            Text("Erst anschauen")
                .font(.title.bold())
                .foregroundStyle(.primary)

            Text("Schau dir an, wie der Buchstabe\ngeschrieben wird.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            // Timer-driven animated "A" stroke demo
            TimelineView(.animation) { timeline in
                let elapsed = timeline.date.timeIntervalSinceReferenceDate
                let cycle = 2.5 // seconds per loop
                let progress = CGFloat((elapsed.truncatingRemainder(dividingBy: cycle)) / cycle)

                ZStack {
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color.white.opacity(0.6))
                        .frame(width: 200, height: 200)

                    Text("A")
                        .font(.system(size: 100, weight: .bold, design: .rounded))
                        .foregroundStyle(.gray.opacity(0.15))

                    AnimatedStrokePath(progress: progress)
                        .frame(width: 160, height: 160)
                }
            }

            Button("Weiter", action: onNext)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(32)
    }
}

/// Simple animated path that draws an "A" shape progressively
private struct AnimatedStrokePath: View {
    let progress: CGFloat

    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            // Left leg
            var left = Path()
            left.move(to: CGPoint(x: w * 0.5, y: h * 0.1))
            left.addLine(to: CGPoint(x: w * 0.15, y: h * 0.9))
            // Right leg
            var right = Path()
            right.move(to: CGPoint(x: w * 0.5, y: h * 0.1))
            right.addLine(to: CGPoint(x: w * 0.85, y: h * 0.9))
            // Crossbar
            var cross = Path()
            cross.move(to: CGPoint(x: w * 0.28, y: h * 0.6))
            cross.addLine(to: CGPoint(x: w * 0.72, y: h * 0.6))

            // Draw ghost
            context.stroke(left, with: .color(.gray.opacity(0.15)), lineWidth: 4)
            context.stroke(right, with: .color(.gray.opacity(0.15)), lineWidth: 4)
            context.stroke(cross, with: .color(.gray.opacity(0.15)), lineWidth: 4)

            // Animated trim — each stroke gets 1/3 of progress
            let seg = progress * 3.0
            if seg > 0 {
                let p1 = min(seg, 1.0)
                context.stroke(left.trimmedPath(from: 0, to: p1),
                    with: .color(.blue), lineWidth: 5)
            }
            if seg > 1 {
                let p2 = min(seg - 1.0, 1.0)
                context.stroke(right.trimmedPath(from: 0, to: p2),
                    with: .color(.blue), lineWidth: 5)
            }
            if seg > 2 {
                let p3 = min(seg - 2.0, 1.0)
                context.stroke(cross.trimmedPath(from: 0, to: p3),
                    with: .color(.blue), lineWidth: 5)
            }

            // Moving dot at current position
            let dot: CGPoint
            if seg <= 1 {
                let t = min(seg, 1.0)
                dot = CGPoint(x: w * (0.5 + (0.15 - 0.5) * t),
                              y: h * (0.1 + (0.9 - 0.1) * t))
            } else if seg <= 2 {
                let t = min(seg - 1.0, 1.0)
                dot = CGPoint(x: w * (0.5 + (0.85 - 0.5) * t),
                              y: h * (0.1 + (0.9 - 0.1) * t))
            } else {
                let t = min(seg - 2.0, 1.0)
                dot = CGPoint(x: w * (0.28 + (0.72 - 0.28) * t),
                              y: h * 0.6)
            }
            context.fill(Circle().path(in: CGRect(x: dot.x - 6, y: dot.y - 6,
                                                   width: 12, height: 12)),
                         with: .color(.orange))
        }
    }
}

// MARK: - Step 3: First Trace

private struct FirstTraceStepView: View {
    let onNext: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Text("✏️")
                .font(.system(size: 64))

            Text("Jetzt nachspuren")
                .font(.title.bold())
                .foregroundStyle(.primary)

            Text("Folge den Punkten mit\ndeinem Finger.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            RoundedRectangle(cornerRadius: 20)
                .fill(Color.blue.opacity(0.05))
                .frame(width: 200, height: 200)
                .overlay {
                    Text("A")
                        .font(.system(size: 100, weight: .bold, design: .rounded))
                        .foregroundStyle(.blue.opacity(0.3))
                }

            Button("Weiter", action: onNext)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(32)
    }
}

// MARK: - Step 4: Reward Intro

private struct RewardIntroStepView: View {
    let onNext: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Text("⭐")
                .font(.system(size: 64))

            Text("Sammle Sterne!")
                .font(.title.bold())
                .foregroundStyle(.primary)

            Text("Für jeden Buchstaben kannst du\nbis zu 3 Sterne verdienen.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                ForEach(LearningPhase.allCases, id: \.self) { phase in
                    VStack(spacing: 6) {
                        Text(phase.icon)
                            .font(.title)
                        Text(phase.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 8)

            Button("Fertig!", action: onNext)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(32)
    }
}
