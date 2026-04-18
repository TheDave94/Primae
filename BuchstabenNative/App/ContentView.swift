import SwiftUI

// 1. Added 'public' to the struct
public struct ContentView: View {
    @Environment(TracingViewModel.self) private var vm
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showDashboard = false

    // 2. Added a public initializer
    public init() {}

    // 3. Added 'public' to the body
    public var body: some View {
        if !vm.isOnboardingComplete {
            OnboardingView()
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

            if vm.isPhaseSessionComplete {
                CompletionCelebrationOverlay(starsEarned: vm.starsEarned) {
                    vm.loadRecommendedLetter()
                }
                .transition(.scale.combined(with: .opacity))
                .zIndex(10)
            }

            // Debug calibration overlay — drag dots to align with strokes
            if vm.showDebug {
                GeometryReader { geo in
                    StrokeCalibrationOverlay(canvasSize: geo.size)
                }
                .ignoresSafeArea()
            }

            VStack(spacing: 0) {
                // Letter picker bar at top
                LetterPickerBar()
                    .background(.ultraThinMaterial)

                // Child-friendly control bar with phase indicator
                childControlBar

                if vm.showDebug {
                    HStack {
                        DebugInfoPanel()
                        Spacer()
                    }
                    .allowsHitTesting(false)
                    .padding(.horizontal, 12)
                    .padding(.top, 4)

                    debugToggleBar
                        .padding(.horizontal, 12)
                        .padding(.bottom, 4)
                }

                if let toast = vm.toastMessage {
                    Text(toast)
                        .font(.headline)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale))
                        .accessibilityAddTraits(.isStaticText)
                        .padding(.top, 4)
                }

                Spacer()

                if let completion = vm.completionMessage {
                    CompletionHUD(message: completion) {
                        vm.dismissCompletionHUD()
                    }
                    .padding(.bottom, 26)
                    .padding(.horizontal, 12)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: vm.toastMessage)
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.82), value: vm.completionMessage)
        .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.78), value: vm.isPhaseSessionComplete)
        .sensoryFeedback(.success, trigger: vm.completionMessage != nil)
        .sheet(isPresented: $showDashboard) {
            ParentDashboardView()
                .environment(vm)
        }
    }

    private var childControlBar: some View {
        HStack(spacing: 12) {
            PhaseIndicatorView(phase: vm.learningPhase, scores: vm.phaseScores)
                .onLongPressGesture { vm.toggleDebug() }
                .accessibilityHint("Halte gedrückt für Entwickleroptionen")

            Spacer()

            Button {
                vm.resetLetter()
            } label: {
                Image(systemName: "arrow.counterclockwise.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Buchstabe wiederholen")

            Button {
                vm.loadRecommendedLetter()
            } label: {
                Image(systemName: "star.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.yellow)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Empfohlener Buchstabe")

            Button {
                showDashboard = true
            } label: {
                Image(systemName: "gear.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.gray)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Einstellungen")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private var debugToggleBar: some View {
        HStack(spacing: 8) {
            ToggleChip(title: "Ghost", isOn: vm.showGhost, hint: "Show or hide guide lines") { vm.toggleGhost() }
            ToggleChip(title: "Order", isOn: vm.strokeEnforced, hint: "Require stroke order for sound playback") { vm.toggleStrokeEnforcement() }
            ToggleChip(title: "Alle", isOn: vm.showAllLetters, hint: "Alle Buchstaben oder nur Demo-Buchstaben anzeigen") { vm.showAllLetters.toggle() }
            Spacer()
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

private struct DebugInfoPanel: View {
    @Environment(TracingViewModel.self) private var vm

    var body: some View {
        let letterProg = vm.progressStore.progress(for: vm.currentLetterName)
        let priority = LetterScheduler.standard
            .prioritized(available: vm.visibleLetterNames, progress: vm.progressStore.allProgress)
            .first(where: { $0.letter == vm.currentLetterName })?.priority ?? 0
        VStack(alignment: .leading, spacing: 2) {
            Text("Phase: \(vm.learningPhase.displayName)")
            Text("Scores:")
            ForEach(LearningPhase.allCases, id: \.self) { phase in
                Text("  \(phase.rawName): \(String(format: "%.2f", vm.phaseScores[phase] ?? 0))")
            }
            Text("Fréchet: \(String(format: "%.4f", vm.lastFreeWriteDistance))")
            Text("Tier: \(String(describing: vm.currentDifficultyTier))")
            Text("Completions: \(letterProg.completionCount)")
            Text("Best acc: \(String(format: "%.2f", letterProg.bestAccuracy))")
            Text("Priority: \(String(format: "%.2f", priority))")
        }
        .font(.caption.monospaced())
        .foregroundStyle(.white)
        .padding(8)
        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
        .allowsHitTesting(false)
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
