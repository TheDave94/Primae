import SwiftUI

struct SettingsView: View {
    @Environment(TracingViewModel.self) private var vm
    @State private var selectedSchriftArt: SchriftArt = .druckschrift
    @State private var selectedOrdering: LetterOrderingStrategy = .motorSimilarity

    private static let defaultsKey = "de.flamingistan.buchstaben.selectedSchriftArt"
    private static let orderingDefaultsKey = "de.flamingistan.buchstaben.letterOrdering"

    var body: some View {
        Form {
            Section("Schriftart") {
                ForEach(SchriftArt.allCases.filter { $0 == .druckschrift }, id: \.self) { art in
                    schriftArtRow(art)
                }
            }
            Section("Buchstabenreihenfolge") {
                ForEach(LetterOrderingStrategy.allCases, id: \.self) { strategy in
                    orderingRow(strategy)
                }
            }
            Section("Hilfe") {
                Button("Einführung wiederholen") { vm.restartOnboarding() }
                    .accessibilityHint("Startet die Einführung beim nächsten App-Start neu")
            }
        }
        .navigationTitle("Einstellungen")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            selectedSchriftArt = vm.schriftArt
            selectedOrdering = vm.letterOrdering
        }
    }

    @ViewBuilder
    private func orderingRow(_ strategy: LetterOrderingStrategy) -> some View {
        Button {
            selectedOrdering = strategy
            UserDefaults.standard.set(strategy.rawValue, forKey: Self.orderingDefaultsKey)
            vm.letterOrdering = strategy
        } label: {
            HStack {
                Text(strategy.displayName)
                    .foregroundStyle(.primary)
                Spacer()
                if selectedOrdering == strategy {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
        }
    }

    @ViewBuilder
    private func schriftArtRow(_ art: SchriftArt) -> some View {
        // Only Druckschrift is currently shipped — the upstream `ForEach` filter
        // keeps other cases from rendering, so we don't show any "coming soon"
        // copy here. If we add another schriftArt later, re-enable it in the
        // filter and surface availability via a non-disabled presentation.
        Button {
            selectedSchriftArt = art
            UserDefaults.standard.set(art.rawValue, forKey: Self.defaultsKey)
            vm.schriftArt = art
        } label: {
            HStack {
                Text(art.displayName)
                    .foregroundStyle(.primary)
                Spacer()
                if selectedSchriftArt == art {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
        }
    }
}
