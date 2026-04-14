// OnboardingFlowView.swift
// BuchstabenNative
//
// Provides the first-run onboarding experience, wiring up the existing
// OnboardingCoordinator state machine (welcome → traceDemo → firstTrace
// → rewardIntro → complete). Kept minimal for the thesis — the focus
// is demonstrating the pedagogical flow, not production-grade polish.

import SwiftUI

// MARK: - Main flow container

struct OnboardingFlowView: View {
    @Environment(TracingViewModel.self) private var vm

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()

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
                .foregroundColor(.secondary)
                .padding(.bottom, 24)
            }
        }
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
            // Should not render — ContentView gates on isOnboardingComplete.
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
                    .fill(Color.gray.opacity(0.15))
                    .frame(height: 6)
                Capsule()
                    .fill(Color.blue)
                    .frame(width: geo.size.width * max(0, min(1, progress)), height: 6)
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

            Text("Lerne Schritt für Schritt\nBuchstaben zu schreiben")
                .font(.title3)
                .foregroundColor(.secondary)
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

            Text("Erst anschauen")
                .font(.title.bold())

            Text("Schau dir an, wie der Buchstabe\ngeschrieben wird.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            // Placeholder for animation preview.
            // In a full implementation this would embed a miniature
            // TracingCanvasView playing the animation guide for "A".
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.gray.opacity(0.1))
                .frame(width: 200, height: 200)
                .overlay {
                    Text("A")
                        .font(.system(size: 100, weight: .bold, design: .rounded))
                        .foregroundColor(.gray.opacity(0.3))
                }

            Button("Weiter", action: onNext)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(32)
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

            Text("Folge den Punkten mit\ndeinem Finger.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            // In the full implementation, this step would embed an actual
            // tracing interaction for the letter "A" and auto-advance
            // on completion. For the thesis, a manual "Weiter" suffices.
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.blue.opacity(0.05))
                .frame(width: 200, height: 200)
                .overlay {
                    Text("A")
                        .font(.system(size: 100, weight: .bold, design: .rounded))
                        .foregroundColor(.blue.opacity(0.3))
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

            Text("Für jeden Buchstaben kannst du\nbis zu 3 Sterne verdienen.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                ForEach(LearningPhase.allCases, id: \.self) { phase in
                    VStack(spacing: 6) {
                        Text(phase.icon)
                            .font(.title)
                        Text(phase.displayName)
                            .font(.caption)
                            .foregroundColor(.secondary)
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
