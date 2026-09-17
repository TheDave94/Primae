import SwiftUI

struct SettingsView: View {
    @Environment(TracingViewModel.self) private var vm
    @State private var selectedSchriftArt: SchriftArt = .druckschrift
    @State private var selectedOrdering: LetterOrderingStrategy = .motorSimilarity
    @State private var thesisEnrolled: Bool = ParticipantStore.isEnrolled
    @State private var conditionOverride: ThesisCondition? = ParticipantStore.conditionOverride
    @State private var audioConditionOverride: PilotAudioCondition? = ParticipantStore.audioConditionOverride
    @State private var trainedSubsetOverride: TrainedLetterSubset? = ParticipantStore.trainedSubsetOverride
    // Comparison switches for the questions a supervisor left open on
    // 2026-09-17 (see `StudyComparisonSettings`). Held as `@State` and
    // written through, matching the pickers above rather than reading
    // UserDefaults from the body. Every default is the current
    // behaviour, so an untouched device is unchanged.
    @State private var comparisonObservePasses: Int = StudyComparisonSettings.observePasses
    @State private var comparisonSpokenFeedback: Bool = StudyComparisonSettings.spokenFeedbackInStudy
    @State private var comparisonAllFiveLetters: Bool = StudyComparisonSettings.allFiveLetters
    @State private var comparisonLetterRepeatCount: Int = StudyComparisonSettings.letterRepeatCount
    @State private var comparisonCycleAllConditions: Bool = StudyComparisonSettings.cycleAllConditions
    @State private var comparisonPresentationSpacing: Double = StudyComparisonSettings.presentationSpacingSeconds
    @State private var comparisonGuidedDotsVisible: Bool = StudyComparisonSettings.guidedDotsVisible
    @State private var comparisonPanning: Bool = StudyComparisonSettings.panningEnabled
    @State private var speechRate: Float = {
        let stored = UserDefaults.standard.float(forKey: "de.flamingistan.primae.speechRate")
        return stored > 0 ? stored : 0.42
    }()
    @State private var useShortOnboarding: Bool = UserDefaults.standard.bool(
        forKey: "de.flamingistan.primae.useShortOnboarding"
    )
    /// "system" / "light" / "dark". Applied at the app root via
    /// `.preferredColorScheme`. Persisted under `primaeAppearance`.
    @AppStorage("primaeAppearance") private var appearance: String = "system"

    private static let defaultsKey = "de.flamingistan.primae.selectedSchriftArt"
    private static let orderingDefaultsKey = "de.flamingistan.primae.letterOrdering"
    fileprivate static let speechRateKey = "de.flamingistan.primae.speechRate"
    fileprivate static let shortOnboardingKey = "de.flamingistan.primae.useShortOnboarding"

    /// Ruling Q1's reasoning applies to enrolment as much as to studyMode:
    /// a study binary must not be switchable into an un-randomised state
    /// (class two, 2026-09-05); enrolment happens through "Neuer
    /// Teilnehmer" in the research area. Kept out of the Form's builder
    /// so the `#if` does not break its type inference (CI run 1652).
    @ViewBuilder
    private var enrolmentControl: some View {
        #if STUDY_BUILD
        Label("Studienteilnahme: durch die Studien-Version festgelegt", systemImage: "lock.fill")
            .foregroundStyle(Color.inkSoft)
        #else
        Toggle("Studienteilnahme (A/B-Arm)", isOn: Binding(
            get: { thesisEnrolled },
            set: {
                thesisEnrolled = $0
                ParticipantStore.isEnrolled = $0
            }
        ))
        #endif
    }

    var body: some View {
        // `@Bindable` is Observation's purpose-built projection for an
        // @Observable reference type: `$vm.x` yields the same Binding the
        // hand-written get/set pairs below used to build by hand. Only
        // the identity pass-throughs are converted — the bindings with
        // side effects stay explicit, because hiding a UserDefaults write
        // or a two-property update behind `$` would make them harder to
        // find, not easier.
        @Bindable var vm = vm
        return Form {
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
                Toggle("Freies Schreiben erlauben", isOn: $vm.enableFreeformMode)
                .accessibilityHint("Zeigt einen zusätzlichen Modus, in dem das Kind auf einem leeren Blatt schreiben und die KI den Buchstaben erkennen kann")
            }
            Section("Schreibrichtung") {
                // Backward chaining for direct phase only: taps the
                // last stroke first (Spooner 2014). Off by default.
                Toggle("Letzten Strich zuerst", isOn: $vm.enableBackwardChaining)
                .accessibilityHint("Vertauscht die Reihenfolge der Punkte in der Richtung-lernen-Phase: zuerst der letzte Strich, dann rückwärts. Hilft bei Schwierigkeiten mit der Bewegungsplanung.")
                Text("Direkt-Phase nur. Bei Bewegungsplanungs-Schwierigkeiten (z. B. motorische Förderung) aktivieren.")
                    .font(.caption)
                    .foregroundStyle(Color.inkSoft)
            }
            Section("Erinnerungstest") {
                // Spaced-retrieval prompt every Nth letter selection
                // (Roediger & Karpicke 2006). Default off.
                Toggle("Erinnerungstest aktivieren", isOn: $vm.enableRetrievalPrompts)
                .accessibilityHint("Vor manchen Buchstaben fragt die App, welcher Buchstabe gehört wurde, mit drei Antwortmöglichkeiten. Stärkt das Gedächtnis.")
                Text("Vor jedem dritten Buchstaben fragt die App: Welcher Buchstabe? Drei Wahlknöpfe. Stärkt das Langzeitgedächtnis (Roediger & Karpicke 2006).")
                    .font(.caption)
                    .foregroundStyle(Color.inkSoft)
            }
            Section("Lautwert") {
                // Phoneme playback: plays the letter's sound (/a/)
                // instead of its name (/aː/). Falls back to the name
                // set when no phoneme recording exists, so the toggle
                // never produces silence.
                Toggle("Lautwert wiedergeben", isOn: $vm.enablePhonemeMode)
                .accessibilityHint("Spielt den Lautwert (z. B. /a/ wie in Affe) statt des Buchstabennamens (z. B. \"Aaa\"). Hilfreich für die phonologische Bewusstheit.")
                Text("Spielt den Laut (/a/ wie in Affe) statt des Namens (/aː/). Phonologische Bewusstheit nach Adams 1990.")
                    .font(.caption)
                    .foregroundStyle(Color.inkSoft)
            }
            Section("Sprache") {
                // Three-position TTS rate. Persisted; applied to
                // `vm.speech` on every appear and on change.
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
                Toggle("Geisterbuchstabe anzeigen", isOn: $vm.showGhost)
                .accessibilityHint("Zeigt einen halbtransparenten Buchstaben während des Nachfahrens")
                Text("Zeigt einen halbtransparenten Buchstaben während des Nachfahrens.")
                    .font(.caption)
                    .foregroundStyle(Color.inkSoft)
            }
            Section("Erscheinungsbild") {
                // "System" follows iOS; "Hell" / "Dunkel" lock the
                // app. Applied at the root via `.preferredColorScheme`.
                Picker("Erscheinungsbild", selection: $appearance) {
                    Text("System").tag("system")
                    Text("Hell").tag("light")
                    Text("Dunkel").tag("dark")
                }
                .accessibilityHint("Erzwingt hellen oder dunklen Modus, oder folgt der iOS-Einstellung.")
                Text("Folgt iOS, wenn auf System gestellt.")
                    .font(.caption)
                    .foregroundStyle(Color.inkSoft)
            }
            Section("Forschung") {
                Toggle("Schreiben auf Papier", isOn: $vm.enablePaperTransfer)
                .accessibilityHint("Nach dem freien Schreiben wird das Kind gebeten, den Buchstaben auf Papier zu schreiben")

                enrolmentControl
                .accessibilityHint("Nur für Forschung aktivieren. Weist das Gerät stabil einer Studienbedingung zu; andernfalls erhält jedes Kind die volle Vier-Phasen-Lernabfolge. Änderung wird beim nächsten App-Start wirksam.")
                Text("Änderung wird beim nächsten App-Start wirksam.")
                    .font(.caption)
                    .foregroundStyle(Color.inkSoft)
                if thesisEnrolled {
                    // Researcher override for exact small-cohort
                    // balancing (e.g. 8/8/8). "Automatisch" defers to
                    // `ThesisCondition.assign(participantId:)`.
                    Picker("Studienarm überschreiben",
                           selection: Binding(
                            get: { conditionOverride },
                            set: {
                                conditionOverride = $0
                                ParticipantStore.conditionOverride = $0
                                vm.markAssignmentOverrideChanged()
                            })) {
                        Text("Automatisch").tag(ThesisCondition?.none)
                        ForEach(ThesisCondition.allCases, id: \.self) { arm in
                            Text(arm.displayName).tag(ThesisCondition?.some(arm))
                        }
                    }
                    .accessibilityHint("Nur für Studienleitung. Ordnet das Gerät einer bestimmten Studienbedingung zu, anstatt die automatische Zuweisung zu verwenden — für ausgewogene Stichproben.")

                    // Same researcher-override pattern for the AUDIO axis
                    // (phoneme / spatial / silent) — the two axes are
                    // independent (`ParticipantStore` keeps separate keys).
                    Picker("Audio-Arm überschreiben",
                           selection: Binding(
                            get: { audioConditionOverride },
                            set: {
                                audioConditionOverride = $0
                                ParticipantStore.audioConditionOverride = $0
                                vm.markAssignmentOverrideChanged()
                            })) {
                        Text("Automatisch").tag(PilotAudioCondition?.none)
                        ForEach(PilotAudioCondition.allCases, id: \.self) { arm in
                            Text(arm.displayName).tag(PilotAudioCondition?.some(arm))
                        }
                    }
                    .accessibilityHint("Nur für Studienleitung. Ordnet das Gerät einem bestimmten Audio-Arm zu (Phonem, Raumklang oder Ohne Ton), anstatt die automatische Zuweisung zu verwenden. Änderung wird beim nächsten App-Start wirksam.")

                    // Third axis: which 3 of the 5 study letters this
                    // participant trains. Same override pattern; the
                    // post-test covers all 5 regardless.
                    Picker("Trainierte Buchstaben überschreiben",
                           selection: Binding(
                            get: { trainedSubsetOverride },
                            set: {
                                trainedSubsetOverride = $0
                                ParticipantStore.trainedSubsetOverride = $0
                                vm.markAssignmentOverrideChanged()
                            })) {
                        Text("Automatisch").tag(TrainedLetterSubset?.none)
                        ForEach(TrainedLetterSubset.allSubsets, id: \.self) { subset in
                            Text(subset.displayName).tag(TrainedLetterSubset?.some(subset))
                        }
                    }
                    .accessibilityHint("Nur für Studienleitung. Legt fest, welche 3 der 5 Studienbuchstaben dieses Kind übt, anstatt die automatische Zuweisung zu verwenden — für ausgewogenes Counterbalancing. Änderung wird beim nächsten App-Start wirksam.")
                }

                // COMPARISON MODE (2026-09-17). Each row is one question a
                // supervisor left open rather than a decision, and each
                // switch puts BOTH options within reach so they can be
                // compared on the device. Defaults are the current
                // behaviour in every case; nothing here changes anything
                // until it is touched.
                //
                // A session run with any of these off-default is a
                // COMPARISON run, not pilot data: rows record the session
                // as normal but the configuration they were produced
                // under is not the pre-specified one. The footer says so.
                Section("Vergleichsmodus (Studienleitung)") {
                    Picker("Vorzeigen", selection: Binding(
                        get: { comparisonObservePasses },
                        set: {
                            comparisonObservePasses = $0
                            StudyComparisonSettings.observePasses = $0
                            vm.markAssignmentOverrideChanged()
                        })) {
                        Text("Einmal").tag(1)
                        Text("Zweimal").tag(2)
                    }
                    .accessibilityHint("Wie oft die Anschauen-Animation läuft, bevor die Phase weitergeht. Einmal ist die Vorgabe; zweimal stellt das frühere Verhalten wieder her. Der Durchlauf ist in beiden Fällen langsamer als früher.")

                    Toggle("Sprachausgabe im Studienmodus", isOn: Binding(
                        get: { comparisonSpokenFeedback },
                        set: {
                            comparisonSpokenFeedback = $0
                            StudyComparisonSettings.spokenFeedbackInStudy = $0
                            vm.markAssignmentOverrideChanged()
                        }))
                    .accessibilityHint("Aus ist die Vorgabe: die Studie entfernt jede Sprachausgabe. Ein stellt die Sprech-Rückmeldung der normalen App wieder her, damit beide Optionen verglichen werden können.")

                    Toggle("Alle fünf Buchstaben üben", isOn: Binding(
                        get: { comparisonAllFiveLetters },
                        set: {
                            comparisonAllFiveLetters = $0
                            StudyComparisonSettings.allFiveLetters = $0
                            vm.markAssignmentOverrideChanged()
                        }))
                    .accessibilityHint("Aus ist die Vorgabe: das Kind übt 3 der 5 Buchstaben, die anderen 2 bleiben für den Nachtest ungeübt. Ein lässt jedes Kind alle 5 üben — damit entfällt der Vergleich geübt/ungeübt.")

                    Picker("Wiederholungen je Buchstabe", selection: Binding(
                        get: { comparisonLetterRepeatCount },
                        set: {
                            comparisonLetterRepeatCount = $0
                            StudyComparisonSettings.letterRepeatCount = $0
                            vm.markAssignmentOverrideChanged()
                        })) {
                        Text("1").tag(1)
                        Text("2").tag(2)
                        Text("3").tag(3)
                    }
                    .accessibilityHint("Wie oft der komplette Ablauf eines Buchstabens läuft, bevor die Studienleitung weiterschaltet. Nach jeder Wiederholung wird derselbe Buchstabe erneut vorgemacht und nachgefahren; jede Wiederholung wird als eigener Datensatz geschrieben. 1 ist die Vorgabe.")

                    Toggle("Alle Konditionen durchlaufen", isOn: Binding(
                        get: { comparisonCycleAllConditions },
                        set: {
                            comparisonCycleAllConditions = $0
                            StudyComparisonSettings.cycleAllConditions = $0
                            vm.markAssignmentOverrideChanged()
                        }))
                    .disabled(true)
                    .accessibilityHint("Noch nicht wirksam. Ein Wechsel der Audio-Bedingung mitten in der Sitzung verlangt, dass die Arm-Autorität (C3-2: für den stillen Arm darf kein Audiosignal entstehen) nachträglich veränderbar wird. Das ist die Absicherung, auf der die Manipulation beruht — bewusst nicht angefasst.")

                    Toggle("Startpunkte anzeigen (Anschauen/Nachspuren)", isOn: Binding(
                        get: { comparisonGuidedDotsVisible },
                        set: {
                            comparisonGuidedDotsVisible = $0
                            StudyComparisonSettings.guidedDotsVisible = $0
                            vm.markAssignmentOverrideChanged()
                        }))
                    .accessibilityHint("Ein ist die Vorgabe: Anschauen und Nachspuren zeichnen an jedem Strichanfang einen Punkt. Aus zeichnet sie gar nicht mehr. Antippen war dort noch nie möglich — antippbare, nummerierte Punkte gibt es nur in der Richtung-lernen-Phase, und die sind von diesem Schalter nicht betroffen. Der Endpunkt-Ring am Buchstabenende bleibt in beiden Stellungen sichtbar.")

                    Toggle("Panning (Stereo-Ortung)", isOn: Binding(
                        get: { comparisonPanning },
                        set: {
                            comparisonPanning = $0
                            StudyComparisonSettings.panningEnabled = $0
                            vm.markAssignmentOverrideChanged()
                        }))
                    .accessibilityHint("Ein ist die Vorgabe. Aus hält die Stereo-Ortung auf der Mitte, sodass die Sitzung auch über einen Lautsprecher funktioniert — die Anforderung \"Kopfhörer angeschlossen\" entfällt damit. Die Tonhöhen-Achse des Raumklang-Arms bleibt unverändert.")

                    Stepper(value: Binding(
                        get: { comparisonPresentationSpacing },
                        set: {
                            comparisonPresentationSpacing = $0
                            StudyComparisonSettings.presentationSpacingSeconds = $0
                            vm.markAssignmentOverrideChanged()
                        }), in: 0...10, step: 0.5) {
                        Text("Abstand zwischen Buchstaben: \(comparisonPresentationSpacing, specifier: "%.1f") s")
                    }
                    .accessibilityHint("Pause zwischen dem Ende eines Buchstabens und dem Beginn des nächsten. 0 ist die Vorgabe.")

                    Button("Vergleichsmodus zurücksetzen", role: .destructive) {
                        StudyComparisonSettings.resetToDefaults()
                        comparisonObservePasses = StudyComparisonSettings.observePasses
                        comparisonSpokenFeedback = StudyComparisonSettings.spokenFeedbackInStudy
                        comparisonAllFiveLetters = StudyComparisonSettings.allFiveLetters
                        comparisonLetterRepeatCount = StudyComparisonSettings.letterRepeatCount
                        comparisonCycleAllConditions = StudyComparisonSettings.cycleAllConditions
                        comparisonGuidedDotsVisible = StudyComparisonSettings.guidedDotsVisible
                        comparisonPanning = StudyComparisonSettings.panningEnabled
                        comparisonPresentationSpacing = StudyComparisonSettings.presentationSpacingSeconds
                        vm.markAssignmentOverrideChanged()
                    }

                    Text("Diese Schalter ändern die Sitzung, nicht den Studienarm. Eine Sitzung mit einem abweichenden Schalter ist ein Vergleichslauf und keine Pilotdaten. Alle Schalter werden beim Start der App gelesen und gelten für die ganze Sitzung. Wird ein Schalter während einer laufenden Sitzung umgestellt, sperrt die App die Sitzung bis zum Neustart — die Meldung nennt dabei den Studienarm, obwohl nur eine Sitzungseinstellung geändert wurde; gemeint ist immer „bitte App neu starten“.")
                }
            }
            // Hidden on STUDY_BUILD (2026-09-04): the overlay this
            // toggle targets is itself `#if !STUDY_BUILD`-gated out of
            // the study binary (Q2), which made this toggle silently
            // inert there — but `vm.isCalibrating` flipping true still
            // degraded the child-facing tracing canvas (checkpoints,
            // ghost lines, hit-testing all suppress on `isCalibrating`),
            // with no calibration UI ever appearing to undo it. Fixed at
            // the source (`TracingViewModel.isCalibrating` is now
            // compile-time false on STUDY_BUILD too) — hiding the
            // toggle here besides is just honesty: a control that can no
            // longer do anything shouldn't still invite a tap.
            #if !STUDY_BUILD
            Section("Werkzeuge") {
                Toggle("Striche kalibrieren", isOn: Binding(
                    get: { vm.showDebug && vm.showCalibration },
                    set: { newValue in
                        vm.showDebug = newValue
                        vm.showCalibration = newValue
                    }
                ))
                .accessibilityHint("Schaltet die Stricheditor-Einblendung in der Schule-Welt frei. Punkte ziehen, hinzufügen oder löschen, dann \"Speichern\" — die Anpassung gilt nur auf diesem Gerät.")
                Text("Punkte ziehen / hinzufügen / löschen, \"Speichern\" überschreibt die mitgelieferten Striche dieses Buchstabens auf diesem Gerät.")
                    .font(.caption)
                    .foregroundStyle(Color.inkSoft)
            }
            #endif
            Section("Hilfe") {
                // A/B onboarding length. Default off (7-step). The
                // first-run variant is locked into OnboardingStore on
                // initial completion so CSV analysis correlates
                // engagement with the variant actually seen.
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
                    .foregroundStyle(Color.inkSoft)
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
            audioConditionOverride = ParticipantStore.audioConditionOverride
            trainedSubsetOverride = ParticipantStore.trainedSubsetOverride
            let storedRate = UserDefaults.standard.float(forKey: Self.speechRateKey)
            speechRate = storedRate > 0 ? storedRate : 0.42
            vm.speech.setRate(speechRate)
        }
    }

    @ViewBuilder
    private func orderingRow(_ strategy: LetterOrderingStrategy) -> some View {
        Button {
            // Read back what the VM accepted: studyMode snaps the value,
            // and the tick / stored value must not disagree with the
            // stimulus (audit 2026-09-04).
            vm.letterOrdering = strategy
            selectedOrdering = vm.letterOrdering
            UserDefaults.standard.set(vm.letterOrdering.rawValue, forKey: Self.orderingDefaultsKey)
        } label: {
            HStack {
                Text(strategy.displayName)
                    .foregroundStyle(Color.ink)
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
            vm.schriftArt = art
            selectedSchriftArt = vm.schriftArt
            UserDefaults.standard.set(vm.schriftArt.rawValue, forKey: Self.defaultsKey)
        } label: {
            HStack {
                Text(art.displayName)
                    .foregroundStyle(Color.ink)
                Spacer()
                if selectedSchriftArt == art {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
        }
    }
}
