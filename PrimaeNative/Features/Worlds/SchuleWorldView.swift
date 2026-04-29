// SchuleWorldView.swift
// PrimaeNative
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
        if vm.visibleLetterNames.isEmpty {
            ContentUnavailableView(
                "Buchstaben nicht geladen",
                systemImage: "exclamationmark.triangle",
                description: Text("Bitte die App neu starten.")
            )
        } else {
        ZStack {
            WorldPalette.background(for: .schule)
                .ignoresSafeArea()

            TracingCanvasView()
                .background(Color.canvasPaper)
                .clipShape(RoundedRectangle(cornerRadius: Radii.xl, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Radii.xl, style: .continuous)
                        .stroke(Color.paperEdge, lineWidth: 1)
                )
                .padding(.horizontal, 16)
                .padding(.top, 64)
                .padding(.bottom, 86)
                .shadow(color: Color.ink.opacity(0.08), radius: 18, y: 4)

            if vm.learningPhase == .observe, !vm.isCalibrating {
                observeOverlay
            }

            // All post-freeWrite overlays flow through the overlay queue —
            // no two can stack because the queue serialises them in canonical
            // order: kpOverlay → recognitionBadge → paperTransfer → celebration.
            // (KP overlay is rendered inside TracingCanvasView so it has
            // access to the live canvas geometry; the modals below sit on
            // top of the world chrome.)
            queuedModalOverlay

            VStack {
                topRow
                if let guided = vm.lastGuidedScore,
                   vm.learningPhase == .freeWrite {
                    guidedFeedbackCard(score: guided)
                        .padding(.top, 8)
                        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                }
                if let assessment = vm.lastWritingAssessment,
                   vm.learningPhase == .freeWrite,
                   !isQueueShowingKPOverlay {
                    // After the KP overlay dismisses but before the
                    // celebration appears, show the form-accuracy row.
                    // C-6: isPhaseSessionComplete guard removed — it was
                    // always true by first re-render (phaseController.advance
                    // sets the flag before returning), so the card never
                    // rendered. The remaining guards (phase == .freeWrite,
                    // no KP overlay) are sufficient; the celebration modal
                    // is opaque and covers this card when it appears.
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
                        .font(.body(FontSize.base, weight: .semibold))
                        .foregroundStyle(Color.ink)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(AppSurface.card, in: Capsule())
                        .overlay(Capsule().stroke(AppSurface.cardEdge, lineWidth: 1))
                        .shadow(color: Color.ink.opacity(0.10), radius: 6, y: 2)
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
                        // Read via the @Observable allProgress
                        // mirror (not progress(for:)) so the
                        // picker chip refreshes after a fresh
                        // completion without dismissing-+-reopening.
                        LetterStars.stars(
                            for: (vm.allProgress[name] ?? LetterProgress()).phaseScores)
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
                   value: vm.overlayQueue.currentOverlay)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: showLetterPicker)
        // Canvas now uses Color.canvasPaper (Primae token, dynamic),
        // so the world participates in the user's chosen appearance
        // (Hell / Dunkel / System) — no light-mode lock required.
        } // end else
    }

    // MARK: - Queue-driven modal overlays

    /// Renders whichever overlay the OverlayQueueManager currently has on
    /// top, except for the KP overlay (which lives in TracingCanvasView so
    /// it can reach the canvas geometry). Returns an empty view for that
    /// case and for `nil`, letting the queue advance naturally.
    @ViewBuilder
    private var queuedModalOverlay: some View {
        switch vm.overlayQueue.currentOverlay {
        case .recognitionBadge(let result):
            VStack {
                Spacer().frame(height: 88)
                RecognitionFeedbackView(
                    result: result,
                    expectedLetter: vm.currentLetterName,
                    onDismiss: { vm.overlayQueue.dismiss() }
                )
                Spacer()
            }
            .transition(reduceMotion
                        ? .opacity
                        : .opacity.combined(with: .scale(scale: 0.9)))
            .zIndex(12)
        case .paperTransfer(let letter):
            PaperTransferView(letter: letter) { score in
                vm.submitPaperTransfer(score: score)
            }
            .transition(.opacity)
            .zIndex(15)
        case .celebration(let stars):
            CompletionCelebrationOverlay(starsEarned: stars, maxStars: vm.maxStars) {
                vm.loadRecommendedLetter()
            }
            .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
            .zIndex(20)
        case .rewardCelebration(let event):
            // U1 (ROADMAP_V5): timed (2.5 s) one-shot achievement
            // celebration. Auto-dismisses through the queue's own
            // timer; tap-to-dismiss for impatient users.
            RewardCelebrationOverlay(event: event)
                .onTapGesture { vm.overlayQueue.dismiss() }
                .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
                .zIndex(25)
        case .retrievalPrompt(let letter, let distractors):
            // P1 (ROADMAP): spaced-retrieval recognition. Modal — child
            // must answer before tracing begins. Audio cue plays the
            // active letter's audio (name or phoneme depending on the
            // existing P6 toggle) via vm.replayAudio.
            RetrievalPromptView(
                target: letter,
                distractors: distractors,
                onPlayAudio: { vm.replayAudio() },
                onAnswer: { _, correct in
                    vm.submitRetrievalAnswer(letter: letter, correct: correct)
                }
            )
            .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
            .zIndex(22)
        case .kpOverlay:
            // KP overlay is rendered by `TracingCanvasView` itself (it
            // needs the canvas geometry and reference-stroke data) — the
            // queueModalOverlay branch only handles full-screen modals.
            EmptyView()
        case .frechetScore:
            // Reserved enum case for a future inline Fréchet-score chip.
            // Currently the inline form/guided feedback cards in this
            // view render the signal instead; the queue case is kept so
            // a downstream caller can re-introduce the chip without an
            // enum-shape migration. See OverlayQueueManager.CanvasOverlay.
            EmptyView()
        case .none:
            EmptyView()
        }
    }

    /// True while the overlay queue is actively showing the KP (Knowledge
    /// of Performance) overlay. Used to suppress the inline form-accuracy
    /// card during the KP window so the two don't overlap.
    private var isQueueShowingKPOverlay: Bool {
        if case .kpOverlay = vm.overlayQueue.currentOverlay { return true }
        return false
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

    /// Verbal feedback band shown above the canvas during the freeWrite
    /// transition. Children must NEVER see numeric metrics — they get a
    /// star count + a short German encouragement line + a colour swatch
    /// that signals quality without spelling out a percentage. The exact
    /// numeric scores all the metrics produce live in the research
    /// dashboard (parent-gated) and the CSV/TSV thesis export.
    private func feedbackCard(title: String, score: CGFloat, subtitle: String) -> some View {
        let tint: Color = score >= 0.7 ? .green : (score >= 0.5 ? .yellow : .orange)
        let starsEarned = score >= 0.85 ? 3 : (score >= 0.6 ? 2 : (score >= 0.35 ? 1 : 0))
        let praise: String
        switch starsEarned {
        case 3: praise = "Super gemacht!"
        case 2: praise = "Gut gemacht!"
        case 1: praise = "Schon ganz gut."
        default: praise = "Probier es nochmal."
        }
        return HStack(spacing: 14) {
            // Mood swatch — colour conveys quality, no number.
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(tint.opacity(0.22))
                RoundedRectangle(cornerRadius: 12)
                    .stroke(tint.opacity(0.55), lineWidth: 1)
                Image(systemName: starsEarned >= 2
                                  ? "hand.thumbsup.fill"
                                  : "sparkles")
                    .font(.display(FontSize.md))
                    .foregroundStyle(tint)
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body(FontSize.sm, weight: .bold)).foregroundStyle(Color.ink)
                Text(praise).font(.body(FontSize.xs, weight: .medium)).foregroundStyle(AppSurface.caption)
            }
            Spacer()
            HStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { idx in
                    let filled = idx < starsEarned
                    Image(systemName: filled ? "star.fill" : "star")
                        .font(.footnote)
                        .foregroundStyle(filled ? AppSurface.starGold : Color.starEmpty)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(AppSurface.card, in: RoundedRectangle(cornerRadius: Radii.md))
        .overlay(RoundedRectangle(cornerRadius: Radii.md).stroke(tint.opacity(0.55), lineWidth: 1))
        .shadow(color: Color.ink.opacity(0.08), radius: 6, y: 2)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(praise) \(subtitle)")
    }

    // MARK: - Top row (letter pill)

    private var topRow: some View {
        HStack {
            letterPill
            Spacer()
            if totalStars > 0 {
                starCountBadge(count: totalStars)
            }
        }
        .padding(.horizontal, 16)
    }

    /// Total stars across all letters — same computation the world
    /// rail's Sterne badge uses so the two displays always agree.
    private var totalStars: Int {
        vm.allProgress.values.reduce(0) { acc, prog in
            acc + LetterStars.stars(for: prog.phaseScores)
        }
    }

    /// Persistent header pill: a yellow star + the running total.
    /// Mirrors the world-rail badge styling so a child who has
    /// noticed one recognises the other; placed in the top-right of
    /// Schule so accumulating stars is visible without world-switching.
    private func starCountBadge(count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "star.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(AppSurface.starGold)
            Text(count > 99 ? "99+" : "\(count)")
                .font(.display(FontSize.base, weight: .bold))
                .foregroundStyle(Color.ink)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(AppSurface.card, in: Capsule())
        .overlay(Capsule().stroke(AppSurface.cardEdge, lineWidth: 1))
        .shadow(color: Color.ink.opacity(0.08), radius: 5, y: 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) Sterne gesamt")
    }

    private var letterPill: some View {
        Button {
            withAnimation { showLetterPicker = true }
        } label: {
            HStack(spacing: 8) {
                Text(vm.currentLetterName)
                    .font(.display(FontSize.lg, weight: .bold))
                    .foregroundStyle(Color.ink)
                Image(systemName: "chevron.down")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(AppSurface.prompt)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(AppSurface.card, in: Capsule())
            .overlay(Capsule().stroke(AppSurface.cardEdge, lineWidth: 1))
            .shadow(color: Color.ink.opacity(0.08), radius: 5, y: 2)
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
        // The child can't read, so the spoken prompt
        // (`ChildSpeechLibrary.phaseEntry(.observe)` — "Schau mal
        // genau hin.") + the live guide-dot animation are the actual
        // phase cue. The on-screen overlay is just two glyphs in a
        // brand pill: an eye for "watch" and a finger for "tap to
        // continue when ready". No text — words wouldn't reach the
        // intended user anyway, and they cluttered the canvas.
        VStack {
            Spacer()
            HStack(spacing: 18) {
                Text("👁️").font(.system(size: 36))
                Text("👆").font(.system(size: 36))
            }
            .padding(.horizontal, 28).padding(.vertical, 16)
            .background(Color.brand, in: Capsule())
            .shadow(color: Color.brand.opacity(0.30), radius: 12, y: 4)
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
            PhaseDotIndicator(phase: vm.learningPhase, scores: vm.phaseScores,
                              activePhases: vm.activePhases)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(AppSurface.card, in: Capsule())
                .overlay(Capsule().stroke(AppSurface.cardEdge, lineWidth: 1))
                .shadow(color: Color.ink.opacity(0.08), radius: 5, y: 2)
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
                .foregroundStyle(Color.ink)
                .frame(width: 44, height: 44)
                .background(AppSurface.card, in: Circle())
                .overlay(Circle().stroke(AppSurface.cardEdge, lineWidth: 1))
                .shadow(color: Color.ink.opacity(0.08), radius: 5, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
