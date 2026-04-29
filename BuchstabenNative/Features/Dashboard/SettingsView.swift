import SwiftUI

struct SettingsView: View {
    @Environment(TracingViewModel.self) private var vm
    @State private var selectedSchriftArt: SchriftArt = .druckschrift
    @State private var selectedOrdering: LetterOrderingStrategy = .motorSimilarity
    @State private var thesisEnrolled: Bool = ParticipantStore.isEnrolled
    @State private var conditionOverride: ThesisCondition? = ParticipantStore.conditionOverride
    @State private var speechRate: Float = {
        let stored = UserDefaults.standard.float(forKey: "de.flamingistan.buchstaben.speechRate")
        return stored > 0 ? stored : 0.42
    }()
    @State private var useShortOnboarding: Bool = UserDefaults.standard.bool(
        forKey: "de.flamingistan.buchstaben.useShortOnboarding"
    )
    /// Primae appearance override — "system" (follow iOS), "light",
    /// or "dark". Applied at the app root via `.preferredColorScheme`.
    /// Persisted under `primaeAppearance` per the design-system spec.
    @AppStorage("primaeAppearance") private var appearance: String = "system"

    private static let defaultsKey = "de.flamingistan.buchstaben.selectedSchriftArt"
    private static let orderingDefaultsKey = "de.flamingistan.buchstaben.letterOrdering"
    fileprivate static let speechRateKey = "de.flamingistan.buchstaben.speechRate"
    fileprivate static let shortOnboardingKey = "de.flamingistan.buchstaben.useShortOnboarding"

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
            Section("Schreibrichtung") {
                // P5 (ROADMAP): reverse the direct-phase tap order so
                // the child taps the LAST stroke first. Niche; off by
                // default. Useful for motor-planning special-needs
                // students (Spooner 2014). Affects only the direct
                // phase — guided + freeWrite always run canonical order.
                Toggle("Letzten Strich zuerst", isOn: Binding(
                    get: { vm.enableBackwardChaining },
                    set: { vm.enableBackwardChaining = $0 }
                ))
                .accessibilityHint("Vertauscht die Reihenfolge der Punkte in der Richtung-lernen-Phase: zuerst der letzte Strich, dann rückwärts. Hilft bei Schwierigkeiten mit der Bewegungsplanung.")
                Text("Direkt-Phase nur. Bei Bewegungsplanungs-Schwierigkeiten (z. B. motorische Förderung) aktivieren.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Erinnerungstest") {
                // P1 (ROADMAP): opt-in spaced-retrieval prompt before
                // every Nth letter selection. Roediger & Karpicke 2006 —
                // retrieval-practice effect. Default off; research feature.
                Toggle("Erinnerungstest aktivieren", isOn: Binding(
                    get: { vm.enableRetrievalPrompts },
                    set: { vm.enableRetrievalPrompts = $0 }
                ))
                .accessibilityHint("Vor manchen Buchstaben fragt die App, welcher Buchstabe gehört wurde, mit drei Antwortmöglichkeiten. Stärkt das Gedächtnis.")
                Text("Vor jedem dritten Buchstaben fragt die App: Welcher Buchstabe? Drei Wahlknöpfe. Stärkt das Langzeitgedächtnis (Roediger & Karpicke 2006).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Lautwert") {
                // P6 (ROADMAP_V5): opt-in phoneme playback. When on,
                // the audio gesture (tap, replay, two-finger swipe) plays
                // the *sound* the letter makes (/a/ as in *Affe*) rather
                // than its name (/aː/). Falls back to the name set for
                // letters without phoneme recordings, so the toggle never
                // produces silence.
                Toggle("Lautwert wiedergeben", isOn: Binding(
                    get: { vm.enablePhonemeMode },
                    set: { vm.enablePhonemeMode = $0 }
                ))
                .accessibilityHint("Spielt den Lautwert (z. B. /a/ wie in Affe) statt des Buchstabennamens (z. B. \"Aaa\"). Hilfreich für die phonologische Bewusstheit.")
                Text("Spielt den Laut (/a/ wie in Affe) statt des Namens (/aː/). Phonologische Bewusstheit nach Adams 1990.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Sprache") {
                // U8 (ROADMAP_V5): three-position rate picker so a parent
                // can slow the TTS for younger / less verbal children.
                // Persisted in UserDefaults; applied to vm.speech on
                // every appear and on change.
                Picker("Sprechgeschwindigkeit", selection: Binding(
                    get: { speechRate },
                    set: { newValue in
                        speechRate = newValue
                        UserDefaults.standard.set(newValue, forKey: Self.speechRateKey)
                        vm.speech.setRate(newValue)
                    })) {
                    Text("Langsam").tag(Float(0.36))
                    Text("Normal").tag(Float(0.42))
                    Text("Schnell").tag(Float(0.50))
                }
                .accessibilityHint("Wie schnell die App spricht. Für jüngere Kinder \"Langsam\" wählen.")
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
            Section("Erscheinungsbild") {
                // Part C: manual appearance override. "System" follows
                // the iOS Settings → Display & Brightness toggle;
                // "Hell" / "Dunkel" lock the app regardless. Persisted
                // under `primaeAppearance` and applied at the root via
                // `.preferredColorScheme(...)` in `BuchstabenAppMain`.
                Picker("Erscheinungsbild", selection: $appearance) {
                    Text("System").tag("system")
                    Text("Hell").tag("light")
                    Text("Dunkel").tag("dark")
                }
                .accessibilityHint("Erzwingt hellen oder dunklen Modus, oder folgt der iOS-Einstellung.")
                Text("Folgt iOS, wenn auf System gestellt.")
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
                // U4 (ROADMAP): A/B onboarding length. Default off (full
                // 7-step flow). When on, "Einführung wiederholen"
                // restarts with the compressed 3-step variant. The
                // first-run variant is locked into OnboardingStore on
                // initial completion so post-hoc CSV analysis can
                // correlate engagement metrics with the variant the
                // child actually saw, regardless of later parent toggles.
                Toggle("Kurze Einführung", isOn: Binding(
                    get: { useShortOnboarding },
                    set: { newValue in
                        useShortOnboarding = newValue
                        UserDefaults.standard.set(newValue, forKey: Self.shortOnboardingKey)
                    }
                ))
                .accessibilityHint("Aktiviert: 3-Schritte-Einführung statt 7. Wirksam ab dem nächsten App-Start oder über \"Einführung wiederholen\".")
                Text("3 Schritte statt 7 (Begrüßung, Demo, Los geht's). Wirksam beim nächsten Start oder nach \"Einführung wiederholen\".")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            let storedRate = UserDefaults.standard.float(forKey: Self.speechRateKey)
            speechRate = storedRate > 0 ? storedRate : 0.42
            vm.speech.setRate(speechRate)
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
