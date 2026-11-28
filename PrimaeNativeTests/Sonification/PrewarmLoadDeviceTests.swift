// PrewarmLoadDeviceTests.swift
// PrimaeNativeTests: lane FOLLOWUP-r31 (2026-11-27)
//
// A DEVICE instrument, like the R20 ones: it times main-actor work against a 15 ms bound with the study's real
// assets, and waits for a prewarm that takes about 63 s under Debug-Study (-Onone) on the iPad. It runs in the
// `Primae-DeviceTests` scheme on the iPad; the `Primae` scheme (CI's simulator run) lists it in its SkippedTests, and
// a simulator run fails (`r20RequireDevice`) instead of passing on a clock that says nothing about the iPad.

import XCTest
import Foundation
@testable import PrimaeNative

final class PrewarmLoadDeviceTests: XCTestCase {

    /// With the study's real assets, a letter's first load after the launch prewarm decodes nothing and builds no
    /// renderer on the main actor, and holds it under 15 ms (r31 code on the iPad: 5 decodes, worst 19.7 ms).
    @MainActor
    func testStudyLetterLoadsAreFastAfterThePrewarm() async throws {
        try r20RequireDevice()
        var resolves = 0
        let voice = LiveSonificationAudio(host: HostSpy(), output: FakeLiveOutput(), kernel: LiveSonificationKernel(),
                                          fadeOutSeconds: 0.4, observeSession: false,
                                          sourceKey: LiveSonificationAudio.bundleSourceKey(named:),
                                          resolve: { name, rate in
                                              resolves += 1
                                              return LiveSonificationAudio.bundleSource(named: name, sampleRate: rate)
                                          })
        let names: [String] = TrainedLetterSubset.studyLetters.compactMap { l in
            PrimaeBundle.layouts(dir: "Letters/\(l)", name: "\(l)_phoneme1", ext: "wav")
                .first { PrimaeBundle.audioURL(for: $0) != nil }
        }
        XCTAssertEqual(names.count, TrainedLetterSubset.studyLetters.count)
        voice.prewarmStudySources()
        let keys = names.compactMap(LiveSonificationAudio.bundleSourceKey(named:))
        // The prewarm builds a TDPSOLA2 pair per source; under Debug-Study (-Onone) on the iPad that is ~15 s each,
        // ~63 s for the set (measured 2026-11-27), so the wait is bounded at 240 s, not 60 s: at 60 s the last pair
        // was still building and the load built it on main, which measured the bound, not the load.
        // RENDERFREEZE: the prewarm decodes every source first, so "all decoded, none pending" held after 0.2 s,
        // before any pair was built. The wait is for every pair REGISTERED (`adopt`).
        let w0 = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<4800 where !keys.allSatisfy(voice.hasRegisteredRenderer(forKey:)) {
            try? await Task.sleep(for: .milliseconds(50))
        }
        let waited = Double(DispatchTime.now().uptimeNanoseconds - w0) / 1e9
        XCTAssertTrue(keys.allSatisfy { voice.prewarmed.source(forKey: $0) != nil }
                      && keys.allSatisfy(voice.hasRegisteredRenderer(forKey:)),
                      "the prewarm was not adopted after \(waited) s")
        var worst = 0.0
        for name in names {
            let t0 = DispatchTime.now().uptimeNanoseconds
            voice.loadAudioFile(named: name, autoplay: false)
            worst = max(worst, Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
        }
        print(String(format: "PREWARM waited %.1f s; worst letter load %.2f ms; resolves %d; main builds %d",
                     waited, worst, resolves, voice.mainActorBuilds))
        XCTAssertEqual(resolves, 0, "a load decoded a study file on the main actor")
        XCTAssertEqual(voice.mainActorBuilds, 0)
        XCTAssertTrue(voice.awaitingRenderers.isEmpty, "a load requested a build the prewarm had already done")
        XCTAssertLessThan(worst, 15, "worst letter load held the main actor \(worst) ms")
    }
}
