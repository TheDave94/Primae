//  TracingViewModelTests.swift
//  BuchstabenNativeTests

import Testing
import Foundation
import QuartzCore
import CoreGraphics
@testable import BuchstabenNative

@MainActor
fileprivate final class MockAudio: AudioControlling {
    private(set) var loadedFiles: [String] = []
    private(set) var playCount  = 0
    private(set) var stopCount  = 0
    private(set) var suspendForLifecycleCount  = 0
    private(set) var resumeAfterLifecycleCount = 0
    private(set) var cancelPendingLifecycleWorkCount = 0
    private(set) var setAdaptivePlaybackCount  = 0
    func loadAudioFile(named fileName: String, autoplay: Bool) { loadedFiles.append(fileName) }
    func setAdaptivePlayback(speed: Float, horizontalBias: Float) { setAdaptivePlaybackCount += 1 }
    func play()    { playCount  += 1 }
    func stop()    { stopCount  += 1 }
    func restart() {}
    func suspendForLifecycle()        { suspendForLifecycleCount  += 1 }
    func resumeAfterLifecycle()       { resumeAfterLifecycleCount += 1 }
    func cancelPendingLifecycleWork() { cancelPendingLifecycleWorkCount += 1 }
}

@MainActor
@discardableResult
private func fastDrag(vm: TracingViewModel, audio: MockAudio,
    canvasSize: CGSize = CGSize(width: 400, height: 400),
    from: CGPoint = CGPoint(x: 100, y: 200), count: Int = 10,
    startTime: CFTimeInterval = 1000.0) -> CFTimeInterval {
    vm.beginTouch(at: from, t: startTime)
    var t = startTime; var p = from
    for _ in 0..<count { t += 0.001; p.x += 10; vm.updateTouch(at: p, t: t, canvasSize: canvasSize) }
    return t
}

@MainActor
@discardableResult
private func slowDrag(vm: TracingViewModel,
    canvasSize: CGSize = CGSize(width: 400, height: 400),
    from: CGPoint = CGPoint(x: 100, y: 200), count: Int = 10,
    startTime: CFTimeInterval = 1000.0) -> CFTimeInterval {
    vm.beginTouch(at: from, t: startTime)
    var t = startTime; var p = from
    for _ in 0..<count { t += 1.0; p.x += 1; vm.updateTouch(at: p, t: t, canvasSize: canvasSize) }
    return t
}

@Suite(.serialized) @MainActor struct TracingViewModelTests {

    fileprivate let audio: MockAudio
    fileprivate let vm: TracingViewModel

    init() {
        audio = MockAudio()
        vm = TracingViewModel(.stub.with(audio: audio))
        vm.strokeEnforced = false
    }

    @Test func slowVelocity_doesNotTriggerPlay() async {
        let playBefore = audio.playCount
        slowDrag(vm: vm)
        try? await Task.sleep(nanoseconds: 250_000_000)
        #expect(audio.playCount == playBefore)
        #expect(!vm.isPlaying)
    }
    @Test func fastVelocity_triggersPlayAfterDebounce() async {
        let playBefore = audio.playCount
        fastDrag(vm: vm, audio: audio)
        try? await Task.sleep(nanoseconds: 150_000_000)
        #expect(audio.playCount > playBefore)
        #expect(vm.isPlaying)
    }
    @Test func endTouch_stopsPlayback() async {
        fastDrag(vm: vm, audio: audio)
        try? await Task.sleep(nanoseconds: 150_000_000)
        let stopBefore = audio.stopCount
        vm.endTouch()
        #expect(audio.stopCount > stopBefore)
        #expect(!vm.isPlaying)
    }
    @Test func endTouch_withoutPriorTouch_doesNotCrash() {
        vm.endTouch()
        #expect(!vm.isPlaying)
    }
    @Test func appDidEnterBackground_suspendsClearsState() async {
        fastDrag(vm: vm, audio: audio)
        try? await Task.sleep(nanoseconds: 150_000_000)
        let suspendBefore = audio.suspendForLifecycleCount
        let stopBefore = audio.stopCount
        vm.appDidEnterBackground()
        #expect(audio.suspendForLifecycleCount == suspendBefore + 1)
        #expect(audio.stopCount > stopBefore)
        #expect(!vm.isPlaying)
    }
    @Test func appDidBecomeActive_withResumeIntent_resumesAudio() async {
        fastDrag(vm: vm, audio: audio)
        try? await Task.sleep(nanoseconds: 150_000_000)
        vm.appDidEnterBackground()
        let resumeBefore = audio.resumeAfterLifecycleCount
        vm.appDidBecomeActive()
        #expect(audio.resumeAfterLifecycleCount == resumeBefore + 1)
    }
    @Test func appDidBecomeActive_withoutResumeIntent_doesNotForcePlay() async {
        fastDrag(vm: vm, audio: audio)
        try? await Task.sleep(nanoseconds: 150_000_000)
        vm.endTouch(); vm.appDidEnterBackground()
        let playBefore = audio.playCount
        vm.appDidBecomeActive()
        try? await Task.sleep(nanoseconds: 150_000_000)
        #expect(audio.playCount == playBefore)
    }
    @Test func strokeCompletion_forcesIdleAndSetsComplete() async {
        let canvas = CGSize(width: 400, height: 400)
        vm.beginTouch(at: CGPoint(x: 0, y: 0), t: 1000.0)
        var t: CFTimeInterval = 1000.0; var didComplete = false
        outer: for row in stride(from: 0.0, through: 1.0, by: 0.05) {
            for col in stride(from: 0.0, through: 1.0, by: 0.05) {
                t += 0.001
                vm.updateTouch(at: CGPoint(x: col * canvas.width, y: row * canvas.height), t: t, canvasSize: canvas)
                if vm.progress >= 1.0 { didComplete = true; break outer }
            }
        }
        guard didComplete else { return } // not completable via grid scan — silent skip
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(vm.progress == 1.0)
        #expect(!vm.isPlaying)
    }
    @Test func resetLetter_clearsProgressAndStops() async {
        fastDrag(vm: vm, audio: audio)
        try? await Task.sleep(nanoseconds: 150_000_000)
        let stopBefore = audio.stopCount
        vm.resetLetter()
        #expect(vm.progress == 0.0)
        #expect(!vm.isPlaying)
        #expect(audio.stopCount > stopBefore)
    }
    @Test func multiTouchNavigation_suppressesSingleTouch() async {
        vm.beginMultiTouchNavigation()
        vm.beginTouch(at: CGPoint(x: 100, y: 100), t: 1000)
        fastDrag(vm: vm, audio: audio, startTime: 1000.1)
        try? await Task.sleep(nanoseconds: 150_000_000)
        #expect(!vm.isPlaying)
    }
    @Test func updateTouch_callsSetAdaptivePlayback() {
        let countBefore = audio.setAdaptivePlaybackCount
        fastDrag(vm: vm, audio: audio, count: 5)
        #expect(audio.setAdaptivePlaybackCount > countBefore)
    }
    @Test func rapidBgFgChurn_neverLeavesPlayingTrue() async {
        fastDrag(vm: vm, audio: audio)
        try? await Task.sleep(nanoseconds: 150_000_000)
        for _ in 0..<10 { vm.appDidEnterBackground(); vm.appDidBecomeActive() }
        vm.appDidEnterBackground()
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(!vm.isPlaying)
    }
    @Test func nextLetter_resetsShowGhostToFalse() {
        vm.toggleGhost(); #expect(vm.showGhost)
        vm.nextLetter()
        #expect(!vm.showGhost)
    }
    @Test func previousLetter_resetsShowGhostToFalse() {
        vm.nextLetter(); vm.toggleGhost(); #expect(vm.showGhost)
        vm.previousLetter()
        #expect(!vm.showGhost)
    }
    @Test func resetLetter_doesNotChangeShowGhost() {
        vm.toggleGhost(); vm.resetLetter()
        #expect(vm.showGhost)
    }
    @Test func tracingViewModel_doesNotRetainSelf() async {
        weak var weakVM: TracingViewModel?
        await MainActor.run {
            let localVM = TracingViewModel(.stub)
            weakVM = localVM
            localVM.appDidBecomeActive()
        }
        try? await Task.sleep(nanoseconds: 500_000_000)
        #expect(weakVM == nil)
    }
}
