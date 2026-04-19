import SwiftUI

struct SettingsView: View {
    @Environment(TracingViewModel.self) private var vm
    @State private var selectedSchriftArt: SchriftArt = .druckschrift
    @State private var selectedOrdering: LetterOrderingStrategy = .motorSimilarity
    @State private var thesisEnrolled: Bool = ParticipantStore.isEnrolled

    private static let defaultsKey = "de.flamingistan.buchstaben.selectedSchriftArt"
    private static let orderingDefaultsKey = "de.flamingistan.buchstaben.letterOrdering"

    var body: some View {
        Form {
            Section("Schriftart") {
                ForEach(SchriftArt.allCases.filter { $0 == .druckschrift || $0 == .schulschrift1995 }, id: \.self) { art in
                    schriftArtRow(art)
                }
            }
            Section("Buchstabenreihenfolge") {
                ForEach(LetterOrderingStrategy.allCases, id: \.self) { strategy in
                    orderingRow(strategy)
                }
            }
            Section("Forschung") {
                Toggle("Papier-Übertragung", isOn: Binding(
                    get: { vm.enablePaperTransfer },
                    set: { vm.enablePaperTransfer = $0 }
                ))
                .accessibilityHint("Nach dem freien Schreiben wird eine Aufgabe zum Schreiben auf Papier angezeigt")

                Toggle("Studienteilnahme (A/B-Arm)", isOn: Binding(
                    get: { thesisEnrolled },
                    set: {
                        thesisEnrolled = $0
                        ParticipantStore.isEnrolled = $0
                    }
                ))
                .accessibilityHint("Nur für Forschung aktivieren. Weist das Gerät stabil einer Studienbedingung zu; andernfalls erhält jedes Kind die volle Vier-Phasen-Lernabfolge. Änderung wird beim nächsten App-Start wirksam.")
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
            thesisEnrolled = ParticipantStore.isEnrolled
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
