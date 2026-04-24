// ParentAreaView.swift
// BuchstabenNative
//
// Parental gate destination. Step 5 wires in Dashboard / Settings /
// Export behind a NavigationSplitView; this stub exists so the Step-1
// navigation commit compiles and the long-press gear has a place to land.

import SwiftUI

struct ParentAreaView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(TracingViewModel.self) private var vm

    var body: some View {
        NavigationStack {
            ParentDashboardView()
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Zurück zur App") { dismiss() }
                    }
                }
        }
    }
}
