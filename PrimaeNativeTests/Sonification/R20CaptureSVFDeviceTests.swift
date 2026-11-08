// R20CaptureSVFDeviceTests.swift
// PrimaeNativeTests: lane R20 (2026-11-08) DEVICE INSTRUMENT, SKIPS ON THE SIMULATOR
//
// R20's listening renders that need the R20 kernel API (the r19 baseline build of the captures does not have it). The 2-pole
// against one-pole renders of the r20 page (section 6) are gone with the one-pole: David chose the 2-pole in r21.

import XCTest
import Foundation
@testable import PrimaeNative

final class R20CaptureSVFDeviceTests: XCTestCase {
    override func setUpWithError() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("device instrument: AVAudioEngine does not run on the simulator")
        #endif
        if !r20InstrumentsEnabled { throw XCTSkip("listening captures: run with TEST_RUNNER_R20_INSTRUMENTS=1") }
    }

    private func name(_ kind: String, _ src: String) -> String { "\(R20CaptureRig.variant)_off_\(kind)_\(src)" }

    /// The mute step with the smoothing time constant swept (gain tau 3 / 6 / 12 / 20 ms; 6 is chosen).
    func testOff_5_tauSweep() throws {
        for s in ["spatial_carrier", "I_phoneme1"] {
            for tau in [0.003, 0.006, 0.012, 0.020] {
                try R20Offline.write(try R20Offline.render(s, seconds: 2.4,
                    make: { LiveSonificationKernel(smoothing: .init(toneGainSeconds: tau, toneCutoffSeconds: 0.012, pressureSeconds: tau)) },
                    events: [(0.6, { $0.setStrokeMute(true) }), (1.4, { $0.setStrokeMute(false) })]), name: name("tau\(Int(tau * 1000))ms", s))
            }
        }
    }

    /// The direction mute on a pen that hovers on the -0.25 boundary (heading 104.5 deg +- 8 deg, 0.7 pt jitter, 10 s on the real touch
    /// path): its mute decisions at 120 Hz, rendered through the kernel, with and without the hysteresis.
    @MainActor func testOff_6_chatter() async throws {
        for (tag, margin) in [("hysteresisOff", Float(0)), ("hysteresisOn", StrokeTone.releaseMarginCosine)] {
            let r = R20Pen.chatter(base: 104.5, wobble: 8, sigma: 0.7, seconds: 6, margin: margin)
            for s in ["spatial_carrier", "I_phoneme1"] {
                let decisions = r.mutes
                let events: [(Double, (LiveSonificationKernel) -> Void)] = decisions.enumerated().map { i, m in (Double(i) / 120, { $0.setStrokeMute(m) }) }
                try R20Offline.write(try R20Offline.render(s, seconds: 6, events: events), name: name("chatter_" + tag, s))
            }
            print(String(format: "R20 CHATTER-RENDER %@: %.2f toggles/s, flickers %d", tag, r.toggles, r.flickers))
        }
    }
}
