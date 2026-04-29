// WorldSwitcherRail.swift
// PrimaeNative
//
// 64pt-wide vertical rail pinned to the leading edge of MainAppView.
// Three large icons (44×44) select the current world; a gear at the
// bottom opens ParentAreaView, but only after a 2-second long press so
// a 5-year-old can't reach it by accident.

import SwiftUI

struct WorldSwitcherRail: View {
    @Environment(TracingViewModel.self) private var vm
    @Binding var activeWorld: AppWorld
    @Binding var showParentArea: Bool

    /// Progress 0…1 of the in-flight gear long-press. Drives the ring
    /// that fills around the gear icon while the parent holds it down.
    @State private var gearHoldProgress: Double = 0
    /// Fixed 2-second window required to open the parent area.
    private let gearHoldSeconds: Double = 2.0

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 24)
            worldButtons
            Spacer()
            gearButton
                .padding(.bottom, 24)
        }
        .frame(width: 64)
        .frame(maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [AppSurface.railTop, AppSurface.railBottom],
                startPoint: .top, endPoint: .bottom
            )
        )
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.black.opacity(0.06))
                .frame(width: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Navigationsleiste")
    }

    // MARK: - World buttons

    private var worldButtons: some View {
        VStack(spacing: 8) {
            ForEach(AppWorld.allCases) { world in
                worldButton(for: world)
            }
        }
    }

    @ViewBuilder
    private func worldButton(for world: AppWorld) -> some View {
        let isActive = world == activeWorld
        let accent = WorldPalette.accent(for: world)
        Button {
            activeWorld = world
        } label: {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isActive ? accent : accent.opacity(0.14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(isActive ? accent : Color.clear,
                                          lineWidth: 2)
                    )

                VStack(spacing: 3) {
                    Image(systemName: world.icon)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(isActive ? Color.white : accent)
                    Text(world.label)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isActive ? Color.white : accent)
                }
                .frame(width: 44, height: 56)

                if world == .fortschritte, starTotal > 0 {
                    starBadge(count: starTotal)
                        .offset(x: 6, y: -6)
                }
            }
            .frame(width: 48, height: 56)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(world.accessibilityLabel)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }

    private func starBadge(count: Int) -> some View {
        Text(badgeText(for: count))
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(Color.orange, in: Capsule())
            .overlay(Capsule().stroke(Color.white, lineWidth: 1))
            .accessibilityLabel("\(count) Sterne")
    }

    private func badgeText(for n: Int) -> String {
        n > 99 ? "99+" : "\(n)"
    }

    /// Total stars earned across all letters. Sums each letter's
    /// quality-gated star count so the badge agrees with the celebration
    /// overlay and the letter gallery.
    private var starTotal: Int {
        vm.allProgress.values.reduce(0) { acc, prog in
            acc + LetterStars.stars(for: prog.phaseScores)
        }
    }

    // MARK: - Gear long-press

    @ViewBuilder
    private var gearButton: some View {
        ZStack {
            Circle()
                .stroke(Color.gray.opacity(0.25), lineWidth: 2)
                .frame(width: 44, height: 44)
            Circle()
                .trim(from: 0, to: gearHoldProgress)
                .stroke(Color.blue, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: 44, height: 44)
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.1), value: gearHoldProgress)
            Image(systemName: "gear")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(AppSurface.prompt)
        }
        // 44×44 ring + a 4pt invisible padding on each side gives a 48pt
        // hit area, matching iOS HIG for primary nav while leaving the
        // visible gear at its prior size.
        .frame(width: 48, height: 48)
        .contentShape(Rectangle())
        .onLongPressGesture(
            minimumDuration: gearHoldSeconds,
            maximumDistance: 40,
            perform: {
                gearHoldProgress = 0
                showParentArea = true
            },
            onPressingChanged: { pressing in
                if pressing {
                    withAnimation(.linear(duration: gearHoldSeconds)) {
                        gearHoldProgress = 1
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.2)) {
                        gearHoldProgress = 0
                    }
                }
            }
        )
        .accessibilityLabel("Eltern-Bereich")
        .accessibilityHint("Zwei Sekunden lang gedrückt halten, um Einstellungen zu öffnen")
    }
}
