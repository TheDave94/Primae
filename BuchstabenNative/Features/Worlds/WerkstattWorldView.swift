// WerkstattWorldView.swift
// BuchstabenNative
//
// World 2 — Schreibwerkstatt. Left panel with mode cards + freeform
// canvas. Step 3 implements the full layout; this file exists so the
// Step-1 navigation commit compiles.

import SwiftUI

struct WerkstattWorldView: View {
    @Environment(TracingViewModel.self) private var vm

    var body: some View {
        // Temporary passthrough: while in this world show the existing
        // freeform writing view if the VM is in freeform mode, otherwise
        // auto-enter freeform letter mode so the child never lands in an
        // empty world. Replaced by the mode-card layout in Step 3.
        Group {
            if vm.writingMode == .freeform {
                FreeformWritingView()
            } else {
                Color.white
                    .onAppear { vm.enterFreeformMode(subMode: .letter) }
            }
        }
    }
}
