// ComparisonSeamDefaultsTests.swift
// PrimaeNativeTests
//
// The DEFAULT ARGUMENTS of `TracingDependencies` for the comparison
// switches, and the throwaway store the tests use to reach them.
//
// WHY THIS FILE EXISTS. `TracingDependencies.stub` pins every comparison
// switch explicitly, which is right (a parallel test must never sample a key
// another test is holding) and which also means NO fixture ever evaluates the
// production path: a caller that omits a switch and gets it from the device.
// That omitted-argument path is the only one the app uses, and a wrong
// default there — the wrong key, a hard-coded value, the wrong store —
// ships an inert researcher switch to a study device while the whole suite
// stays green. The tests that used to cover it (`switchesAreCapturedAtInit`,
// `switchesApplyOnNextConstruction`) could not: the first no longer could
// fail, and the second copied the global onto the seam by hand, so a wrong
// default argument still passed.
//
// HOW THEY REACH IT WITHOUT A GLOBAL. `TracingDependencies.comparisonDefaults`
// is the store an omitted switch is read from. It is `.standard` in
// production; a test hands it a `UserDefaults(suiteName:)` that nobody else
// can see, so the real "read the device setting" code runs against values the
// test controls and Swift Testing's parallel suites cannot observe.

import Testing
import Foundation
@testable import PrimaeNative

// MARK: - Throwaway store

/// A uniquely named `UserDefaults` suite, removed when the test lets go of it.
final class ThrowawayDefaults {
    let defaults: UserDefaults
    private let name: String

    init() {
        name = "de.flamingistan.primae.test.comparison.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: name)!
    }

    deinit { defaults.removePersistentDomain(forName: name) }

    /// Stores every switch of `configuration` under its real key.
    func write(_ configuration: StudyComparisonConfiguration) {
        typealias S = StudyComparisonSettings
        defaults.set(configuration.observePasses, forKey: S.observePassesKey)
        defaults.set(configuration.spokenFeedbackInStudy, forKey: S.spokenFeedbackKey)
        defaults.set(configuration.allFiveLetters, forKey: S.allFiveLettersKey)
        defaults.set(configuration.letterRepeatCount, forKey: S.letterRepeatCountKey)
        defaults.set(configuration.cycleAllConditions, forKey: S.cycleAllConditionsKey)
        defaults.set(configuration.presentationSpacingSeconds, forKey: S.presentationSpacingKey)
        defaults.set(configuration.panningEnabled, forKey: S.panningEnabledKey)
        defaults.set(configuration.guidedDotsVisible, forKey: S.guidedDotsVisibleKey)
        defaults.set(configuration.spatialAxisDemonstration, forKey: S.spatialAxisDemonstrationKey)
        defaults.set(configuration.soundGateRadiusFactor, forKey: S.soundGateRadiusFactorKey)
        defaults.set(configuration.soundGateVelocityFloor, forKey: S.soundGateVelocityFloorKey)
        defaults.set(configuration.oncePerCondition, forKey: S.oncePerConditionKey)
    }
}

extension StudyComparisonConfiguration {
    /// Every one of the twelve switches AWAY from its default, so a value that
    /// was inherited, ignored or read from the wrong key is visibly wrong.
    static var everySwitchNonDefault: StudyComparisonConfiguration {
        StudyComparisonConfiguration(
            observePasses: 2,
            spokenFeedbackInStudy: !StudyComparisonSettings.spokenFeedbackInStudyDefault,
            allFiveLetters: true,
            letterRepeatCount: 3,
            cycleAllConditions: true,
            presentationSpacingSeconds: 5,
            panningEnabled: false,
            guidedDotsVisible: false,
            spatialAxisDemonstration: true,
            soundGateRadiusFactor: 6.0,
            soundGateVelocityFloor: 22,
            oncePerCondition: true
        )
    }
}

// MARK: - Dependencies that OMIT the switches

extension TracingDependencies {
    /// A study-mode bundle with the nine non-optional comparison switches
    /// LEFT OUT of the call — so their real default arguments run — reading
    /// them from `comparisonDefaults`. Everything else is the stub's.
    ///
    /// The three optional seams (`allFiveLetters`, `letterRepeatCount`,
    /// `spokenFeedbackInStudy`) are pinned at their defaults, because the
    /// view model resolves those, not this initialiser; the tests that mean
    /// to exercise them say so at the call site.
    ///
    /// Not `.stub`-derived on purpose: `stub` passes every switch, and a
    /// bundle that passes them cannot show what the omitted form does.
    @MainActor
    static func omittingComparisonSwitches(reading comparisonDefaults: UserDefaults) -> TracingDependencies {
        var deps = TracingDependencies(
            audio:                StubAudio(),
            progressStore:        StubProgressStore(),
            haptics:              StubHaptics(),
            repo:                 LetterRepository(resources: StubResourceProvider(),
                                                   cache: NullLetterCache()),
            streakStore:          StubStreakStore(),
            dashboardStore:       StubDashboardStore(),
            rawTraceStore:        StubRawTraceStore(),
            participantArchive:   StubParticipantArchive(),
            enrolmentLog:         StubEnrolmentLog(),
            setCompletion:        StubSetCompletionLedger(),
            onboardingStore:      StubOnboardingStore(),
            thesisCondition:      .guidedOnly,
            audioCondition:       .phoneme,
            trainedSubset:        TrainedLetterSubset.allSubsets[0],
            allFiveLetters:       StudyComparisonSettings.allFiveLettersDefault,
            studyMode:            true,
            spokenFeedbackInStudy: StudyComparisonSettings.spokenFeedbackInStudyDefault,
            comparisonDefaults:   comparisonDefaults,
            participantEnrolled:  true,
            letterRecognizer:     StubLetterRecognizer(),
            speech:               NullSpeechSynthesizer(),
            deliveryEnvironment:  FixedDeliveryEnvironment(),
            launchSentinel:       NullLaunchSentinel(),
            buildStamp:           FixedDeliveryEnvironment.build,
            makePromptPlayer:     { _ in NullPromptPlayer() }
        )
        deps.letterRepeatCount = StudyComparisonSettings.letterRepeatCountDefault
        #if !STUDY_BUILD
        deps.notificationScheduler = LocalNotificationScheduler(center: StubNotificationCenter())
        #endif
        return deps
    }

    /// The same bundle but also OMITTING `comparisonDefaults`, to observe the
    /// default of that parameter itself.
    @MainActor
    static func omittingComparisonSwitchesAndStore() -> TracingDependencies {
        var deps = TracingDependencies(
            audio:                StubAudio(),
            progressStore:        StubProgressStore(),
            haptics:              StubHaptics(),
            repo:                 LetterRepository(resources: StubResourceProvider(),
                                                   cache: NullLetterCache()),
            streakStore:          StubStreakStore(),
            dashboardStore:       StubDashboardStore(),
            rawTraceStore:        StubRawTraceStore(),
            participantArchive:   StubParticipantArchive(),
            enrolmentLog:         StubEnrolmentLog(),
            setCompletion:        StubSetCompletionLedger(),
            onboardingStore:      StubOnboardingStore(),
            thesisCondition:      .guidedOnly,
            audioCondition:       .phoneme,
            trainedSubset:        TrainedLetterSubset.allSubsets[0],
            allFiveLetters:       StudyComparisonSettings.allFiveLettersDefault,
            studyMode:            true,
            spokenFeedbackInStudy: StudyComparisonSettings.spokenFeedbackInStudyDefault,
            participantEnrolled:  true,
            letterRecognizer:     StubLetterRecognizer(),
            speech:               NullSpeechSynthesizer(),
            deliveryEnvironment:  FixedDeliveryEnvironment(),
            launchSentinel:       NullLaunchSentinel(),
            buildStamp:           FixedDeliveryEnvironment.build,
            makePromptPlayer:     { _ in NullPromptPlayer() }
        )
        deps.letterRepeatCount = StudyComparisonSettings.letterRepeatCountDefault
        #if !STUDY_BUILD
        deps.notificationScheduler = LocalNotificationScheduler(center: StubNotificationCenter())
        #endif
        return deps
    }
}

// MARK: - Suite

@Suite @MainActor struct ComparisonSeamDefaultsTests {

    /// Production reads the DEVICE's settings, so the store an omitted switch
    /// is read from must default to the real one. Changing that default to a
    /// private suite would make every researcher switch silently inert on a
    /// study device — and nothing else in the suite would notice, because
    /// every fixture passes its switches explicitly.
    ///
    /// Read-only: it compares an identity and writes no key.
    @Test("the store an omitted switch is read from defaults to the device's own")
    func comparisonDefaultsIsTheDeviceStore() {
        let deps = TracingDependencies.omittingComparisonSwitchesAndStore()
        #expect(deps.comparisonDefaults === UserDefaults.standard,
                "TracingDependencies.comparisonDefaults no longer defaults to UserDefaults.standard — the supervisor's switches would be read from somewhere else and ignored on the device")
    }

    /// An omitted switch must come from the store, not from a literal. Every
    /// one of the nine is checked against a value that is NOT its default.
    @Test("each omitted switch is read from the store under its own key")
    func everyOmittedSwitchComesFromItsOwnKey() {
        let box = ThrowawayDefaults()
        let written = StudyComparisonConfiguration.everySwitchNonDefault
        box.write(written)
        #expect(StudyComparisonSettings.configuration(in: box.defaults) == written,
                "precondition: the throwaway store must hold the non-default values it was given")

        let deps = TracingDependencies.omittingComparisonSwitches(reading: box.defaults)

        #expect(deps.cycleAllConditions == written.cycleAllConditions)
        #expect(deps.oncePerCondition == written.oncePerCondition)
        #expect(deps.observePasses == written.observePasses)
        #expect(deps.soundGateRadiusFactor == written.soundGateRadiusFactor)
        #expect(deps.soundGateVelocityFloor == written.soundGateVelocityFloor)
        #expect(deps.presentationSpacingSeconds == written.presentationSpacingSeconds)
        #expect(deps.guidedDotsVisible == written.guidedDotsVisible)
        #expect(deps.panningEnabled == written.panningEnabled)
        #expect(deps.spatialAxisDemonstration == written.spatialAxisDemonstration)
    }

    /// The nine switches `deps` resolved, as a configuration (the three
    /// optional seams stay at their defaults — the helper pins them).
    private func nineSwitches(of deps: TracingDependencies) -> StudyComparisonConfiguration {
        var c = StudyComparisonConfiguration.defaults
        c.cycleAllConditions = deps.cycleAllConditions
        c.oncePerCondition = deps.oncePerCondition
        c.observePasses = deps.observePasses
        c.soundGateRadiusFactor = deps.soundGateRadiusFactor
        c.soundGateVelocityFloor = deps.soundGateVelocityFloor
        c.presentationSpacingSeconds = deps.presentationSpacingSeconds
        c.guidedDotsVisible = deps.guidedDotsVisible
        c.panningEnabled = deps.panningEnabled
        c.spatialAxisDemonstration = deps.spatialAxisDemonstration
        return c
    }

    /// With every switch away from its default at once, two switches whose
    /// non-default values COINCIDE (panning and the dots are both `false`)
    /// cannot be told apart: a default argument that reads its neighbour's key
    /// passes. So each switch is also moved ALONE, and the whole resolved
    /// configuration must equal what was written — a swapped key shows up as
    /// the wrong field moving. Found by mutation: reading the dots key for
    /// `panningEnabled` passed the all-at-once test above.
    @Test("each omitted switch moves alone, and nothing else moves with it")
    func eachSwitchMovesAlone() {
        let away = StudyComparisonConfiguration.everySwitchNonDefault
        let moves: [(String, (inout StudyComparisonConfiguration) -> Void)] = [
            ("cycleAllConditions",        { $0.cycleAllConditions = away.cycleAllConditions }),
            ("oncePerCondition",          { $0.oncePerCondition = away.oncePerCondition }),
            ("observePasses",             { $0.observePasses = away.observePasses }),
            ("soundGateRadiusFactor",     { $0.soundGateRadiusFactor = away.soundGateRadiusFactor }),
            ("soundGateVelocityFloor",    { $0.soundGateVelocityFloor = away.soundGateVelocityFloor }),
            ("presentationSpacingSeconds", { $0.presentationSpacingSeconds = away.presentationSpacingSeconds }),
            ("guidedDotsVisible",         { $0.guidedDotsVisible = away.guidedDotsVisible }),
            ("panningEnabled",            { $0.panningEnabled = away.panningEnabled }),
            ("spatialAxisDemonstration",  { $0.spatialAxisDemonstration = away.spatialAxisDemonstration }),
        ]
        for (name, move) in moves {
            var written = StudyComparisonConfiguration.defaults
            move(&written)
            #expect(written != StudyComparisonConfiguration.defaults,
                    "precondition: moving \(name) must change the configuration")
            let box = ThrowawayDefaults()
            box.write(written)
            let deps = TracingDependencies.omittingComparisonSwitches(reading: box.defaults)
            #expect(nineSwitches(of: deps) == written,
                    "with only \(name) moved, the resolved configuration differs — \(name) is read from the wrong key, or another switch follows it")
        }
    }

    /// And an empty store must give back exactly the documented defaults — the
    /// property that makes adding a switch safe on an enrolled device.
    @Test("an untouched store gives every omitted switch its documented default")
    func untouchedStoreGivesTheDefaults() {
        let box = ThrowawayDefaults()
        let deps = TracingDependencies.omittingComparisonSwitches(reading: box.defaults)

        #expect(deps.cycleAllConditions == StudyComparisonSettings.cycleAllConditionsDefault)
        #expect(deps.oncePerCondition == StudyComparisonSettings.oncePerConditionDefault)
        #expect(deps.observePasses == StudyComparisonSettings.observePassesDefault)
        #expect(deps.soundGateRadiusFactor == StudyComparisonSettings.soundGateRadiusFactorDefault)
        #expect(deps.soundGateVelocityFloor == StudyComparisonSettings.soundGateVelocityFloorDefault)
        #expect(deps.presentationSpacingSeconds == StudyComparisonSettings.presentationSpacingSecondsDefault)
        #expect(deps.guidedDotsVisible == StudyComparisonSettings.guidedDotsVisibleDefault)
        #expect(deps.panningEnabled == StudyComparisonSettings.panningEnabledDefault)
        #expect(deps.spatialAxisDemonstration == StudyComparisonSettings.spatialAxisDemonstrationDefault)
    }
}
