// MainAppView.swift
// PrimaeNative
//
// Root view of the redesigned UI. Hosts the persistent WorldSwitcherRail
// on the left and swaps the right-hand content between the three worlds
// based on `activeWorld`. Settings + research features are behind the
// gear long-press (presented as a fullScreenCover).

import SwiftUI

public struct MainAppView: View {
    @Environment(TracingViewModel.self) private var vm
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Persisted across launches so the child returns to the world
    /// they were last in. Stored as the AppWorld raw value because
    /// `@AppStorage` only supports plain Codable scalars.
    @AppStorage("de.flamingistan.primae.activeWorld")
    private var activeWorldRaw: String = AppWorld.schule.rawValue
    @State private var showParentArea = false

    public init() {}

    /// Two-way binding around `activeWorldRaw` that decodes and encodes the
    /// AppWorld enum so child views can keep working with the typed value.
    /// Falls back to `.schule` if a future build wrote a value we no
    /// longer recognise.
    private var activeWorldBinding: Binding<AppWorld> {
        Binding(
            get: { AppWorld(rawValue: activeWorldRaw) ?? .schule },
            set: { activeWorldRaw = $0.rawValue }
        )
    }

    private var activeWorld: AppWorld {
        AppWorld(rawValue: activeWorldRaw) ?? .schule
    }

    public var body: some View {
        // Onboarding still owns the full screen on first run. No rail
        // until the user has reached the main experience.
        if !vm.isOnboardingComplete {
            OnboardingView()
        } else {
            HStack(spacing: 0) {
                WorldSwitcherRail(
                    activeWorld: activeWorldBinding,
                    showParentArea: $showParentArea
                )
                worldContent
            }
            .ignoresSafeArea()
            .fullScreenCover(isPresented: $showParentArea) {
                ParentAreaView()
                    .environment(vm)
            }
            .onChange(of: activeWorldRaw) { _, _ in
                // Leaving Werkstatt → drop freeform so the other worlds
                // see a clean VM state (guided canvas, blank target).
                if activeWorld != .werkstatt, vm.writingMode == .freeform {
                    vm.exitFreeformMode()
                }
            }
        }
    }

    @ViewBuilder
    private var worldContent: some View {
        Group {
            switch activeWorld {
            case .schule:
                SchuleWorldView()
            case .werkstatt:
                WerkstattWorldView()
            case .fortschritte:
                FortschritteWorldView(onLetterSelected: { letter in
                    vm.loadLetter(name: letter)
                    activeWorldRaw = AppWorld.schule.rawValue
                })
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .opacity
        ))
        // Respect Reduce Motion: skip the slide-in transition for users
        // who disabled motion. The world still swaps, just without the
        // 300 ms ease — matches the rest of the app's reduceMotion gates.
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: activeWorld)
    }
}
