// WerkstattWorldView.swift
// BuchstabenNative
//
// World 2 — Schreibwerkstatt. Two-column layout: 140pt mode-card panel
// on the left (Buchstabe / Wort), freeform canvas on the right. Reuses
// the existing FreeformWritingView — no tracing/scoring/recognition
// logic is duplicated here; we just configure TracingViewModel's
// writingMode and let the canvas do its thing.

import SwiftUI

struct WerkstattWorldView: View {
    @Environment(TracingViewModel.self) private var vm

    var body: some View {
        ZStack {
            WorldPalette.background(for: .werkstatt)
                .ignoresSafeArea()

            HStack(spacing: 0) {
                modePanel
                Divider()
                freeformContent
            }
        }
        .onAppear {
            // Auto-enter freeform on first landing so the canvas isn't
            // blank on an explicit user intent — MainAppView drops us
            // back to guided whenever they leave this world.
            if vm.writingMode != .freeform {
                vm.enterFreeformMode(subMode: .letter)
            }
        }
        // Freeform canvas is hard-coded `Color.white`; pin the chrome
        // to light mode so .primary stays black even in dark mode.
        .preferredColorScheme(.light)
    }

    // MARK: - Mode panel (left 140pt)

    private var modePanel: some View {
        VStack(spacing: 14) {
            modeCard(
                subMode: .letter,
                title: "Buchstabe",
                subtitle: "Einzelner Buchstabe",
                systemImage: "character"
            )
            modeCard(
                subMode: .word,
                title: "Wort",
                subtitle: "Ganzes Wort",
                systemImage: "text.cursor"
            )
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, 20)
        .frame(width: 140)
        .frame(maxHeight: .infinity)
        .background(Color.white.opacity(0.6))
    }

    @ViewBuilder
    private func modeCard(subMode: FreeformSubMode,
                          title: String,
                          subtitle: String,
                          systemImage: String) -> some View {
        let isActive = vm.freeformSubMode == subMode
        Button {
            if subMode == .word, vm.freeformTargetWord == nil {
                vm.selectFreeformWord(
                    FreeformWordList.all.first
                        ?? FreeformWord(word: "OMA", difficulty: 1))
            } else {
                vm.freeformSubMode = subMode
                vm.clearFreeformCanvas()
            }
        } label: {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(isActive ? Color.white : Color.blue)
                Text(title)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(isActive ? Color.white : Color.primary)
                Text(subtitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(isActive
                                      ? Color.white.opacity(0.95)
                                      : AppSurface.caption)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 120)
            .padding(.horizontal, 8)
            .background(
                isActive ? Color.blue : AppSurface.card,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isActive ? Color.blue : AppSurface.cardEdge,
                            lineWidth: isActive ? 2 : 1)
            )
            .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(subtitle)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - Freeform content (right)

    @ViewBuilder
    private var freeformContent: some View {
        if vm.writingMode == .freeform {
            FreeformWritingView()
        } else {
            // Transient state while enterFreeformMode finishes on first
            // onAppear. Keep the area white so it doesn't flash grey.
            Color.white
        }
    }
}
