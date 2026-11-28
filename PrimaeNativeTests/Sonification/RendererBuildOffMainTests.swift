// RendererBuildOffMainTests.swift
// PrimaeNativeTests: lane RENDERFREEZE (2026-11-28)
//
// Up to r32 a letter loaded before the launch prewarm had built its renderer built the TDPSOLA2 pair ON THE MAIN
// THREAD: 2.2-6.2 s on the iPad (Debug-Study), the child-facing UI frozen for all of it. A load now has its pair
// built through the voice's `buildRenderers` (production: off the main thread) and binds it, sounding if it is
// meant to, once it is published. These cases run the PRODUCTION runner with a slow builder seam.
//
// Mutation check: make `requestRenderer` build inline (`make(source)` then `store.put` with no `buildRenderers`
// hop), i.e. the r32 main-thread build. `loadReturnsBeforeTheBuildAndTheBuildIsOffMain` goes RED.

import Testing
import Foundation
@testable import PrimaeNative

@Suite("RENDERFREEZE: a load's renderer build never runs on the main thread")
@MainActor struct RendererBuildOffMainTests {

    /// A builder that takes time: it waits for `release()` (bounded at 1 s, so a build that runs on the main
    /// thread stalls the test, it does not hang it) and records the thread it ran on.
    nonisolated final class SlowBuilder: @unchecked Sendable {
        private let lock = NSLock()
        private let gate = DispatchSemaphore(value: 0)
        private let timeout: TimeInterval
        init(timeout: TimeInterval = 1) { self.timeout = timeout }
        private var records: [(key: String, onMain: Bool)] = []
        var calls: [(key: String, onMain: Bool)] { lock.lock(); defer { lock.unlock() }; return records }
        func release(_ n: Int = 1) { for _ in 0..<n { gate.signal() } }
        func make(_ s: SonificationSource) -> (TDPSOLA2, TDPSOLA2) {
            lock.lock(); records.append((s.key, Thread.isMainThread)); lock.unlock()
            _ = gate.wait(timeout: .now() + timeout)
            return LiveSonificationAudio.makeRendererPair(s)
        }
    }

    static func voice(_ b: SlowBuilder) -> LiveSonificationAudio {
        let sources = ["a": LiveSonificationAudioTests.tone("a"), "m": LiveSonificationAudioTests.tone("m", hz: 150)]
        return LiveSonificationAudio(host: HostSpy(), output: FakeLiveOutput(), kernel: LiveSonificationKernel(),
                                     fadeOutSeconds: 0.05, observeSession: false,
                                     buildRenderers: LiveSonificationAudio.offMainRendererBuild,
                                     makePair: { b.make($0) },
                                     resolve: { name, _ in sources[name] })
    }

    /// Lets the main actor run (the hop that registers a published pair) until `done`, at most 5 s.
    static func settle(_ done: @MainActor () -> Bool) async {
        for _ in 0..<500 where !done() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test("an un-prewarmed load returns before its renderer is built, the build runs off the main thread, and the observe sound starts when it is ready")
    func loadReturnsBeforeTheBuildAndTheBuildIsOffMain() async {
        let b = SlowBuilder()
        let v = Self.voice(b)
        v.loadAudioFile(named: "a", autoplay: true)
        #expect(!v.isPlaying, "the load waited for the renderer build (r32: built on the main thread)")
        #expect(v.loadedKey == "a", "the load is recorded at once")
        b.release()
        await Self.settle { v.isPlaying }
        #expect(b.calls.count == 1)
        #expect(b.calls.first?.onMain == false, "the renderer was built on the main thread")
        #expect(v.mainActorBuilds == 0)
        #expect(v.isPlaying && v.kernel.gateRequested, "the observe sound did not start once the renderer was ready")
    }

    @Test("a stop before the renderer is ready: nothing sounds when it arrives")
    func stopBeforeReadyStaysSilent() async {
        let b = SlowBuilder()
        let v = Self.voice(b)
        v.loadAudioFile(named: "a", autoplay: true)
        v.stop()
        b.release()
        await Self.settle { v.awaitingRenderers.isEmpty }
        #expect(v.awaitingRenderers.isEmpty, "the published pair was never registered")
        #expect(!v.isPlaying && !v.kernel.gateRequested, "a stopped load sounded when its renderer arrived")
        #expect(v.loadedKey == nil)
    }

    @Test("a switch while the first letter's renderer is building: only the second letter sounds, once its own is ready")
    func switchWhileBuildingPlaysOnlyTheNewLetter() async {
        let b = SlowBuilder()
        let v = Self.voice(b)
        v.loadAudioFile(named: "a", autoplay: true)
        v.loadAudioFile(named: "m", autoplay: true)
        b.release(2)
        await Self.settle { v.awaitingRenderers.isEmpty && v.isPlaying }
        #expect(Set(b.calls.map(\.key)) == ["a", "m"])
        #expect(b.calls.allSatisfy { !$0.onMain })
        #expect(v.loadedKey == "m" && v.isPlaying)
        // The late "a" pair is registered (cached for the next load of a) but does not take the load over.
        v.loadAudioFile(named: "a", autoplay: false)
        #expect(b.calls.count == 2, "a's pair was built again instead of reused")
    }

    @Test("a play while the renderer is building sounds once it is ready (the load without autoplay, then play)")
    func playWhileBuildingSoundsWhenReady() async {
        let b = SlowBuilder()
        let v = Self.voice(b)
        v.loadAudioFile(named: "a", autoplay: false)
        v.play()
        #expect(!v.isPlaying)
        b.release()
        await Self.settle { v.isPlaying }
        #expect(v.isPlaying && v.kernel.gateRequested)
    }
}
