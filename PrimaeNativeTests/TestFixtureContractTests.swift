// TestFixtureContractTests.swift
// PrimaeNativeTests
//
// The shared test fixture's own contract.
//
// `TracingDependencies.stub` is the base for nearly every VM-building test
// in the suite, which makes its defaults load-bearing far from where they
// are written. Twice now a property of that fixture has been depended on
// without being asserted:
//
//   1. `studyMode` was left unpinned while the three sibling assignment
//      axes were pinned deliberately. When B2 changed the default to
//      resolve ON in a study build, three haptic tests began failing in the
//      study binary only — and the comments on the three pins, which
//      explained exactly this hazard, did not prevent the fourth being
//      missed. A comment is not a mechanism; these tests are.
//
//   2. The stub letter "A" happens to be inside the stub's trained subset
//      "AFI", so a studyMode practice pool built from the fixture is
//      non-empty. Nothing asserted that, and nothing named it as a
//      requirement — it was a coincidence holding up every test that opts
//      into studyMode.
//
// Both are cheap to state and expensive to rediscover.

import Testing
import Foundation
@testable import PrimaeNative

@Suite @MainActor struct TestFixtureContractTests {

    /// The fixture must not inherit `studyMode` from the build it was
    /// compiled into.
    ///
    /// `StudyBuild.resolveStudyMode()` — the production default — returns
    /// true in a study build (B2). If `.stub` did not pin the value, the
    /// same test source would exercise the study path in one binary and the
    /// normal path in the other, and the suite would quietly stop testing
    /// what it reads as testing. Tests that mean to exercise studyMode opt
    /// in per-call with `.with(studyMode:)`.
    @Test("the shared fixture pins studyMode rather than resolving it")
    func stubPinsStudyMode() {
        #expect(TracingDependencies.stub.studyMode == false,
                "TracingDependencies.stub must pin studyMode explicitly — an unpinned fixture resolves it from the build and makes the suite build-dependent")
    }

    /// The stub letter must survive the studyMode practice-pool filter.
    ///
    /// Under studyMode `visibleLetterNames` narrows to
    /// `studyBaseLetters ∩ trainedSubset.letters ∩ uppercase`. The fixture
    /// satisfies that only because its single letter is "A" and its pinned
    /// subset is `allSubsets[0]` == "AFI". Change either — a different stub
    /// letter, or a different pinned subset — and the intersection empties.
    ///
    /// What that breaks is every test that opts INTO studyMode:
    /// `StudyLetterSetTests`, `StudyCleanConfigTests`,
    /// `AudioArmRoutingTests`' studyMode cases, and
    /// `TracingViewModelHapticTests.studyMode_firesNoHaptics`. They would
    /// not fail on their own subject matter; they would fail on empty
    /// letter names and zero progress, which reads as a tracing or scoring
    /// regression rather than a fixture edit. This test converts that into
    /// one named failure that says which half of the intersection moved.
    ///
    /// (Before `.stub` pinned studyMode this was far wider — it would also
    /// have taken out the six files that never mention studyMode at all.
    /// The pin closed that; this closes the remainder.)
    @Test("the stub letter stays inside the stub's trained subset")
    func stubLetterSurvivesTheStudyModeFilter() {
        let subset = TracingDependencies.stub.trainedSubset
        let normal = TracingViewModel(.stub.with(studyMode: false)).visibleLetterNames
        let study  = TracingViewModel(.stub.with(studyMode: true)).visibleLetterNames

        #expect(!normal.isEmpty,
                "the stub repo supplies no letters at all — this is a fixture problem upstream of studyMode")

        let trained = normal.filter { subset.letters.contains($0.uppercased()) }
        #expect(!trained.isEmpty,
                "no stub letter is in the pinned trained subset \(subset.rawValue) — the fixture's letter and its subset have drifted apart")

        #expect(!study.isEmpty,
                "the studyMode practice pool built from .stub is EMPTY (letters: \(normal), subset: \(subset.rawValue)) — every test that opts into studyMode will now fail on empty letter names rather than on its own subject")
    }

    /// Every comparison switch a parallel test might write must be PINNED in
    /// the fixture, never inherited from the process-global it also lives in.
    ///
    /// This is the third instance of the pattern the two tests above name, and
    /// the first one to cost a red suite rather than merely invite one. The
    /// switches live in `UserDefaults.standard`; Swift Testing runs tests in
    /// PARALLEL; so a switch held inside one test's body is read by every
    /// fixture constructed concurrently, in any file. MEASURED 2026-10-16:
    /// `StudyComparisonSwitchesTests` held `observePasses = 2` while
    /// `AuditThirdPassTests` built its fixture, that fixture needed two passes,
    /// and *"one full pass must end observe"* failed on a suite that never
    /// mentioned the switch. The view model read that one setting straight from
    /// the global — the last such read — and `stub` did not pin it.
    ///
    /// The test writes the globals, because that is the only way to tell a pin
    /// from an inheritance; it snapshots and restores the exact values rather
    /// than calling `resetToDefaults()`, which would clear keys a parallel test
    /// may be holding. Adding a switch to the fixture's pinned set should add
    /// it here too.
    @Test("the shared fixture pins the comparison switches against their globals")
    func stubPinsTheComparisonSwitches() {
        let saved = (
            cycleAllConditions:  StudyComparisonSettings.cycleAllConditions,
            oncePerCondition:    StudyComparisonSettings.oncePerCondition,
            spacing:             StudyComparisonSettings.presentationSpacingSeconds,
            observePasses:       StudyComparisonSettings.observePasses,
            radiusFactor:        StudyComparisonSettings.soundGateRadiusFactor,
            velocityFloor:       StudyComparisonSettings.soundGateVelocityFloor
        )
        defer {
            StudyComparisonSettings.cycleAllConditions = saved.cycleAllConditions
            StudyComparisonSettings.oncePerCondition = saved.oncePerCondition
            StudyComparisonSettings.presentationSpacingSeconds = saved.spacing
            StudyComparisonSettings.observePasses = saved.observePasses
            StudyComparisonSettings.soundGateRadiusFactor = saved.radiusFactor
            StudyComparisonSettings.soundGateVelocityFloor = saved.velocityFloor
        }

        // Every value non-default, so an inherited one would be visibly wrong.
        StudyComparisonSettings.cycleAllConditions = true
        StudyComparisonSettings.oncePerCondition = true
        StudyComparisonSettings.presentationSpacingSeconds = 5
        StudyComparisonSettings.observePasses = 2
        StudyComparisonSettings.soundGateRadiusFactor = 6.0
        StudyComparisonSettings.soundGateVelocityFloor = 22

        let deps = TracingDependencies.stub
        #expect(deps.cycleAllConditions == StudyComparisonSettings.cycleAllConditionsDefault,
                "the fixture inherited cycleAllConditions from the global")
        #expect(deps.oncePerCondition == StudyComparisonSettings.oncePerConditionDefault,
                "the fixture inherited oncePerCondition from the global")
        #expect(deps.presentationSpacingSeconds == StudyComparisonSettings.presentationSpacingSecondsDefault,
                "the fixture inherited presentationSpacingSeconds from the global — an observe window would stretch while another test holds a non-zero value")
        #expect(deps.observePasses == StudyComparisonSettings.observePassesDefault,
                "the fixture inherited observePasses from the global — a parallel test would hand it whichever pass count it was holding, and an observe-exit assertion would fail on a suite that never set it")
        #expect(deps.soundGateRadiusFactor == StudyComparisonSettings.soundGateRadiusFactorDefault,
                "the fixture inherited soundGateRadiusFactor from the global")
        #expect(deps.soundGateVelocityFloor == StudyComparisonSettings.soundGateVelocityFloorDefault,
                "the fixture inherited soundGateVelocityFloor from the global")
    }
}
