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
        defaults.set(configuration.rateCoupling, forKey: S.rateCouplingKey)
        defaults.set(configuration.pitchScope.rawValue, forKey: S.pitchScopeKey)
        defaults.set(configuration.pitchRangeCents, forKey: S.pitchRangeCentsKey)
        defaults.set(configuration.soundGatingEnabled, forKey: S.soundGatingEnabledKey)
        defaults.set(configuration.distanceToneEnabled, forKey: S.distanceToneEnabledKey)
        defaults.set(configuration.directionMuteEnabled, forKey: S.directionMuteEnabledKey)
        defaults.set(configuration.distanceToneFarLevelDB, forKey: S.distanceToneFarLevelDBKey)
        defaults.set(configuration.distanceToneFarCutoffHz, forKey: S.distanceToneFarCutoffHzKey)
        defaults.set(configuration.directionMuteBackwardCosine, forKey: S.directionMuteBackwardCosineKey)
        defaults.set(configuration.pressureLoudnessEnabled, forKey: S.pressureLoudnessEnabledKey)
        defaults.set(configuration.pressureLoudnessRangeDB, forKey: S.pressureLoudnessRangeDBKey)
        defaults.set(configuration.dysfluencyRoughness, forKey: S.dysfluencyRoughnessKey)
        defaults.set(configuration.dysfluencyRoughnessDepth, forKey: S.dysfluencyRoughnessDepthKey)
        defaults.set(configuration.dysfluencyRoughnessRateHz, forKey: S.dysfluencyRoughnessRateHzKey)
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
            oncePerCondition: true,
            rateCoupling: false,
            pitchScope: .both,
            pitchRangeCents: 1200,
            soundGatingEnabled: false,
            distanceToneEnabled: true,
            directionMuteEnabled: true,
            distanceToneFarLevelDB: -18,
            distanceToneFarCutoffHz: 1600,
            directionMuteBackwardCosine: -0.5,
            pressureLoudnessEnabled: true,
            pressureLoudnessRangeDB: 24,
            dysfluencyRoughness: true,
            dysfluencyRoughnessDepth: 0.6,
            dysfluencyRoughnessRateHz: 60
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
        #expect(deps.soundGatingEnabled == written.soundGatingEnabled)
        #expect(deps.observePasses == written.observePasses)
        #expect(deps.soundGateRadiusFactor == written.soundGateRadiusFactor)
        #expect(deps.soundGateVelocityFloor == written.soundGateVelocityFloor)
        #expect(deps.presentationSpacingSeconds == written.presentationSpacingSeconds)
        #expect(deps.guidedDotsVisible == written.guidedDotsVisible)
        #expect(deps.panningEnabled == written.panningEnabled)
        #expect(deps.rateCoupling == written.rateCoupling)
        #expect(deps.pitchCoupling == PitchCoupling(scope: written.pitchScope, spanCents: written.pitchRangeCents))
        #expect(deps.distanceToneEnabled == written.distanceToneEnabled)
        #expect(deps.directionMuteEnabled == written.directionMuteEnabled)
        #expect(deps.distanceToneFarLevelDB == written.distanceToneFarLevelDB)
        #expect(deps.distanceToneFarCutoffHz == written.distanceToneFarCutoffHz)
        #expect(deps.directionMuteBackwardCosine == written.directionMuteBackwardCosine)
        #expect(deps.pressureLoudnessEnabled == written.pressureLoudnessEnabled)
        #expect(deps.pressureLoudnessRangeDB == written.pressureLoudnessRangeDB)
        #expect(deps.dysfluencyRoughness == written.dysfluencyRoughness)
        #expect(deps.dysfluencyRoughnessDepth == written.dysfluencyRoughnessDepth)
        #expect(deps.dysfluencyRoughnessRateHz == written.dysfluencyRoughnessRateHz)
        #expect(deps.spatialAxisDemonstration == written.spatialAxisDemonstration)
    }

    /// The nine switches `deps` resolved, as a configuration (the three
    /// optional seams stay at their defaults — the helper pins them).
    private func nineSwitches(of deps: TracingDependencies) -> StudyComparisonConfiguration {
        var c = StudyComparisonConfiguration.defaults
        c.cycleAllConditions = deps.cycleAllConditions
        c.oncePerCondition = deps.oncePerCondition
        c.soundGatingEnabled = deps.soundGatingEnabled
        c.observePasses = deps.observePasses
        c.soundGateRadiusFactor = deps.soundGateRadiusFactor
        c.soundGateVelocityFloor = deps.soundGateVelocityFloor
        c.presentationSpacingSeconds = deps.presentationSpacingSeconds
        c.guidedDotsVisible = deps.guidedDotsVisible
        c.panningEnabled = deps.panningEnabled
        c.rateCoupling = deps.rateCoupling
        c.pitchScope = deps.pitchCoupling.scope
        c.pitchRangeCents = deps.pitchCoupling.spanCents
        c.distanceToneEnabled = deps.distanceToneEnabled
        c.directionMuteEnabled = deps.directionMuteEnabled
        c.distanceToneFarLevelDB = deps.distanceToneFarLevelDB
        c.distanceToneFarCutoffHz = deps.distanceToneFarCutoffHz
        c.directionMuteBackwardCosine = deps.directionMuteBackwardCosine
        c.pressureLoudnessEnabled = deps.pressureLoudnessEnabled
        c.pressureLoudnessRangeDB = deps.pressureLoudnessRangeDB
        c.dysfluencyRoughness = deps.dysfluencyRoughness
        c.dysfluencyRoughnessDepth = deps.dysfluencyRoughnessDepth
        c.dysfluencyRoughnessRateHz = deps.dysfluencyRoughnessRateHz
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
            ("soundGatingEnabled",        { $0.soundGatingEnabled = away.soundGatingEnabled }),
            ("observePasses",             { $0.observePasses = away.observePasses }),
            ("soundGateRadiusFactor",     { $0.soundGateRadiusFactor = away.soundGateRadiusFactor }),
            ("soundGateVelocityFloor",    { $0.soundGateVelocityFloor = away.soundGateVelocityFloor }),
            ("presentationSpacingSeconds", { $0.presentationSpacingSeconds = away.presentationSpacingSeconds }),
            ("guidedDotsVisible",         { $0.guidedDotsVisible = away.guidedDotsVisible }),
            ("panningEnabled",            { $0.panningEnabled = away.panningEnabled }),
            ("spatialAxisDemonstration",  { $0.spatialAxisDemonstration = away.spatialAxisDemonstration }),
            ("rateCoupling",              { $0.rateCoupling = away.rateCoupling }),
            ("pitchScope",                { $0.pitchScope = away.pitchScope }),
            ("pitchRangeCents",           { $0.pitchRangeCents = away.pitchRangeCents }),
            ("distanceToneEnabled",       { $0.distanceToneEnabled = away.distanceToneEnabled }),
            ("directionMuteEnabled",      { $0.directionMuteEnabled = away.directionMuteEnabled }),
            ("distanceToneFarLevelDB",    { $0.distanceToneFarLevelDB = away.distanceToneFarLevelDB }),
            ("distanceToneFarCutoffHz",   { $0.distanceToneFarCutoffHz = away.distanceToneFarCutoffHz }),
            ("directionMuteBackwardCosine", { $0.directionMuteBackwardCosine = away.directionMuteBackwardCosine }),
            ("pressureLoudnessEnabled",   { $0.pressureLoudnessEnabled = away.pressureLoudnessEnabled }),
            ("pressureLoudnessRangeDB",   { $0.pressureLoudnessRangeDB = away.pressureLoudnessRangeDB }),
            ("dysfluencyRoughness",       { $0.dysfluencyRoughness = away.dysfluencyRoughness }),
            ("dysfluencyRoughnessDepth",  { $0.dysfluencyRoughnessDepth = away.dysfluencyRoughnessDepth }),
            ("dysfluencyRoughnessRateHz", { $0.dysfluencyRoughnessRateHz = away.dysfluencyRoughnessRateHz }),
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
        #expect(deps.soundGatingEnabled == StudyComparisonSettings.soundGatingEnabledDefault)
        #expect(deps.observePasses == StudyComparisonSettings.observePassesDefault)
        #expect(deps.soundGateRadiusFactor == StudyComparisonSettings.soundGateRadiusFactorDefault)
        #expect(deps.soundGateVelocityFloor == StudyComparisonSettings.soundGateVelocityFloorDefault)
        #expect(deps.presentationSpacingSeconds == StudyComparisonSettings.presentationSpacingSecondsDefault)
        #expect(deps.guidedDotsVisible == StudyComparisonSettings.guidedDotsVisibleDefault)
        #expect(deps.panningEnabled == StudyComparisonSettings.panningEnabledDefault)
        #expect(deps.rateCoupling == StudyComparisonSettings.rateCouplingDefault)
        #expect(deps.pitchCoupling == .default)
        #expect(deps.distanceToneEnabled == StudyComparisonSettings.distanceToneEnabledDefault)
        #expect(deps.directionMuteEnabled == StudyComparisonSettings.directionMuteEnabledDefault)
        #expect(deps.distanceToneFarLevelDB == StudyComparisonSettings.distanceToneFarLevelDBDefault)
        #expect(deps.distanceToneFarCutoffHz == StudyComparisonSettings.distanceToneFarCutoffHzDefault)
        #expect(deps.directionMuteBackwardCosine == StudyComparisonSettings.directionMuteBackwardCosineDefault)
        #expect(deps.pressureLoudnessEnabled == StudyComparisonSettings.pressureLoudnessEnabledDefault)
        #expect(deps.pressureLoudnessRangeDB == StudyComparisonSettings.pressureLoudnessRangeDBDefault)
        #expect(deps.dysfluencyRoughness == StudyComparisonSettings.dysfluencyRoughnessDefault)
        #expect(deps.dysfluencyRoughnessDepth == StudyComparisonSettings.dysfluencyRoughnessDepthDefault)
        #expect(deps.dysfluencyRoughnessRateHz == StudyComparisonSettings.dysfluencyRoughnessRateHzDefault)
        #expect(deps.spatialAxisDemonstration == StudyComparisonSettings.spatialAxisDemonstrationDefault)
    }
}
