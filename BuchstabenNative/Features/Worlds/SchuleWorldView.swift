// SchuleWorldView.swift
// BuchstabenNative
//
// World 1 — Buchstaben-Schule. Hosts the existing TracingCanvasView
// full-bleed with a minimal HUD: current-letter pill in the top-left
// (long-press to open LetterWheelPicker), phase dots flanked by
// prev/next arrows at the bottom. All scoring / audio / recognition
// pipelines remain on TracingViewModel — this view only replaces the
// surrounding chrome.

import SwiftUI

struct SchuleWorldView: View {
    @Environment(TracingViewModel.self) private var vm
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var showLetterPicker = false

    var body: some View {
        ZStack {
            WorldPalette.background(for: .schule)
                .ignoresSafeArea()

            TracingCanvasView()
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(Color.black.opacity(0.08), lineWidth: 1)
                )
                .padding(.horizontal, 16)
                .padding(.top, 64)
                .padding(.bottom, 86)
                .shadow(color: .black.opacity(0.08), radius: 18, y: 4)

            if vm.learningPhase == .observe, !vm.isCalibrating {
                observeOverlay
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

            VStack {
                topRow
                Spacer()
                bottomBar
            }
            .padding(.vertical, 16)

            if let toast = vm.toastMessage {
                VStack {
                    Text(toast)
                        .font(.headline)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 80)
                    Spacer()
                }
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale))
            }

            if showLetterPicker {
                LetterWheelPicker(
                    letters: vm.visibleLetterNames,
                    currentLetter: vm.currentLetterName,
                    starCount: { name in
                        vm.progressStore.progress(for: name).phaseScores?
                            .values.filter { $0 > 0 }.count ?? 0
                    },
                    onSelect: { letter in
                        vm.loadLetter(name: letter)
                        withAnimation { showLetterPicker = false }
                    },
                    onDismiss: {
                        withAnimation { showLetterPicker = false }
                    }
                )
                .zIndex(30)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: vm.toastMessage)
        .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.78),
                   value: vm.isPhaseSessionComplete)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: showLetterPicker)
    }

    // MARK: - Top row (letter pill)

    private var topRow: some View {
        HStack {
            letterPill
            Spacer()
        }
        .padding(.horizontal, 16)
    }

    private var letterPill: some View {
        Button {
            withAnimation { showLetterPicker = true }
        } label: {
            HStack(spacing: 8) {
                Text(vm.currentLetterName)
                    .font(.system(.title, design: .rounded).weight(.bold))
                Image(systemName: "chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.black.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            // Tap or long-press both open the picker — the long-press
            // gesture mirrors the spec's "long-press the letter" wording
            // while the tap fallback keeps the UI obvious for a child.
            LongPressGesture(minimumDuration: 0.4).onEnded { _ in
                withAnimation { showLetterPicker = true }
            }
        )
        .accessibilityLabel("Aktueller Buchstabe \(vm.currentLetterName)")
        .accessibilityHint("Tippen oder gedrückt halten, um einen anderen Buchstaben zu wählen")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Observe overlay

    private var observeOverlay: some View {
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
            .padding(.horizontal, 28).padding(.vertical, 18)
            .background(.blue.opacity(0.85), in: RoundedRectangle(cornerRadius: 16))
            .shadow(radius: 8)
            .padding(.bottom, 100)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { vm.completeObservePhase() }
        .accessibilityLabel("Beobachtungsphase")
        .accessibilityHint("Tippe, um zur nächsten Phase zu wechseln")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Bottom bar (phase dots + letter nav)

    private var bottomBar: some View {
        HStack(spacing: 24) {
            navArrow(systemName: "chevron.left",
                     label: "Vorheriger Buchstabe") { vm.previousLetter() }
            PhaseDotIndicator(phase: vm.learningPhase, scores: vm.phaseScores)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
            navArrow(systemName: "chevron.right",
                     label: "Nächster Buchstabe") { vm.nextLetter() }
        }
        .padding(.bottom, 8)
    }

    private func navArrow(systemName: String,
                          label: String,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(Color.black.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
