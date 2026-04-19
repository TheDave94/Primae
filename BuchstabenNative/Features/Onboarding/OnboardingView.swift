// OnboardingView.swift
// BuchstabenNative
//
// 4-step onboarding flow for first-time users.

import SwiftUI

// MARK: - Main container

struct OnboardingView: View {
    @Environment(TracingViewModel.self) private var vm

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.93, green: 0.95, blue: 1.0),
                         Color(red: 0.98, green: 0.94, blue: 0.96)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                OnboardingProgressBar(progress: vm.onboardingProgress)
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
                    .accessibilityLabel("Einführung")
                    .accessibilityValue("\(Int((vm.onboardingProgress * 100).rounded())) Prozent")

                Spacer()

                stepContent

                Spacer()

                Text("Für Eltern: gedrückt halten zum Überspringen")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 24)
                    .contentShape(Rectangle())
                    .onLongPressGesture(minimumDuration: 1.5) { vm.skipOnboarding() }
                    .accessibilityLabel("Einführung überspringen")
                    .accessibilityHint("Gedrückt halten, nur für Erwachsene")
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

            Text("Lerne Buchstaben zu schreiben")
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

// MARK: - Step 2: Trace Demo

private struct TraceDemoStepView: View {
    let onNext: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Text("👁️")
                .font(.system(size: 64))

            Text("Erst gucken")
                .font(.title.bold())
                .foregroundStyle(.primary)

            Text("Schau, wie der Buchstabe\ngeschrieben wird!")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            TimelineView(.animation) { timeline in
                let elapsed = timeline.date.timeIntervalSinceReferenceDate
                let cycle = 2.5
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

private struct AnimatedStrokePath: View {
    let progress: CGFloat

    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            var left = Path()
            left.move(to: CGPoint(x: w * 0.50, y: h * 0.00))
            left.addLine(to: CGPoint(x: w * 0.05, y: h * 1.00))
            var right = Path()
            right.move(to: CGPoint(x: w * 0.50, y: h * 0.00))
            right.addLine(to: CGPoint(x: w * 0.95, y: h * 1.00))
            var cross = Path()
            cross.move(to: CGPoint(x: w * 0.22, y: h * 0.62))
            cross.addLine(to: CGPoint(x: w * 0.78, y: h * 0.62))

            context.stroke(left, with: .color(.gray.opacity(0.15)), lineWidth: 4)
            context.stroke(right, with: .color(.gray.opacity(0.15)), lineWidth: 4)
            context.stroke(cross, with: .color(.gray.opacity(0.15)), lineWidth: 4)

            let seg = progress * 3.0
            if seg > 0 {
                context.stroke(left.trimmedPath(from: 0, to: min(seg, 1.0)),
                    with: .color(.blue), lineWidth: 5)
            }
            if seg > 1 {
                context.stroke(right.trimmedPath(from: 0, to: min(seg - 1.0, 1.0)),
                    with: .color(.blue), lineWidth: 5)
            }
            if seg > 2 {
                context.stroke(cross.trimmedPath(from: 0, to: min(seg - 2.0, 1.0)),
                    with: .color(.blue), lineWidth: 5)
            }

            let dot: CGPoint
            if seg <= 1 {
                let t = min(seg, 1.0)
                dot = CGPoint(x: w * (0.50 + (0.05 - 0.50) * t), y: h * t)
            } else if seg <= 2 {
                let t = min(seg - 1.0, 1.0)
                dot = CGPoint(x: w * (0.50 + (0.95 - 0.50) * t), y: h * t)
            } else {
                let t = min(seg - 2.0, 1.0)
                dot = CGPoint(x: w * (0.22 + (0.78 - 0.22) * t), y: h * 0.62)
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

            Text("Jetzt nachmalen")
                .font(.title.bold())
                .foregroundStyle(.primary)

            Text("Tippe die blauen Punkte\nmit dem Finger an!")
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

            Text("Für jeden Buchstaben bekommst du\nbis zu 4 Sterne!")
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
