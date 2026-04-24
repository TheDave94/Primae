// MainAppView.swift
// BuchstabenNative
//
// Root view of the redesigned UI. Hosts the persistent WorldSwitcherRail
// on the left and swaps the right-hand content between the three worlds
// based on `activeWorld`. Settings + research features are behind the
// gear long-press (presented as a fullScreenCover).

import SwiftUI

public struct MainAppView: View {
    @Environment(TracingViewModel.self) private var vm
    @State private var activeWorld: AppWorld = .schule
    @State private var showParentArea = false

    public init() {}

    public var body: some View {
        // Onboarding still owns the full screen on first run. No rail
        // until the user has reached the main experience.
        if !vm.isOnboardingComplete {
            OnboardingView()
        } else {
            HStack(spacing: 0) {
                WorldSwitcherRail(
                    activeWorld: $activeWorld,
                    showParentArea: $showParentArea
                )
                worldContent
            }
            .ignoresSafeArea()
            .fullScreenCover(isPresented: $showParentArea) {
                ParentAreaView()
                    .environment(vm)
            }
            .onChange(of: activeWorld) { _, newWorld in
                // Leaving Werkstatt → drop freeform so the other worlds
                // see a clean VM state (guided canvas, blank target).
                if newWorld != .werkstatt, vm.writingMode == .freeform {
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
                    activeWorld = .schule
                })
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .opacity
        ))
        .animation(.easeInOut(duration: 0.3), value: activeWorld)
    }
}
