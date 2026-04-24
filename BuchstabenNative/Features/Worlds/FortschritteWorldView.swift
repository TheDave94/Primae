// FortschritteWorldView.swift
// BuchstabenNative
//
// World 3 — Meine Fortschritte. Child-facing progress view with stars,
// streak, and a letter gallery. Step 4 adds the full layout; this stub
// keeps Step 1's navigation commit compiling.

import SwiftUI

struct FortschritteWorldView: View {
    @Environment(TracingViewModel.self) private var vm
    /// Called when the child taps a letter in the gallery so the host
    /// (MainAppView) can switch to the Schule world with that letter
    /// pre-selected.
    let onLetterSelected: (String) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Meine Fortschritte")
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
                .padding(.top, 32)
            Text("Hier werden deine Sterne und Serien angezeigt.")
                .font(.headline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}
