import SwiftUI

public struct ContentView: View {
    @Environment(TracingViewModel.self) private var vm
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showDashboard = false

    public init() {}

    public var body: some View {
        if !vm.isOnboardingComplete {
            OnboardingView()
        } else if vm.writingMode == .freeform {
            FreeformWritingView()
        } else {
            mainContent
        }
    }

    private var mainContent: some View {
        ZStack(alignment: .top) {
            TracingCanvasView()
                .background(Color.white)
                .ignoresSafeArea()

            // Observe-phase "Schau zu!" modal is suppressed while the
            // calibrator is open — it sits over the center of the glyph,
            // which is exactly where the user is trying to drag dots.
            if vm.learningPhase == .observe, !vm.isCalibrating {
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
            // Stroke calibrator is opt-in via the "Kalibrieren" toggle so its
            // full-screen controls don't have to fight with the letter picker
            // and the audio-tuning panel for the same screen real estate.
            if vm.showDebug && vm.showCalibration {
                GeometryReader { geo in
                    StrokeCalibrationOverlay(canvasSize: geo.size)
                }
                .ignoresSafeArea()
            }
            #endif

            VStack(spacing: 0) {
                // LetterPickerBar sits at the very top of the screen and
                // overlaps the calibrator's mode/add-stroke bar — hide it
                // while calibrating so those controls are reachable.
                if !(vm.showDebug && vm.showCalibration) {
                    SequencePickerBar()
                        .background(.ultraThinMaterial)
                }

                #if DEBUG
                if vm.showDebug {
                    // DebugInfoPanel lives at top-left, exactly where the
                    // calibrator renders its stroke chips and "+ Strich"
                    // button. Keep the toggle bar (so the user can turn
                    // calibration off) but hide the info readout so the
                    // calibrator controls aren't buried under it.
                    if !vm.showCalibration {
                        HStack {
                            DebugInfoPanel()
                            Spacer()
                        }
                        .allowsHitTesting(false)
                        .padding(.horizontal, 12)
                        .padding(.top, 4)
                    }

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

                // Recognition badge — only in guided mode while the KP
                // overlay isn't covering the canvas. Freeform mode has its
                // own in-panel feedback, so we don't show the toast there.
                if vm.writingMode == .guided,
                   !vm.showFreeWriteOverlay,
                   !vm.isRecognitionBadgeDismissed,
                   let r = vm.lastRecognitionResult {
                    RecognitionFeedbackView(
                        result: r,
                        expectedLetter: vm.currentLetterName,
                        onDismiss: { vm.dismissRecognitionBadge() }
                    )
                    .padding(.bottom, 18)
                    .padding(.horizontal, 12)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }

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
                // Hide the audio-tuning panel while calibrating — it covers
                // the calibrator's Save / Apply / JSON buttons otherwise.
                if vm.showDebug && !vm.showCalibration {
                    DebugAudioPanel(vm: vm)
                }
                #endif
                // Everything in the trailing column — PhaseIndicator, the
                // Variante button, and the 5-button controlDock — sits over
                // the right half of the calibrator's bottom bar and hides
                // Apply / Speichern / JSON. Drop the whole column while the
                // calibrator owns the screen; long-press on the toggle chip
                // row still exits debug mode if needed.
                if !vm.isCalibrating {
                    PhaseIndicatorView(phase: vm.learningPhase, scores: vm.phaseScores)
                    #if DEBUG
                        .onLongPressGesture { vm.toggleDebug() }
                        .accessibilityHint("Halte gedrückt für Entwickleroptionen")
                    #endif
                    if vm.currentLetterHasVariants,
                       vm.learningPhase == .guided || vm.learningPhase == .freeWrite {
                        varianteButton
                    }
                    controlDock
                }
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

    private var varianteButton: some View {
        Button(action: { vm.toggleVariant() }) {
            Label(vm.showingVariant ? "Standard" : "Variante",
                  systemImage: "arrow.2.squarepath")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(vm.showingVariant ? .orange : .teal)
        .accessibilityLabel(vm.showingVariant ? "Standard-Form" : "Variante zeigen")
        .accessibilityHint("Wechselt zwischen Standard- und Variante-Schreibweise")
    }

    private var controlDock: some View {
        HStack(spacing: 14) {
            dockButton("arrow.counterclockwise.circle.fill", .orange, "Buchstabe wiederholen") { vm.resetLetter() }
            dockButton("shuffle.circle.fill",                .purple, "Zufälliger Buchstabe")  { vm.randomLetter() }
            dockButton("speaker.wave.2.circle.fill",         .blue,   "Ton abspielen") { vm.replayAudio() }
            dockButton("star.circle.fill",                   .yellow, "Empfohlener Buchstabe") { vm.loadRecommendedLetter() }
            // Freeform entry point. Icon-only so the dock doesn't grow past
            // the canvas width on smaller iPads; sub-mode (Buchstabe / Wort)
            // is picked inside the freeform view itself.
            if vm.enableFreeformMode {
                dockButton("pencil.and.outline", .pink, "Freies Schreiben") {
                    vm.enterFreeformMode(subMode: .letter)
                }
            }
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
            ToggleChip(title: "Kalibrieren", isOn: vm.showCalibration,  hint: "Strich-Kalibrierung öffnen (blendet Audio-Panel und Buchstabenleiste aus)") { vm.toggleCalibration() }
            ToggleChip(title: "Stift",       isOn: vm.inputModeDetector.override == .forcePencil, hint: "Pencil-Layout erzwingen (4 Zellen) — für Debug ohne echten Stift") {
                let current = vm.inputModeDetector.override
                vm.inputModeDetector.override = (current == .forcePencil) ? .auto : .forcePencil
                vm.reapplyGridPreset()
            }
            // Cycles the canonical Austrian Volksschule Woche-1 word list.
            // Pedagogically ordered (shortest → longest): OMA / OMI /
            // OPA are the grandparent trio (Austrian teacher standard),
            // MAMA / PAPA are the universal parent pair, LAMA introduces
            // the doubled A in an animal context, KILO and FILM round out
            // with 4-letter concrete nouns the child encounters daily.
            // Demo-scope feature per thesis plan.
            Button(action: { vm.cycleWord() }) {
                Text("Wort: \(vm.currentWordCycleLabel)")
                    .font(.caption)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.blue.opacity(0.15), in: Capsule())
                    .overlay(Capsule().stroke(Color.blue.opacity(0.4), lineWidth: 1))
            }
            .accessibilityHint("Zyklisch durch Demo-Wörter: OMA, OMI, OPA, MAMA, PAPA, LAMA, KILO, FILM")
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
