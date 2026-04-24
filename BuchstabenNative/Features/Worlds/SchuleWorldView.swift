// SchuleWorldView.swift
// BuchstabenNative
//
// World 1 — Buchstaben-Schule. Full-width tracing canvas with a minimal
// HUD: current letter pill in the top-left (long-press to open the
// letter wheel), phase dots with prev/next arrows at the bottom. Wraps
// the existing TracingCanvasView — TracingViewModel, scoring, audio
// and recognition pipelines are unchanged.

import SwiftUI

struct SchuleWorldView: View {
    @Environment(TracingViewModel.self) private var vm

    var body: some View {
        ZStack(alignment: .topLeading) {
            TracingCanvasView()
                .background(Color.white)
                .ignoresSafeArea(edges: [.top, .bottom, .trailing])

            // Placeholder top-left letter pill — Step 2 adds the wheel
            // picker on long-press; for now it shows which letter is
            // active so the initial navigation commit has a visible
            // anchor without breaking existing layout.
            if !vm.currentLetterName.isEmpty {
                Text(vm.currentLetterName)
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 16).padding(.leading, 16)
                    .accessibilityLabel("Aktueller Buchstabe \(vm.currentLetterName)")
            }
        }
    }
}
