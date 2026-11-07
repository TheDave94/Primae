// StrokeToneTests.swift
// PrimaeNativeTests — R18 slices 4+5 (sonification dimensions), 2026-11-06
//
// "Distance from the stroke darkens and quietens the sound" and "Direction
// along the stroke mutes the sound when the pen moves backwards". Both
// switches default OFF = protocol r17.
//   seam A: StrokeContext / StrokeTone / ArmCoupling.parameters (pure)
//   seam B: StudyComparisonConfiguration.nonDefaultStamp + reset
//   seam C: LiveSonificationKernel offline render
//   wiring: the pen's touch path (TouchDispatcher) writes the tone only when a switch is on.
// The reference stroke here is a synthetic A-left-leg (bottom-left up to the apex), not the bundled A.

import Testing
import Foundation
import CoreGraphics
@testable import PrimaeNative

// MARK: - Seam A

@Suite("R18 stroke tone mapping (seam A)") @MainActor
struct StrokeToneMappingTests {

    /// Writes bottom-left to apex: direction (+0.3, -0.8) per step in cell fractions (y grows downwards).
    static let leg: LetterStrokes = {
        let cps = (0...20).map { i -> Checkpoint in
            let t = CGFloat(i) / 20
            return Checkpoint(x: 0.2 + 0.3 * t, y: 0.9 - 0.8 * t)
        }
        return LetterStrokes(letter: "A", checkpointRadius: 0.05, strokes: [StrokeDefinition(id: 1, checkpoints: cps)])
    }()
    static let gate: CGFloat = 0.15        // checkpointRadius 0.05 x gate factor 3
    static let along = CGVector(dx: 0.3, dy: -0.8)
    static let mid = CGPoint(x: 0.35, y: 0.5)

    /// A point `gates` gate radii off the stroke's middle, perpendicular to it (cell aspect 1).
    static func offStroke(_ gates: CGFloat) -> CGPoint {
        let len = hypot(along.dx, along.dy)
        let nx = -along.dy / len, ny = along.dx / len
        return CGPoint(x: mid.x + nx * gate * gates, y: mid.y + ny * gate * gates)
    }

    static func context(at p: CGPoint, movement: CGVector? = nil) -> StrokeContext? {
        StrokeContext.measure(point: p, movement: movement, aspect: 1, definition: leg, gateRadius: gate)
    }

    @Test("both switches off: no tone at all, and the coupling is exactly r17's")
    func offIsR17() {
        #expect(StrokeTone.make(context: Self.context(at: Self.mid), distanceEnabled: false, directionEnabled: false) == nil)
        for arm in [PilotAudioCondition.phoneme, .spatial] {
            let p = ArmCoupling.parameters(canvasNormalized: CGPoint(x: 0.3, y: 0.4), velocity: 100,
                                           panningEnabled: true, rateCouplingEnabled: true, arm: arm)
            #expect(p.strokeTone == nil, "\(arm): an off switch produced a tone")
        }
    }

    @Test("on the stroke the tone is neutral: 0 dB, no filter, not muted")
    func onStrokeNeutral() throws {
        let c = try #require(Self.context(at: Self.mid))
        #expect(c.normalizedDistance < 1e-5)
        let tone = try #require(StrokeTone.make(context: c, distanceEnabled: true, directionEnabled: true))
        #expect(tone == StrokeTone.neutral)
    }

    @Test("half a gate radius off the stroke: lower level and lower cutoff than on it")
    func halfGateRadius() throws {
        let on = try #require(StrokeTone.make(context: Self.context(at: Self.mid), distanceEnabled: true, directionEnabled: false))
        let c = try #require(Self.context(at: Self.offStroke(0.5)))
        #expect(abs(c.normalizedDistance - 0.5) < 0.01, "distance \(c.normalizedDistance)")
        let off = try #require(StrokeTone.make(context: c, distanceEnabled: true, directionEnabled: false))
        #expect(off.levelDB < on.levelDB - 5.5 && off.levelDB > -6.5, "level \(off.levelDB)")
        #expect(off.lowpassHz < on.lowpassHz && abs(off.lowpassHz - 4000) < 150, "cutoff \(off.lowpassHz)")
        #expect(!off.muted)
    }

    @Test("far from the stroke the effect saturates at -12 dB and 800 Hz")
    func farSaturates() throws {
        let far = try #require(StrokeTone.make(context: Self.context(at: Self.offStroke(3)),
                                               distanceEnabled: true, directionEnabled: false))
        #expect(far.levelDB == StrokeTone.farLevelDB)
        #expect(abs(far.lowpassHz - StrokeTone.farCutoffHz) < 0.01)
    }

    @Test("direction: along the stroke is audible, against it is muted, across it is audible")
    func directionMute() throws {
        func muted(_ m: CGVector) throws -> Bool {
            let c = try #require(Self.context(at: Self.mid, movement: m))
            return try #require(StrokeTone.make(context: c, distanceEnabled: false, directionEnabled: true)).muted
        }
        #expect(try !muted(Self.along))
        #expect(try muted(CGVector(dx: -Self.along.dx, dy: -Self.along.dy)))
        #expect(try !muted(CGVector(dx: 0.8, dy: 0.3)), "a sideways step must not mute")
        // Not near the stroke (beyond one gate radius): direction means nothing, no mute.
        let c = try #require(Self.context(at: Self.offStroke(2), movement: CGVector(dx: -0.3, dy: 0.8)))
        #expect(try #require(StrokeTone.make(context: c, distanceEnabled: false, directionEnabled: true)).muted == false)
        // No movement yet: audible.
        let still = try #require(Self.context(at: Self.mid))
        #expect(try #require(StrokeTone.make(context: still, distanceEnabled: false, directionEnabled: true)).muted == false)
    }

    @Test("switch independence: direction alone leaves level and cutoff alone, distance alone never mutes")
    func independent() throws {
        let c = try #require(Self.context(at: Self.offStroke(0.8), movement: CGVector(dx: -0.3, dy: 0.8)))
        let dir = try #require(StrokeTone.make(context: c, distanceEnabled: false, directionEnabled: true))
        #expect(dir.levelDB == 0 && dir.lowpassHz == StrokeTone.bypassHz && dir.muted)
        let dist = try #require(StrokeTone.make(context: c, distanceEnabled: true, directionEnabled: false))
        #expect(dist.levelDB < 0 && !dist.muted)
    }

    @Test("no reference geometry (or free writing): a switch that is on gives the neutral tone")
    func noContextIsNeutral() {
        #expect(StrokeTone.make(context: nil, distanceEnabled: true, directionEnabled: true) == StrokeTone.neutral)
    }

    @Test("both sound arms receive the identical tone through ArmCoupling")
    func armsIdentical() throws {
        let tone = StrokeTone(levelDB: -6, lowpassHz: 4000, muted: true)
        let a = ArmCoupling.parameters(canvasNormalized: CGPoint(x: 0.3, y: 0.4), velocity: 100,
                                       panningEnabled: true, rateCouplingEnabled: true, arm: .phoneme, strokeTone: tone)
        let b = ArmCoupling.parameters(canvasNormalized: CGPoint(x: 0.3, y: 0.4), velocity: 100,
                                       panningEnabled: true, rateCouplingEnabled: true, arm: .spatial, strokeTone: tone)
        #expect(a.strokeTone == tone && b.strokeTone == tone)
        #expect(a.speed == b.speed && a.horizontalBias == b.horizontalBias)
    }

    @Test("the movement tracker ignores jitter below the minimum step and keeps the last direction")
    func movementTracker() {
        var t = StrokeMovementTracker()
        let g: CGFloat = 0.15
        #expect(t.movement(to: CGPoint(x: 0.5, y: 0.5), aspect: 1, gateRadius: g) == nil)
        #expect(t.movement(to: CGPoint(x: 0.501, y: 0.5), aspect: 1, gateRadius: g) == nil)
        let fwd = t.movement(to: CGPoint(x: 0.52, y: 0.5), aspect: 1, gateRadius: g)
        #expect(fwd != nil && fwd!.dx > 0)
        #expect(t.movement(to: CGPoint(x: 0.5205, y: 0.5), aspect: 1, gateRadius: g) == fwd, "jitter replaced the direction")
        let back = t.movement(to: CGPoint(x: 0.49, y: 0.5), aspect: 1, gateRadius: g)
        #expect(back != nil && back!.dx < 0)
        t.reset()
        #expect(t.movement(to: CGPoint(x: 0.3, y: 0.3), aspect: 1, gateRadius: g) == nil)
    }

    /// R19 (review N10). The tracker is driven the way the touch path drives it: `penMoved` on a kept sample,
    /// `movement` on every sample, with the stall cutoff (0.3 s here).
    @Test("a pen that has stopped moving has no direction; one still moving keeps it")
    func stoppedPenForgetsItsDirection() {
        let g: CGFloat = 0.15, stall: TimeInterval = 0.3
        var t = StrokeMovementTracker()
        func sample(_ x: CGFloat, at time: CFTimeInterval, moved: Bool) -> CGVector? {
            if moved { t.penMoved(at: time, stallSeconds: stall) }
            return t.movement(to: CGPoint(x: x, y: 0.5), aspect: 1, gateRadius: g, at: time, stallSeconds: stall)
        }
        _ = sample(0.50, at: 0.00, moved: true)
        let fwd = sample(0.54, at: 0.05, moved: true)
        #expect(fwd != nil && fwd!.dx > 0)
        let back = sample(0.50, at: 0.10, moved: true)
        #expect(back != nil && back!.dx < 0)
        // Held still: samples that moved nothing. Inside the stall cutoff the reversal is still the direction ...
        #expect(sample(0.50, at: 0.30, moved: false) == back, "forgotten before the stall cutoff")
        // ... from the cutoff on the pen has no direction.
        #expect(sample(0.50, at: 0.41, moved: false) == nil, "a stopped pen kept its reversal")
        #expect(sample(0.50, at: 0.90, moved: false) == nil)
        // It starts again: the new direction is its own, never the stale reversal.
        #expect(sample(0.5005, at: 1.00, moved: true) == nil, "a resumed pen read the stale direction")
        let again = sample(0.54, at: 1.05, moved: true)
        #expect(again != nil && again!.dx > 0, "the resumed pen's direction is not its own: \(String(describing: again))")
    }

    @Test("slow movement is not a stop: a kept sample inside every stall window keeps the direction")
    func slowMovementKeepsItsDirection() {
        let g: CGFloat = 0.15, stall: TimeInterval = 0.3
        var t = StrokeMovementTracker()
        t.penMoved(at: 0, stallSeconds: stall)
        _ = t.movement(to: CGPoint(x: 0.5, y: 0.5), aspect: 1, gateRadius: g, at: 0, stallSeconds: stall)
        t.penMoved(at: 0.05, stallSeconds: stall)
        let back = t.movement(to: CGPoint(x: 0.46, y: 0.5), aspect: 1, gateRadius: g, at: 0.05, stallSeconds: stall)
        #expect(back != nil && back!.dx < 0)
        // 4 s at 0.25 s per kept sample, each far below one step (0.1 x gate): the reversal stays.
        for i in 1...16 {
            let time = 0.05 + 0.25 * Double(i)
            t.penMoved(at: time, stallSeconds: stall)
            let m = t.movement(to: CGPoint(x: 0.46 - 0.0005 * Double(i), y: 0.5), aspect: 1, gateRadius: g,
                               at: time, stallSeconds: stall)
            #expect(m == back, "slow reverse movement lost its direction at sample \(i)")
        }
    }
}

// MARK: - Seam B

@Suite("R18 stroke tone stamp (seam B)") @MainActor
struct StrokeToneStampTests {
    @Test("each switch is named when non-default; nothing at defaults; reset restores both")
    func stamp() {
        #expect(StudyComparisonConfiguration.defaults.nonDefaultStamp == nil)
        var c = StudyComparisonConfiguration.defaults
        c.distanceToneEnabled = true
        #expect(c.nonDefaultStamp == "distanceToneEnabled=true", "got \(c.nonDefaultStamp ?? "nil")")
        c = .defaults
        c.directionMuteEnabled = true
        #expect(c.nonDefaultStamp == "directionMuteEnabled=true", "got \(c.nonDefaultStamp ?? "nil")")
        c.distanceToneEnabled = true
        #expect(c.nonDefaultStamp == "distanceToneEnabled=true;directionMuteEnabled=true")
    }

    @Test("both keys round-trip through a store and resetToDefaults removes them")
    func storeRoundTrip() throws {
        let suite = "r18s45.\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        #expect(!StudyComparisonSettings.configuration(in: d).distanceToneEnabled)
        d.set(true, forKey: StudyComparisonSettings.distanceToneEnabledKey)
        d.set(true, forKey: StudyComparisonSettings.directionMuteEnabledKey)
        let c = StudyComparisonSettings.configuration(in: d)
        #expect(c.distanceToneEnabled && c.directionMuteEnabled)
        #expect(StudyComparisonSettings.resetToDefaults(in: d), "the reset reported no change")
        #expect(StudyComparisonSettings.configuration(in: d) == .defaults)
    }

    @Test("a session's stamp carries the switches it captured")
    func sessionStamp() {
        var deps = TracingDependencies.stub
        deps.distanceToneEnabled = true
        deps.directionMuteEnabled = true
        let vm = TracingViewModel(deps)
        #expect(vm.comparisonConfigurationStamp == "distanceToneEnabled=true;directionMuteEnabled=true")
        #expect(TracingViewModel(.stub).comparisonConfigurationStamp == nil)
    }
}

// MARK: - Seam C

@Suite("R18 stroke tone kernel render (seam C)")
nonisolated struct StrokeToneKernelTests {
    static let sr = LiveSonificationKernel.sampleRate

    /// Renders the carrier with `setup` applied after the sound is up; returns the last 0.3 s.
    private func steady(_ setup: (LiveSonificationKernel) -> Void) throws -> [Float] {
        let rig = LiveSonificationKernelTests.Rig(sources: [try StudySources.load("spatial_carrier")])
        rig.kernel.open(slot: rig.slots["spatial_carrier"]!, fadeInFrames: 0)
        _ = rig.render(0.3)
        setup(rig.kernel)
        let y = rig.render(0.7)
        return Array(y[Int(0.4 * Self.sr)...])
    }

    private func rms(_ y: [Float]) -> Double { SonificationMetrics.rms(y[...]) }

    @Test("defaults are bit-identical to a kernel that never heard of the tone stage")
    func defaultsBitIdentical() throws {
        let a = try steady { _ in }
        let b = try steady { k in k.setStrokeLevel(gainDB: 0); k.setStrokeLowpass(cutoffHz: StrokeTone.bypassHz); k.setStrokeMute(false) }
        #expect(a == b)
        #expect(rms(a) > 0.01, "the carrier did not sound")
    }

    @Test("level -12 dB renders at a quarter of the amplitude")
    func level() throws {
        let ref = rms(try steady { _ in })
        let low = rms(try steady { $0.setStrokeLevel(gainDB: -12) })
        #expect(abs(low / ref - 0.2512) < 0.01, "ratio \(low / ref)")
    }

    @Test("a low-pass at 800 Hz lowers a bright sound's level; 20 kHz does not")
    func lowpass() throws {
        let ref = rms(try steady { _ in })
        let dark = rms(try steady { $0.setStrokeLowpass(cutoffHz: 150) })
        let open = rms(try steady { $0.setStrokeLowpass(cutoffHz: 20_000) })
        #expect(dark < ref * 0.8, "a 150 Hz low-pass left \(dark / ref) of the level")
        #expect(open == ref)
    }

    @Test("half a gate radius (-6 dB, ~4 kHz) renders lower than on the stroke; far lower still")
    func distanceOrdering() throws {
        let on = rms(try steady { _ in })
        let half = rms(try steady { $0.setStrokeLevel(gainDB: -6); $0.setStrokeLowpass(cutoffHz: 4000) })
        let far = rms(try steady { $0.setStrokeLevel(gainDB: -12); $0.setStrokeLowpass(cutoffHz: 800) })
        #expect(half < on * 0.55 && far < half, "on \(on) half \(half) far \(far)")
    }

    @Test("mute silences the voice without closing the gate, and the sound returns when unmuted")
    func mute() throws {
        let rig = LiveSonificationKernelTests.Rig(sources: [try StudySources.load("spatial_carrier")])
        rig.kernel.open(slot: rig.slots["spatial_carrier"]!, fadeInFrames: 0)
        let before = rig.render(0.3)
        rig.kernel.setStrokeMute(true)
        _ = rig.render(0.3)
        let muted = rig.render(0.2)
        #expect(muted.allSatisfy { abs($0) < 1e-3 }, "peak \(muted.map(abs).max() ?? 0) while muted")
        #expect(rig.kernel.isSounding && rig.kernel.gateRequested, "the mute closed the gate")
        rig.kernel.setStrokeMute(false)
        _ = rig.render(0.3)
        let after = rig.render(0.2)
        #expect(rms(after) > 0.8 * rms(Array(before[Int(0.1 * Self.sr)...])), "the sound did not come back")
    }

    @Test("the change is smoothed: no buffer-to-buffer step larger than the signal itself")
    func smoothed() throws {
        let rig = LiveSonificationKernelTests.Rig(sources: [try StudySources.load("spatial_carrier")])
        rig.kernel.open(slot: rig.slots["spatial_carrier"]!, fadeInFrames: 0)
        let pre = rig.render(0.3)
        rig.kernel.setStrokeMute(true)
        let post = rig.render(0.1)
        let all = pre + post
        let peak = Double(pre.map(abs).max() ?? 1)
        var maxStep = 0.0
        for i in Int(0.29 * Self.sr)..<all.count - 1 { maxStep = max(maxStep, Double(abs(all[i + 1] - all[i]))) }
        #expect(maxStep < peak * 0.5, "a step of \(maxStep) against a peak of \(peak) = a click")
    }
}

// MARK: - Touch-path wiring (the "is it inert?" check)

@MainActor
fileprivate final class ToneRecordingAudio: AudioControlling {
    var initializationError: String? { nil }
    private(set) var levels: [Float] = []
    private(set) var cutoffs: [Float] = []
    private(set) var mutes: [Bool] = []
    private(set) var rateCalls = 0
    func loadAudioFile(named: String, autoplay: Bool) {}
    func play() {}
    func stop() {}
    func restart() {}
    func suspendForLifecycle() {}
    func resumeAfterLifecycle() {}
    func cancelPendingLifecycleWork() {}
    func setAdaptivePlayback(speed: Float, horizontalBias: Float) { rateCalls += 1 }
    func setStrokeLevel(gainDB: Float) { levels.append(gainDB) }
    func setStrokeLowpass(cutoffHz: Float) { cutoffs.append(cutoffHz) }
    func setStrokeMute(_ muted: Bool) { mutes.append(muted) }
}

@Suite("R18 stroke tone on the pen's touch path", .serialized) @MainActor
struct StrokeToneTouchPathTests {
    private let canvas = CGSize(width: 400, height: 400)

    private func makeVM(distance: Bool, direction: Bool, arm: PilotAudioCondition = .phoneme)
        -> (TracingViewModel, ToneRecordingAudio) {
        let audio = ToneRecordingAudio()
        var deps = TracingDependencies.stub.with(audioCondition: arm).with(audio: audio)
        deps.distanceToneEnabled = distance
        deps.directionMuteEnabled = direction
        let vm = TracingViewModel(deps)
        // Lay the canvas out BEFORE loading the test definition: the first
        // `updateTouch` with a different `canvasSize` sets `vm.canvasSize`,
        // whose didSet re-flows the grid and RELOADS the current letter's
        // checkpoints — which discarded this test's definition and measured
        // the stub letter's radius instead (found in the integration run:
        // -2 dB / 11.7 kHz instead of -6 dB / 4 kHz).
        vm.canvasSize = canvas
        // A horizontal stroke through y = 0.5, written left to right; gate radius 0.1 x 3 = 0.3.
        vm.strokeTracker.load(LetterStrokes(letter: "T", checkpointRadius: 0.1, strokes: [
            StrokeDefinition(id: 1, checkpoints: (0...16).map { Checkpoint(x: 0.1 + 0.05 * CGFloat($0), y: 0.5) })
        ]))
        return (vm, audio)
    }

    /// Drags in 10 pt steps at height `y` from `x0` by `dx` per step.
    private func drag(_ vm: TracingViewModel, y: CGFloat, x0: CGFloat, dx: CGFloat) {
        let t0: CFTimeInterval = 1000
        vm.beginTouch(at: CGPoint(x: x0, y: y), t: t0)
        var t = t0
        var p = CGPoint(x: x0, y: y)
        for _ in 0..<15 { t += 0.001; p.x += dx; vm.updateTouch(at: p, t: t, canvasSize: canvas) }
    }

    @Test("both switches off: the pen writes no tone (r17)")
    func offWritesNothing() {
        let (vm, audio) = makeVM(distance: false, direction: false)
        drag(vm, y: 200, x0: 50, dx: 10)
        #expect(audio.rateCalls > 0, "the coupling did not run: the test measures nothing")
        #expect(audio.levels.isEmpty && audio.cutoffs.isEmpty && audio.mutes.isEmpty)
    }

    @Test("distance on: on the stroke 0 dB / no filter, half a gate radius off it quieter and darker")
    func distanceReachesTheVoice() {
        let (on, onAudio) = makeVM(distance: true, direction: false)
        drag(on, y: 200, x0: 50, dx: 10)
        #expect(!onAudio.levels.isEmpty && onAudio.levels.allSatisfy { abs($0) < 0.05 })
        #expect(onAudio.cutoffs.allSatisfy { $0 >= StrokeTone.bypassHz - 1 })
        let (off, offAudio) = makeVM(distance: true, direction: false)
        drag(off, y: 260, x0: 50, dx: 10)               // 0.15 = half of the 0.3 gate radius
        #expect(!offAudio.levels.isEmpty && offAudio.levels.allSatisfy { $0 < -5 && $0 > -7 }, "\(offAudio.levels)")
        #expect(offAudio.cutoffs.allSatisfy { $0 < 5000 && $0 > 3000 }, "\(offAudio.cutoffs)")
    }

    @Test("direction on: tracing against the stroke mutes, with it does not; in both sound arms")
    func directionReachesTheVoice() {
        for arm in [PilotAudioCondition.phoneme, .spatial] {
            let (fwd, fwdAudio) = makeVM(distance: false, direction: true, arm: arm)
            drag(fwd, y: 200, x0: 50, dx: 10)
            #expect(!fwdAudio.mutes.isEmpty && !fwdAudio.mutes.contains(true), "\(arm) forwards: \(fwdAudio.mutes)")
            let (back, backAudio) = makeVM(distance: false, direction: true, arm: arm)
            drag(back, y: 200, x0: 350, dx: -10)
            #expect(backAudio.mutes.contains(true), "\(arm) backwards was never muted: \(backAudio.mutes)")
        }
    }

    // MARK: R19 (review N10): the mute belongs to a pen that is moving backwards

    /// A fast reversal along the stroke (x 350 -> 200 at y 200, 1 ms per 10 pt sample), pen still down.
    /// Returns the touch time of its last sample.
    private func reverse(_ vm: TracingViewModel) -> CFTimeInterval {
        let t0: CFTimeInterval = 1000
        vm.beginTouch(at: CGPoint(x: 350, y: 200), t: t0)
        var t = t0
        var p = CGPoint(x: 350, y: 200)
        for _ in 0..<15 { t += 0.001; p.x -= 10; vm.updateTouch(at: p, t: t, canvasSize: canvas) }
        return t
    }

    @Test("direction on: a reversed pen that stops moving is no longer muted")
    func reversedThenStoppedUnmutes() {
        for arm in [PilotAudioCondition.phoneme, .spatial] {
            let (vm, audio) = makeVM(distance: false, direction: true, arm: arm)
            let t = reverse(vm)
            #expect(audio.mutes.last == true, "\(arm): the reversal was not muted, the test measures nothing: \(audio.mutes)")
            let stall = vm.strokeTempo.stallSeconds
            // Held on the spot (a sample that moved nothing): inside the stall cutoff the reversal still counts ...
            vm.updateTouch(at: CGPoint(x: 200, y: 200), t: t + stall * 0.5, canvasSize: canvas)
            #expect(audio.mutes.last == true, "\(arm): unmuted before the pen had stopped: \(audio.mutes)")
            // ... past it the pen has stopped, and a stopped pen is not backwards.
            vm.updateTouch(at: CGPoint(x: 200, y: 200), t: t + stall + 0.05, canvasSize: canvas)
            #expect(audio.mutes.last == false, "\(arm): a stopped pen stayed muted: \(audio.mutes)")
            // Moving forward again is audible, and a new reversal mutes again.
            var p = CGPoint(x: 200, y: 200)
            var time = t + stall + 0.06
            for _ in 0..<10 { time += 0.001; p.x += 10; vm.updateTouch(at: p, t: time, canvasSize: canvas) }
            #expect(audio.mutes.last == false, "\(arm): forwards after the stop was muted: \(audio.mutes)")
            let before = audio.mutes.count
            for _ in 0..<10 { time += 0.001; p.x -= 10; vm.updateTouch(at: p, t: time, canvasSize: canvas) }
            #expect(audio.mutes[before...].contains(true), "\(arm): a second reversal was never muted: \(audio.mutes)")
        }
    }

    @Test("direction on: a reversed pen that keeps moving, slowly, stays muted")
    func reversedAndMovingStaysMuted() {
        for arm in [PilotAudioCondition.phoneme, .spatial] {
            let (vm, audio) = makeVM(distance: false, direction: true, arm: arm)
            var t = reverse(vm)
            var p = CGPoint(x: 200, y: 200)
            let before = audio.mutes.count
            // 4 s at 2 pt per 0.2 s = 10 pt/s, each sample a kept move inside the stall cutoff.
            for _ in 0..<20 { t += 0.2; p.x -= 2; vm.updateTouch(at: p, t: t, canvasSize: canvas) }
            let slow = Array(audio.mutes[before...])
            #expect(slow.count == 20, "the slow samples did not reach the voice: \(slow.count)")
            #expect(slow.allSatisfy { $0 }, "\(arm): a slow backwards pen was unmuted: \(slow)")
        }
    }

    @Test("direction on: the lift after a reversal does not mute the tail")
    func liftAfterReversalIsNotMuted() {
        for arm in [PilotAudioCondition.phoneme, .spatial] {
            let (vm, audio) = makeVM(distance: false, direction: true, arm: arm)
            _ = reverse(vm)
            #expect(audio.mutes.last == true, "\(arm): the reversal was not muted, the test measures nothing")
            vm.endTouch()
            #expect(audio.mutes.last == false, "\(arm): the lift tail stayed muted by a past reversal: \(audio.mutes)")
        }
    }

    @Test("direction off: a reversal and a lift write no mute at all, distance alone never mutes")
    func switchOffIsUnchanged() {
        let (off, offAudio) = makeVM(distance: false, direction: false)
        _ = reverse(off)
        off.endTouch()
        #expect(offAudio.rateCalls > 0, "the coupling did not run: the test measures nothing")
        #expect(offAudio.mutes.isEmpty, "both switches off wrote a mute: \(offAudio.mutes)")
        let (dist, distAudio) = makeVM(distance: true, direction: false)
        _ = reverse(dist)
        dist.endTouch()
        #expect(!distAudio.mutes.isEmpty && !distAudio.mutes.contains(true), "distance alone muted: \(distAudio.mutes)")
    }
}
