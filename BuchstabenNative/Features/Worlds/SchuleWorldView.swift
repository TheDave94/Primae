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
                if let guided = vm.lastGuidedScore,
                   vm.learningPhase == .freeWrite {
                    guidedFeedbackCard(score: guided)
                        .padding(.top, 8)
                        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                }
                if let assessment = vm.lastWritingAssessment,
                   vm.isPhaseSessionComplete == false,
                   vm.learningPhase == .freeWrite, vm.showFreeWriteOverlay == false {
                    // After the KP overlay dismisses but before the
                    // celebration appears, show the form-accuracy row
                    // so the child sees the Fréchet-based score.
                    formFeedbackCard(score: assessment.formAccuracy)
                        .padding(.top, 8)
                        .transition(reduceMotion ? .opacity : .opacity)
                }
                Spacer()
                bottomBar
            }
            .padding(.vertical, 16)

            if let toast = vm.toastMessage {
                VStack {
                    Text(toast)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(AppSurface.card, in: Capsule())
                        .overlay(Capsule().stroke(AppSurface.cardEdge, lineWidth: 1))
                        .shadow(color: .black.opacity(0.1), radius: 6, y: 2)
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
                        LetterStars.stars(
                            for: vm.progressStore.progress(for: name).phaseScores)
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
        // Tracing canvas is hard-coded `Color.white`; pin the surrounding
        // chrome to light mode so `.primary` resolves to black instead of
        // disappearing into the canvas in dark mode.
        .preferredColorScheme(.light)
    }

    // MARK: - Feedback cards

    private func guidedFeedbackCard(score: CGFloat) -> some View {
        feedbackCard(
            title: "Nachspuren fertig",
            score: score,
            subtitle: "So gut hast du die Linien getroffen."
        )
    }

    private func formFeedbackCard(score: CGFloat) -> some View {
        feedbackCard(
            title: "Selbst geschrieben",
            score: score,
            subtitle: "So ähnlich war deine Form dem Buchstaben."
        )
    }

    private func feedbackCard(title: String, score: CGFloat, subtitle: String) -> some View {
        let pct = Int((max(0, min(1, score)) * 100).rounded())
        let tint: Color = score >= 0.7 ? .green : (score >= 0.5 ? .yellow : .orange)
        return HStack(spacing: 14) {
            VStack(spacing: 2) {
                Text("\(pct)")
                    .font(.system(size: 26, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(tint)
                Text("%")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: 48, height: 48)
            .background(tint.opacity(0.22), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(tint.opacity(0.55), lineWidth: 1))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.bold)).foregroundStyle(.primary)
                Text(subtitle).font(.caption.weight(.medium)).foregroundStyle(AppSurface.caption)
            }
            Spacer()
            HStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { idx in
                    let filled = CGFloat(idx + 1) * 0.33 <= score + 0.01
                    Image(systemName: filled ? "star.fill" : "star")
                        .font(.footnote)
                        .foregroundStyle(filled ? Color.orange : Color.gray.opacity(0.55))
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(AppSurface.card, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(tint.opacity(0.55), lineWidth: 1))
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(pct) Prozent. \(subtitle)")
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
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.down")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(AppSurface.prompt)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(AppSurface.card, in: Capsule())
            .overlay(Capsule().stroke(AppSurface.cardEdge, lineWidth: 1))
            .shadow(color: .black.opacity(0.08), radius: 5, y: 2)
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
                .background(AppSurface.card, in: Capsule())
                .overlay(Capsule().stroke(AppSurface.cardEdge, lineWidth: 1))
                .shadow(color: .black.opacity(0.08), radius: 5, y: 2)
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
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .background(AppSurface.card, in: Circle())
                .overlay(Circle().stroke(AppSurface.cardEdge, lineWidth: 1))
                .shadow(color: .black.opacity(0.08), radius: 5, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
