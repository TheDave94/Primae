import SwiftUI

public struct ContentView: View {
    @Environment(TracingViewModel.self) private var vm
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showDashboard = false

    public init() {}

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

            if vm.learningPhase == .observe {
                ObservePhaseOverlay { vm.completeObservePhase() }
            }

            if vm.isPhaseSessionComplete {
                CompletionCelebrationOverlay(starsEarned: vm.starsEarned) {
                    vm.loadRecommendedLetter()
                }
                .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
                .zIndex(10)
            }

            if vm.showPaperTransfer {
                PaperTransferView(letter: vm.currentLetterName) { score in
                    vm.submitPaperTransfer(score: score)
                }
                .transition(.opacity)
                .zIndex(15)
            }

            #if DEBUG
            if vm.showDebug {
                GeometryReader { geo in
                    StrokeCalibrationOverlay(canvasSize: geo.size)
                }
                .ignoresSafeArea()
            }
            #endif

            VStack(spacing: 0) {
                LetterPickerBar()
                    .background(.ultraThinMaterial)

                #if DEBUG
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
                #endif

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

            VStack(alignment: .trailing, spacing: 10) {
                Spacer()
                #if DEBUG
                if vm.showDebug {
                    DebugAudioPanel(vm: vm)
                }
                #endif
                PhaseIndicatorView(phase: vm.learningPhase, scores: vm.phaseScores)
                #if DEBUG
                    .onLongPressGesture { vm.toggleDebug() }
                    .accessibilityHint("Halte gedrückt für Entwickleroptionen")
                #endif
                controlDock
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 16)
            .padding(.bottom, 24)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: vm.toastMessage)
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.82), value: vm.completionMessage)
        .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.78), value: vm.isPhaseSessionComplete)
        .sensoryFeedback(.success, trigger: vm.completionMessage != nil)
        .sensoryFeedback(.success, trigger: vm.isPhaseSessionComplete)
        .sheet(isPresented: $showDashboard) {
            ParentDashboardView()
                .environment(vm)
        }
    }

    private var controlDock: some View {
        HStack(spacing: 14) {
            dockButton("arrow.counterclockwise.circle.fill", .orange, "Buchstabe wiederholen") { vm.resetLetter() }
            dockButton("shuffle.circle.fill",                .purple, "Zufälliger Buchstabe")  { vm.randomLetter() }
            dockButton("speaker.wave.2.circle.fill",         .blue,   "Ton abspielen")         { vm.replayAudio() }
            dockButton("star.circle.fill",                   .yellow, "Empfohlener Buchstabe") { vm.loadRecommendedLetter() }
            dockButton("gear.circle.fill",                   .gray,   "Einstellungen")         { showDashboard = true }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 1))
        .shadow(color: .black.opacity(0.1), radius: 8, y: 2)
    }

    private func dockButton(_ systemName: String,
                            _ color: Color,
                            _ label: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 32))
                .foregroundStyle(color)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var debugToggleBar: some View {
        HStack(spacing: 8) {
            ToggleChip(title: "Hilfslinien",  isOn: vm.showGhost,       hint: "Hilfslinien ein- oder ausblenden")         { vm.toggleGhost() }
            ToggleChip(title: "Reihenfolge", isOn: vm.strokeEnforced,   hint: "Strichreihenfolge für Ton erzwingen")      { vm.toggleStrokeEnforcement() }
            ToggleChip(title: "Alle",        isOn: vm.showAllLetters,   hint: "Alle Buchstaben oder nur Demo-Buchstaben") { vm.showAllLetters.toggle() }
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
                Text("👁️  Schau zu!")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                Text("👆  Tippen")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.9))
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
        .accessibilityHint("Tippe, um zur nächsten Phase zu wechseln")
        .accessibilityAddTraits(.isButton)
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
        .accessibilityValue(isOn ? "Ein" : "Aus")
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
            if let a = vm.lastWritingAssessment {
                Text("Form:    \(String(format: "%.2f", a.formAccuracy))")
                Text("Tempo:   \(String(format: "%.2f", a.tempoConsistency))")
                Text("Druck:   \(String(format: "%.2f", a.pressureControl))")
                Text("Rhythmus:\(String(format: "%.2f", a.rhythmScore))")
                Text("Gesamt:  \(String(format: "%.2f", a.overallScore))")
            }
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
            .accessibilityLabel("Erfolgsmeldung schließen")
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
