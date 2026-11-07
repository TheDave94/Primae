// SoundGatingSwitchTests.swift
// PrimaeNativeTests
//
// R18DIM slice 3: "Ton nur auf dem Buchstaben" (StudyComparisonSettings.soundGatingEnabled).
// ON (default) is protocol r17: guided sound needs the pen near the next checkpoint.
// OFF: the sound follows the pen wherever it moves on the canvas, in both sound arms.
//
// No global UserDefaults key is written anywhere in this file (Swift Testing runs suites in
// parallel; see TriggerBoundaryTests' header). The switch is injected through
// `TracingDependencies.soundGatingEnabled`, the seam the other switches use.

import Testing
import Foundation
import CoreGraphics
@testable import PrimaeNative

@MainActor
private final class GateCountingAudio: AudioControlling {
    var initializationError: String? { nil }
    private(set) var playCount = 0
    func loadAudioFile(named fileName: String, autoplay: Bool) {}
    func setAdaptivePlayback(speed: Float, horizontalBias: Float) {}
    func play()    { playCount += 1 }
    func stop()    {}
    func restart() {}
    func suspendForLifecycle()        {}
    func resumeAfterLifecycle()       {}
    func cancelPendingLifecycleWork() {}
}

@Suite(.serialized) @MainActor
struct SoundGatingSwitchTests {

    private let canvas = CGSize(width: 400, height: 400)

    // MARK: - Seam A: the decision as a value

    @Test("the proximity decision: gate on needs the letter, gate off or free-write does not")
    func decisionTable() {
        typealias TD = TouchDispatcher
        // gate ON (r17): only near the stroke, or in the already-ungated free-write
        #expect(TD.proximityAllowsSound(ungatedPhase: false, gatingEnabled: true, isNearStroke: true))
        #expect(TD.proximityAllowsSound(ungatedPhase: false, gatingEnabled: true, isNearStroke: false) == false)
        #expect(TD.proximityAllowsSound(ungatedPhase: true,  gatingEnabled: true, isNearStroke: false))
        // gate OFF: everywhere
        #expect(TD.proximityAllowsSound(ungatedPhase: false, gatingEnabled: false, isNearStroke: false))
        #expect(TD.proximityAllowsSound(ungatedPhase: false, gatingEnabled: false, isNearStroke: true))
    }

    // MARK: - Seam B: the stamp and the default

    @Test("the default is ON and a default session stamps nothing for it")
    func defaultIsOnAndUnstamped() {
        #expect(StudyComparisonSettings.soundGatingEnabledDefault == true)
        #expect(StudyComparisonConfiguration.defaults.soundGatingEnabled)
        #expect(StudyComparisonConfiguration.defaults.nonDefaultStamp == nil)
        var c = StudyComparisonConfiguration.defaults
        c.soundGatingEnabled = false
        #expect(c.nonDefaultStamp == "soundGatingEnabled=false")
    }

    @Test("the session's stamp names the switch only when it is off")
    func sessionStamp() {
        func stamp(_ on: Bool) -> String {
            var deps = TracingDependencies.stub
            deps.soundGatingEnabled = on
            deps.studyMode = true
            return TracingViewModel(deps).comparisonConfigurationStamp ?? ""
        }
        #expect(stamp(false).contains("soundGatingEnabled=false"))
        #expect(stamp(true).contains("soundGatingEnabled") == false)
    }

    @Test("reset restores the gate to ON")
    func resetRestores() {
        let suite = "SoundGatingSwitchTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: StudyComparisonSettings.soundGatingEnabledKey)
        #expect(StudyComparisonSettings.configuration(in: defaults).soundGatingEnabled == false,
                "precondition: the stored value must be read")
        let changed = StudyComparisonSettings.resetToDefaults(in: defaults)
        #expect(changed)
        #expect(StudyComparisonSettings.configuration(in: defaults).soundGatingEnabled)
    }

    // MARK: - The switch reaches the running dispatcher

    @Test("the switch lands on the dispatcher at construction")
    func reachesDispatcher() {
        var deps = TracingDependencies.stub
        deps.soundGatingEnabled = false
        #expect(TracingViewModel(deps).touchDispatcher.soundGatingEnabled == false)
        #expect(TracingViewModel(.stub).touchDispatcher.soundGatingEnabled)
    }

    // MARK: - What the child would hear (the production touch path)

    /// Same gesture as TriggerBoundaryTests.factorIsAudible: the pen lands on the first
    /// checkpoint and moves to 2x the hit radius, outside a 1x sound gate. With a 1x gate and
    /// the gate ON that is silent (r17); with the gate OFF the same gesture sounds.
    private func plays(gating: Bool, arm: PilotAudioCondition) -> Bool? {
        let audio = GateCountingAudio()
        var deps = TracingDependencies.stub.with(audio: audio)
        deps.soundGateRadiusFactor = 1.0
        deps.soundGatingEnabled = gating
        deps.audioCondition = arm
        deps.makePlaybackController = { audio, cb in
            PlaybackController(audio: audio, sleep: { _ in }, onIsPlayingChanged: cb)
        }
        let vm = TracingViewModel(deps)
        vm.canvasSize = canvas
        guard let definition = vm.strokeTracker.definition,
              definition.strokes.first?.checkpoints.isEmpty == false else { return nil }
        let frame = vm.grid.activeCell.frame
        let hit   = definition.checkpointRadius * vm.strokeTracker.radiusMultiplier
        let first = definition.strokes[0].checkpoints[0]
        let distance = min(2 * hit, 0.95)
        guard hit > 0, distance > hit, first.x + distance <= 1.0 else { return nil }
        let start  = CGPoint(x: frame.minX + first.x * frame.width,
                             y: frame.minY + first.y * frame.height)
        let target = CGPoint(x: frame.minX + (first.x + distance) * frame.width, y: start.y)
        guard target.x <= canvas.width, target.y <= canvas.height else { return nil }
        vm.beginTouch(at: start, t: 1000.0)
        vm.updateTouch(at: target, t: 1000.001, canvasSize: canvas)
        return audio.playCount > 0
    }

    @Test("gating off makes a stroke away from the letter audible; on keeps it silent (r17)")
    func audibleOffSilentOn() {
        for arm in [PilotAudioCondition.phoneme, .spatial] {
            #expect(plays(gating: true, arm: arm) == false,
                    "default (gate ON) must stay silent away from the letter, arm \(arm)")
            #expect(plays(gating: false, arm: arm) == true,
                    "gate OFF must sound wherever the pen moves, arm \(arm)")
        }
    }
}
