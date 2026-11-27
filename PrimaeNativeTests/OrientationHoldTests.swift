// OrientationHoldTests.swift
// Protocol r30 (David's ruling 2026-11-26, "Real fix + turn prompt"): the
// study build no longer sets UIRequiresFullScreen and declares every iPad
// orientation. A landscape scene locks its orientation; a portrait or
// windowed scene holds the session under the turn prompt, which suspends it
// exactly like the other interruptions. These pin the decisions
// (`StudyOrientationGate`) and what a hold does to the session
// (`TracingViewModel.sceneShapeDidChange`).

import Testing
import SwiftUI
@testable import PrimaeNative

@Suite @MainActor struct OrientationHoldTests {

    private var cue: String { ChildSpeechLibrary.phaseEntry(.observe) }

    // MARK: - The decisions

    @Test("the hold for each scene shape: portrait asks to turn, a landscape window waits, a full landscape scene runs")
    func holdForEachShape() {
        #expect(StudyOrientationGate.hold(sceneIsLandscape: true, sceneFillsScreen: true) == .none)
        #expect(StudyOrientationGate.hold(sceneIsLandscape: false, sceneFillsScreen: true) == .turnToLandscape)
        #expect(StudyOrientationGate.hold(sceneIsLandscape: true, sceneFillsScreen: false) == .fillScreen)
        #expect(StudyOrientationGate.hold(sceneIsLandscape: false, sceneFillsScreen: false) == .turnToLandscape,
                "portrait wins: turning the iPad is what the child can do")
    }

    @Test("the lock engages only on a landscape scene, so a portrait launch is never locked in portrait")
    func lockOnlyWhenLandscape() {
        #expect(StudyOrientationGate.locksOrientation(sceneIsLandscape: true))
        #expect(!StudyOrientationGate.locksOrientation(sceneIsLandscape: false))
    }

    @Test("a scene fills the screen in either orientation, and a window does not")
    func fillsTheScreen() {
        let screen = CGSize(width: 1024, height: 1366)   // iPad Pro 12.9", portrait points
        #expect(StudyOrientationGate.fills(sceneSize: CGSize(width: 1366, height: 1024), screenSize: screen))
        #expect(StudyOrientationGate.fills(sceneSize: CGSize(width: 1024, height: 1366), screenSize: screen))
        #expect(StudyOrientationGate.fills(sceneSize: CGSize(width: 1366.2, height: 1023.8), screenSize: screen),
                "rounding of the geometry is not a window")
        #expect(!StudyOrientationGate.fills(sceneSize: CGSize(width: 1000, height: 800), screenSize: screen))
        #expect(!StudyOrientationGate.fills(sceneSize: CGSize(width: 1366, height: 980), screenSize: screen),
                "a window as wide as the screen but shorter is still a window")
    }

    // MARK: - What a hold does to the session

    @Test("a portrait scene holds the session and a full landscape scene resumes it")
    func portraitHoldsAndLandscapeResumes() {
        let rig = LifecycleRig()
        rig.vm.loadLetter(name: "A")
        #expect(rig.vm.debugLetterLoadTime != nil, "precondition: the live slice is running")
        rig.vm.sceneShapeDidChange(isLandscape: false, fillsScreen: true)
        #expect(rig.vm.orientationHold == .turnToLandscape)
        #expect(rig.vm.activeInterruptions.contains(.orientation))
        #expect(rig.vm.debugLetterLoadTime == nil, "active time accrued under the turn prompt")
        rig.vm.sceneShapeDidChange(isLandscape: true, fillsScreen: true)
        #expect(rig.vm.orientationHold == .none)
        #expect(rig.vm.activeInterruptions.isEmpty)
        #expect(rig.vm.debugLetterLoadTime != nil, "the clock did not restart when the iPad was turned")
    }

    @Test("a landscape window holds the session until the scene fills the screen again")
    func windowHolds() {
        let rig = LifecycleRig()
        rig.vm.loadLetter(name: "A")
        rig.vm.sceneShapeDidChange(isLandscape: true, fillsScreen: false)
        #expect(rig.vm.orientationHold == .fillScreen)
        #expect(rig.vm.activeInterruptions.contains(.orientation))
        rig.vm.sceneShapeDidChange(isLandscape: true, fillsScreen: true)
        #expect(rig.vm.activeInterruptions.isEmpty)
    }

    @Test("no stroke starts under the turn prompt")
    func noStrokeUnderTheHold() {
        let rig = LifecycleRig()
        rig.vm.loadLetter(name: "A")
        rig.vm.phaseController.resume(at: .freeWrite)
        rig.vm.sceneShapeDidChange(isLandscape: false, fillsScreen: true)
        rig.strokeDown()
        #expect(!rig.vm.touchDispatcher.isSingleTouchInteractionActive,
                "a touch under the turn prompt started a stroke")
        rig.vm.endTouch()
        #expect(rig.store.rows(.freeWrite).isEmpty)
    }

    @Test("turning to portrait mid-stroke cancels the stroke; turning back re-arms the quiet window")
    func strokeCutByTheHold() {
        let rig = LifecycleRig()
        rig.vm.loadLetter(name: "A")
        rig.vm.phaseController.resume(at: .freeWrite)
        rig.strokeDown()
        #expect(rig.vm.touchDispatcher.isSingleTouchInteractionActive, "precondition")
        rig.vm.sceneShapeDidChange(isLandscape: false, fillsScreen: true)
        #expect(!rig.vm.touchDispatcher.isSingleTouchInteractionActive, "the stroke ran on under the turn prompt")
        #expect(!rig.vm.touchDispatcher.isFreeWriteAdvanceScheduled)
        rig.vm.sceneShapeDidChange(isLandscape: true, fillsScreen: true)
        #expect(rig.vm.touchDispatcher.isFreeWriteAdvanceScheduled)
        #expect(rig.store.rows(.freeWrite).isEmpty)
    }

    @Test("a letter loaded under the turn prompt (portrait launch) starts its observe only once the iPad is landscape")
    func portraitLaunchWaitsForLandscape() async {
        let rig = LifecycleRig(arm: .phoneme, fallback: 3600)
        rig.vm.sceneShapeDidChange(isLandscape: false, fillsScreen: true)
        rig.vm.loadLetter(name: "A")
        #expect(rig.prompts.count(.phaseObserve) == 0, "the cue was spoken under the turn prompt")
        #expect(!rig.audio.isPlaying)
        #expect(rig.vm.debugLetterLoadTime == nil, "active time accrued under the turn prompt")
        rig.vm.sceneShapeDidChange(isLandscape: true, fillsScreen: true)
        #expect(rig.prompts.count(.phaseObserve) == 1, "the deferred cue was never spoken")
        rig.speech.end(cue)
        await rig.waitUntil { rig.vm.animation.armedStrokes != nil }
        #expect(rig.vm.animation.armedStrokes != nil, "the deferred observe never started")
    }

    @Test("an unchanged shape is not a new hold, and the hold counts as one interruption")
    func repeatedShapeIsOneInterruption() {
        let rig = LifecycleRig()
        rig.vm.loadLetter(name: "A")
        rig.vm.sceneShapeDidChange(isLandscape: true, fillsScreen: true)
        #expect(rig.vm.lifecycleCounters.interruptions == 0, "a landscape report at connect is not an interruption")
        rig.vm.sceneShapeDidChange(isLandscape: false, fillsScreen: true)
        rig.vm.sceneShapeDidChange(isLandscape: false, fillsScreen: true)
        #expect(rig.vm.lifecycleCounters.interruptions == 1)
        rig.vm.sceneShapeDidChange(isLandscape: true, fillsScreen: true)
        #expect(rig.vm.activeInterruptions.isEmpty)
    }

    @Test("the turn prompt and the parent area nest: closing one does not resume under the other")
    func nestsWithTheParentArea() {
        let rig = LifecycleRig()
        rig.vm.loadLetter(name: "A")
        rig.vm.sceneShapeDidChange(isLandscape: false, fillsScreen: true)
        rig.vm.parentAreaDidOpen()
        rig.vm.parentAreaDidClose()
        #expect(rig.vm.activeInterruptions == [.orientation])
        #expect(rig.vm.debugLetterLoadTime == nil)
        rig.vm.sceneShapeDidChange(isLandscape: true, fillsScreen: true)
        #expect(rig.vm.debugLetterLoadTime != nil)
    }
}
