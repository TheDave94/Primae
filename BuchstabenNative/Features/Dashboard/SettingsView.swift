import SwiftUI

struct SettingsView: View {
    @Environment(TracingViewModel.self) private var vm
    @State private var selectedSchriftArt: SchriftArt = .druckschrift
    @State private var selectedOrdering: LetterOrderingStrategy = .motorSimilarity
    @State private var thesisEnrolled: Bool = ParticipantStore.isEnrolled
    @State private var conditionOverride: ThesisCondition? = ParticipantStore.conditionOverride

    private static let defaultsKey = "de.flamingistan.buchstaben.selectedSchriftArt"
    private static let orderingDefaultsKey = "de.flamingistan.buchstaben.letterOrdering"

    var body: some View {
        Form {
            Section("Schriftart") {
                ForEach(SchriftArt.allCases.filter { $0 == .druckschrift || $0 == .schreibschrift }, id: \.self) { art in
                    schriftArtRow(art)
                }
            }
            Section("Buchstabenreihenfolge") {
                ForEach(LetterOrderingStrategy.allCases, id: \.self) { strategy in
                    orderingRow(strategy)
                }
            }
            Section("Freies Schreiben") {
                Toggle("Freies Schreiben erlauben", isOn: Binding(
                    get: { vm.enableFreeformMode },
                    set: { vm.enableFreeformMode = $0 }
                ))
                .accessibilityHint("Zeigt einen zusätzlichen Modus, in dem das Kind auf einem leeren Blatt schreiben und die KI den Buchstaben erkennen kann")
            }
            Section("Anzeige") {
                Toggle("Geisterbuchstabe anzeigen", isOn: Binding(
                    get: { vm.showGhost },
                    set: { vm.showGhost = $0 }
                ))
                .accessibilityHint("Zeigt einen halbtransparenten Buchstaben während des Nachfahrens")
                Text("Zeigt einen halbtransparenten Buchstaben während des Nachfahrens.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Forschung") {
                Toggle("Schreiben auf Papier", isOn: Binding(
                    get: { vm.enablePaperTransfer },
                    set: { vm.enablePaperTransfer = $0 }
                ))
                .accessibilityHint("Nach dem freien Schreiben wird das Kind gebeten, den Buchstaben auf Papier zu schreiben")

                Toggle("Studienteilnahme (A/B-Arm)", isOn: Binding(
                    get: { thesisEnrolled },
                    set: {
                        thesisEnrolled = $0
                        ParticipantStore.isEnrolled = $0
                    }
                ))
                .accessibilityHint("Nur für Forschung aktivieren. Weist das Gerät stabil einer Studienbedingung zu; andernfalls erhält jedes Kind die volle Vier-Phasen-Lernabfolge. Änderung wird beim nächsten App-Start wirksam.")
                Text("Änderung wird beim nächsten App-Start wirksam.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if thesisEnrolled {
                    // T6 (ROADMAP_V5): manual researcher override so small
                    // cohorts can be exactly balanced (e.g. 8/8/8 instead
                    // of the byte-modulo's ~uniform-in-expectation
                    // imbalance for n < 30). "Automatisch" leaves the
                    // assignment to ThesisCondition.assign(participantId:).
                    Picker("Studienarm überschreiben",
                           selection: Binding(
                            get: { conditionOverride },
                            set: {
                                conditionOverride = $0
                                ParticipantStore.conditionOverride = $0
                            })) {
                        Text("Automatisch").tag(ThesisCondition?.none)
                        ForEach(ThesisCondition.allCases, id: \.self) { arm in
                            Text(arm.displayName).tag(ThesisCondition?.some(arm))
                        }
                    }
                    .accessibilityHint("Nur für Studienleitung. Ordnet das Gerät einer bestimmten Studienbedingung zu, anstatt die automatische Zuweisung zu verwenden — für ausgewogene Stichproben.")
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
            thesisEnrolled = ParticipantStore.isEnrolled
            conditionOverride = ParticipantStore.conditionOverride
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
