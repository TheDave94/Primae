// WorldSwitcherRail.swift
// PrimaeNative
//
// 64pt vertical rail. Three world icons; gear at the bottom opens
// `ParentAreaView` after a 2-second long press so a 5-year-old can't
// reach it by accident.
//
// A DOUBLE-TAP anywhere on the rail reveals a "Nächstes Kind" button
// just above the gear (2026-10-01) — the same bar, one gesture, no
// navigation. It exists because enrolling 30-40 children in a row via
// gear-hold → Research Dashboard → share sheet → force-quit relaunch was
// seven steps per child. The button auto-hides after
// `nextChildRevealSeconds` so it is never sitting on the child-facing
// screen while a child is drawing; the destructive step is still behind
// `NextParticipantControl`'s confirmation.

import SwiftUI

struct WorldSwitcherRail: View {
    @Environment(TracingViewModel.self) private var vm
    @Binding var activeWorld: AppWorld
    @Binding var showParentArea: Bool

    /// 0…1 progress of the in-flight gear long-press.
    @State private var gearHoldProgress: Double = 0
    /// Hold duration required to open the parent area.
    private let gearHoldSeconds: Double = 2.0
    /// Whether the proctor's "next child" button is currently revealed.
    @State private var showNextChild = false
    /// How long the revealed button stays up before hiding itself again.
    private let nextChildRevealSeconds: Double = 15.0

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 24)
            #if !STUDY_BUILD
            // One world remains in a study build, so a switcher would be a
            // button that selects what is already selected. The rail itself
            // stays: it carries the gear, which is the proctor's only route
            // into the parent area.
            worldButtons
            #endif
            Spacer()
            // ALWAYS MOUNTED, never removed. Hiding it by unmounting
            // (`if showNextChild`) also destroyed the "Neues Kind bereit"
            // alert the control presents, because the rail hid the button
            // in the same update cycle that set the alert — the alert
            // never appeared at all. Visibility is therefore driven by
            // opacity + hit-testing, and `accessibilityHidden` keeps the
            // hidden button out of the accessibility tree (so VoiceOver
            // cannot reach an invisible control, and a UI test looking for
            // "Nächstes Kind" is still a real assertion rather than one
            // trivially satisfied by a permanently-present view).
            NextParticipantControl(onReset: {
                // Safe to unmount-by-hide now: the control stays in the
                // tree (opacity/hit-testing only), so clearing this does
                // not take its alert with it.
                withAnimation(.easeOut(duration: 0.2)) { showNextChild = false }
            }) {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.inkSoft)
            }
            .accessibilityLabel("Nächstes Kind")
            .frame(width: 48, height: 48)
            .contentShape(Rectangle())
            .padding(.bottom, 8)
            .opacity(showNextChild ? 1 : 0)
            .allowsHitTesting(showNextChild)
            .accessibilityHidden(!showNextChild)
            gearButton
                .padding(.bottom, 24)
        }
        .frame(width: 64)
        .frame(maxHeight: .infinity)
        // The double-tap catcher lives in the BACKGROUND, behind the
        // rail's own content, and that placement is load-bearing.
        //
        // First attempt put `contentShape(Rectangle())` + `onTapGesture`
        // on the rail itself, which made the empty bar hit-testable and
        // so made the gesture fire — but it also made the rail compete
        // with the GEAR's own 2-second long press for every touch, and
        // that broke the parent-area entry: the previously-green
        // testSecondEnrolmentUsableWithoutRelaunch stopped being able to
        // open the parent area at all.
        //
        // Behind the content, the catcher receives the taps that land on
        // empty bar (which is where a proctor aims) and the gear keeps
        // sole ownership of its own press. Two further details: it needs
        // an explicit `contentShape` because a container only hit-tests
        // where it draws, and `worldButtons` is compiled out in a study
        // build so the bar is empty everywhere but the gear; and it must
        // go on the outer 64pt frame, since the VStack's own layout width
        // is only its widest child (the 48pt gear).
        .background {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    withAnimation(.easeOut(duration: 0.2)) { showNextChild.toggle() }
                }
        }
        // Auto-hide so the button cannot still be on screen when the
        // proctor hands the iPad to the next child. Re-armed on every
        // toggle because `.task(id:)` restarts on each change.
        .task(id: showNextChild) {
            guard showNextChild else { return }
            try? await Task.sleep(for: .seconds(nextChildRevealSeconds))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { showNextChild = false }
        }
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
    //
    // Gated at the DECLARATION, not merely where `body` uses it: a
    // gated call site leaves the declaration compiling, and
    // `worldButton(for:)` references `.fortschritte`, which does not
    // exist in a study build.
    #if !STUDY_BUILD

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
                        .foregroundStyle(isActive ? Color.paper : accent)
                    Text(world.label)
                        .font(.display(10, weight: .semibold))
                        .foregroundStyle(isActive ? Color.paper : accent)
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

    #endif

    private func starBadge(count: Int) -> some View {
        Text(badgeText(for: count))
            .font(.body(FontSize.xs, weight: .bold))
            .foregroundStyle(Color.paper)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(Color.star, in: Capsule())
            .overlay(Capsule().stroke(Color.paper, lineWidth: 1))
            .accessibilityLabel("\(count) Sterne")
    }

    private func badgeText(for n: Int) -> String {
        n > 99 ? "99+" : "\(n)"
    }

    /// Sum of quality-gated star counts across letters. Delegates to
    /// `LetterStars.total`, the same call `SchuleWorldView`'s badge makes —
    /// the two were separate copies of this expression, each with a comment
    /// claiming agreement, and nothing enforced it (audit 2026-09-20).
    private var starTotal: Int {
        LetterStars.total(for: vm.allProgress)
    }

    // MARK: - Gear long-press

    @ViewBuilder
    private var gearButton: some View {
        ZStack {
            Circle()
                .stroke(Color.paperEdge, lineWidth: 2)
                .frame(width: 44, height: 44)
            Circle()
                .trim(from: 0, to: gearHoldProgress)
                .stroke(Color.brand, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: 44, height: 44)
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.1), value: gearHoldProgress)
            Image(systemName: "gear")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.inkSoft)
        }
        // 44×44 visible ring + 4 pt invisible padding = 48 pt hit
        // area (iOS HIG primary-nav minimum).
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
