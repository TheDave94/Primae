import SwiftUI

// 1. Added 'public' to the struct
public struct ContentView: View {
    @Environment(TracingViewModel.self) private var vm
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // 2. Added a public initializer
    public init() {}

    // 3. Added 'public' to the body
    public var body: some View {
        if !vm.isOnboardingComplete {
            OnboardingFlowView()
        } else {
            mainContent
        }
    }

    private var mainContent: some View {
        ZStack(alignment: .top) {
            TracingCanvasView()
                .background(Color.white)
                .ignoresSafeArea()

            // Observe phase: touch is disabled, show tap-to-continue overlay
            if vm.learningPhase == .observe {
                ObservePhaseOverlay {
                    vm.completeObservePhase()
                }
            }

            VStack(spacing: 10) {
                topBar
                if let toast = vm.toastMessage {
                    Text(toast)
                        .font(.headline)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale))
                        .accessibilityAddTraits(.isStaticText)
                }

                Spacer()

                if let completion = vm.completionMessage {
                    CompletionHUD(message: completion) {
                        vm.dismissCompletionHUD()
                    }
                    .padding(.bottom, 26)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.top, 12)
            .padding(.horizontal, 12)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: vm.toastMessage)
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.82), value: vm.completionMessage)
        .sensoryFeedback(.success, trigger: vm.completionMessage != nil)
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            ToggleChip(title: "Ghost", isOn: vm.showGhost, hint: "Show or hide guide lines") { vm.toggleGhost() }
            ToggleChip(title: "Order", isOn: vm.strokeEnforced, hint: "Require stroke order for sound playback") { vm.toggleStrokeEnforcement() }
            ToggleChip(title: "Debug", isOn: vm.showDebug, hint: "Show debug overlays") { vm.toggleDebug() }

            Button("Reset") { vm.resetLetter() }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Reset current letter")
                .accessibilityHint("Clears current stroke progress")

            PhaseIndicator(phase: vm.learningPhase, scores: vm.phaseScores)

            Button("📚") { vm.loadRecommendedLetter() }
                .buttonStyle(.bordered)
                .accessibilityLabel("Empfohlener Buchstabe")

            Spacer(minLength: 6)

            HStack(spacing: 6) {
                Circle()
                    .fill(vm.isPlaying ? .green : .red)
                    .frame(width: 12, height: 12)
                    .accessibilityHidden(true)

                Text(vm.currentLetterName)
                    .font(.headline)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Current letter")
            .accessibilityValue(vm.currentLetterName)
            .accessibilityHint(vm.isPlaying ? "Audio is currently playing" : "Audio is currently paused")
        }
    }
}

private struct ObservePhaseOverlay: View {
    let onContinue: () -> Void

    var body: some View {
        VStack {
            Spacer()
            VStack(spacing: 12) {
                Text("👁️ Beobachte den Buchstaben")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("Tippe hier um fortzufahren")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
            .background(.blue.opacity(0.85), in: RoundedRectangle(cornerRadius: 16))
            .shadow(radius: 8)
            .padding(.bottom, 60)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(perform: onContinue)
        .accessibilityLabel("Beobachtungsphase")
        .accessibilityHint("Tippe um zur nächsten Phase zu wechseln")
    }
}

private struct ToggleChip: View {
    let title: String
    let isOn: Bool
    let hint: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.borderedProminent)
        .tint(isOn ? .blue : .gray)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityHint(hint)
    }
}

private struct CompletionHUD: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.green)
                .font(.title3)

            Text(message)
                .font(.headline)
                .multilineTextAlignment(.leading)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(.thinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss completion message")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.green.opacity(0.28), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.1), radius: 10, y: 5)
    }
}
