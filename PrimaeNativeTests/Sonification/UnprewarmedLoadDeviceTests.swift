// UnprewarmedLoadDeviceTests.swift
// PrimaeNativeTests: lane RENDERFREEZE (2026-11-28)
//
// A DEVICE instrument, like PrewarmLoadDeviceTests: the iPad's clock with the study's real assets. It runs in the
// `Primae-DeviceTests` scheme; the `Primae` scheme lists it in its SkippedTests, and a simulator run fails
// (`r20RequireDevice`).
//
// A study letter loaded BEFORE the launch prewarm built its renderer (the session's first letter, a chevron in the
// first minute): how long the load holds the main thread, and the longest the main thread then goes without
// running while the build completes. "before" is the r32 path (the build runs inline on the main thread, which is
// what `inlineRendererBuild` is); "after" is production's `offMainRendererBuild`.

import XCTest
import Foundation
@testable import PrimaeNative

final class UnprewarmedLoadDeviceTests: XCTestCase {

    @MainActor
    func testUnprewarmedLetterLoadDoesNotHoldTheMainThread() async throws {
        try r20RequireDevice()
        let name = try XCTUnwrap(PrimaeBundle.layouts(dir: "Letters/I", name: "I_phoneme1", ext: "wav")
            .first { PrimaeBundle.audioURL(for: $0) != nil })
        func voice(_ runner: @escaping LiveSonificationAudio.RendererBuildRunner) -> LiveSonificationAudio {
            LiveSonificationAudio(host: HostSpy(), output: FakeLiveOutput(), kernel: LiveSonificationKernel(),
                                  fadeOutSeconds: 0.4, observeSession: false,
                                  sourceKey: LiveSonificationAudio.bundleSourceKey(named:),
                                  buildRenderers: runner,
                                  resolve: LiveSonificationAudio.bundleSource(named:sampleRate:))
        }
        func ms(since t0: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6 }
        // The prewarm decodes every study source first (about 75 ms each, RENDERFREEZE), well before the first
        // letter loads; both voices get the decoded source, so what is measured is the renderer build.
        let src = try XCTUnwrap(LiveSonificationAudio.bundleSource(named: name, sampleRate: LiveSonificationKernel().sampleRate))
        func withSource(_ v: LiveSonificationAudio) -> LiveSonificationAudio { v.prewarmed.putSource(src); return v }

        // before: the r32 path, the build inline on the main thread
        let old = withSource(voice(LiveSonificationAudio.inlineRendererBuild))
        var t0 = DispatchTime.now().uptimeNanoseconds
        old.loadAudioFile(named: name, autoplay: true)
        let before = ms(since: t0)
        XCTAssertTrue(old.isPlaying)

        // after: production
        let v = withSource(voice(LiveSonificationAudio.offMainRendererBuild))
        t0 = DispatchTime.now().uptimeNanoseconds
        v.loadAudioFile(named: name, autoplay: true)
        let after = ms(since: t0)
        var worstGap = 0.0
        var last = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<12000 where !v.isPlaying {   // at most ~60 s
            try? await Task.sleep(for: .milliseconds(5))
            worstGap = max(worstGap, ms(since: last))
            last = DispatchTime.now().uptimeNanoseconds
        }
        let ready = ms(since: t0)
        print(String(format: "RENDERFREEZE before: load held main %.1f ms | after: load held main %.2f ms, sound ready after %.1f ms, worst main-actor gap meanwhile %.1f ms, main builds %d",
                     before, after, ready, worstGap, v.mainActorBuilds))
        XCTAssertTrue(v.isPlaying, "the sound never started")
        XCTAssertEqual(v.mainActorBuilds, 0)
        XCTAssertLessThan(after, 15, "the un-prewarmed load held the main thread \(after) ms")
        XCTAssertLessThan(worstGap, 100, "the main actor stalled \(worstGap) ms while the renderer was built")
    }

    /// RENDERFREEZE2: how long a sound arm's observe presentation waits for its renderer (`whenRendererReady`), with
    /// the launch prewarm running alongside as in the app: the fresh session's first letter loaded at launch (I, then
    /// the next letter L prioritised, as `load(letter:)` does), and a chevron to L the moment I is ready (the worst
    /// case: L's build has had only I's time). The presentation itself starts after the observe cue (its end + 1.0 s,
    /// or 3.0 s after its start), so the child-facing wait is this minus that. Run it in Release-Study for the
    /// artefact's numbers (Debug-Study is -Onone).
    @MainActor
    func testRendererWaitForTheFirstLetterAndAChevron() async throws {
        try r20RequireDevice()
        func file(_ l: String) throws -> String {
            try XCTUnwrap(PrimaeBundle.layouts(dir: "Letters/\(l)", name: "\(l)_phoneme1", ext: "wav")
                .first { PrimaeBundle.audioURL(for: $0) != nil })
        }
        let first = try file("I"), next = try file("L")
        let v = LiveSonificationAudio(host: HostSpy(), output: FakeLiveOutput(), kernel: LiveSonificationKernel(),
                                      fadeOutSeconds: 0.4, observeSession: false,
                                      sourceKey: LiveSonificationAudio.bundleSourceKey(named:),
                                      buildRenderers: LiveSonificationAudio.offMainRendererBuild,
                                      resolve: LiveSonificationAudio.bundleSource(named:sampleRate:))
        func ms(since t0: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6 }
        func waitReady(_ name: String) async -> Double {
            let t0 = DispatchTime.now().uptimeNanoseconds
            var done = false
            v.whenRendererReady(forFile: name) { done = true }
            for _ in 0..<12000 where !done { try? await Task.sleep(for: .milliseconds(5)) }
            XCTAssertTrue(done, "\(name) never became ready")
            return ms(since: t0)
        }
        let t0 = DispatchTime.now().uptimeNanoseconds
        v.prewarmStudySources()
        v.loadAudioFile(named: first, autoplay: false)
        let loadHeld = ms(since: t0)
        v.prioritizeRenderer(forFile: next)
        let firstWait = await waitReady(first)
        v.loadAudioFile(named: next, autoplay: false)
        let chevronWait = await waitReady(next)
        print(String(format: "RENDERFREEZE2 wait: first letter I ready %.1f ms after launch (load held main %.1f ms); chevron to L at I-ready: L ready %.1f ms later; main builds %d",
                     firstWait, loadHeld, chevronWait, v.mainActorBuilds))
        XCTAssertEqual(v.mainActorBuilds, 0)
    }
}
