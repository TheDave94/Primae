// AudioRouteChangeTests.swift
// R-019 (audit 2026-10-13, H1-04 / AA-F5): on a lost output (headphones
// unplugged, Bluetooth gone) `AudioEngine` stops itself
// (`handleRouteChangeValue(.oldDeviceUnavailable)` → `stop()`), but the
// playback state machine was never told: it stayed `.active`, so every
// following `request(.active)` was a no-op and the pen stayed silent until
// a stall or a lift reset the machine. Nothing recorded the change.
//
// Scope (batch C): the view model forces the machine idle so the next
// moving sample plays again, and counts/stamps the change. Whether a sound
// arm may continue on a non-headphone route at all is NEEDS-DAVID (D7),
// and observe's recovery from a lost route is batch E (AudioEngine S2).

import Testing
import CoreGraphics
import AVFoundation
@testable import PrimaeNative

@Suite @MainActor struct AudioRouteChangeTests {

    /// Free-writing (ungated) in a sound arm, pen down and sounding.
    private func sounding() -> LifecycleRig {
        let rig = LifecycleRig(arm: .phoneme)
        rig.vm.loadLetter(name: "A")
        rig.vm.phaseController.resume(at: .freeWrite)
        rig.strokeDown()
        return rig
    }

    @Test("a lost output: the next moving sample plays again, at once")
    func lostOutputRecoversOnTheNextSample() {
        let rig = sounding()
        #expect(rig.audio.isPlaying, "precondition: sounding under the pen")
        // The engine's own reaction to a lost output (AudioEngine.swift
        // handleRouteChangeValue → stop()), modelled by the double.
        rig.audio.stop()
        rig.vm.handleAudioRouteChange(reasonRawValue: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue,
                                   outputLost: true, outputPortType: "Speaker")
        let playsBefore = rig.audio.playCount
        var t: CFTimeInterval = 1200
        var p = CGPoint(x: 210, y: 200)
        for _ in 0..<5 { t += 0.01; p.x += 5; rig.vm.updateTouch(at: p, t: t, canvasSize: rig.canvas) }
        #expect(rig.audio.playCount > playsBefore,
                "the pen stayed silent after the route change — the machine still thought it was playing")
        #expect(rig.audio.isPlaying && rig.audio.loadedFile != nil,
                "played without a file: \(rig.audio.events.suffix(4))")
    }

    @Test("every device route change is counted and the new output stamped")
    func routeChangeIsStamped() {
        let rig = sounding()
        rig.vm.handleAudioRouteChange(reasonRawValue: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue,
                                   outputLost: true, outputPortType: "Speaker")
        rig.vm.handleAudioRouteChange(reasonRawValue: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue,
                                   outputLost: false, outputPortType: "Headphones")
        #expect(rig.vm.lifecycleCounters.routeChanges == 2)
        #expect(rig.vm.lifecycleCounters.outputRoute == "Headphones")
    }

    @Test("a route change that loses nothing leaves playback alone")
    func gainedOutputLeavesPlaybackAlone() {
        let rig = sounding()
        let eventsBefore = rig.audio.events.count
        rig.vm.handleAudioRouteChange(reasonRawValue: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue,
                                   outputLost: false, outputPortType: "Headphones")
        #expect(rig.vm.isPlaying, "a new device must not silence the pen")
        #expect(rig.audio.events.count == eventsBefore, "\(rig.audio.events.suffix(3))")
    }
}
