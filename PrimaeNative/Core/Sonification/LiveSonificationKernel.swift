// LiveSonificationKernel.swift
// PrimaeNative
//
// THE RENDER-THREAD HALF of the live sonification voice (protocol r17,
// 2026-11-03). `LiveSonificationAudio` (main actor) decides WHAT should
// sound; this kernel makes it sound, inside the `AVAudioSourceNode` render
// block, by driving the TDPSOLA renderers (RULINGS 2026-11-03: engine A is
// final; engine B and the A/B switch are gone).
//
// WHY A KERNEL AND NOT `play()`/`stop()` ON A PLAYER. The r16 path started an
// `AVAudioPlayerNode` through `AVAudioUnitTimePitch` on every stroke: ~100 ms
// to start a stopped player plus the unit's 93 ms latency (LAT.md, 230-270 ms
// first move -> audible). Here the renderer is a pure-DSP grain engine whose
// gate opens on the first sample of the next render call, so the stroke's
// onset is one I/O buffer away.
//
// What the kernel owns (the envelope the r16 engine applied with
// `player.volume`): the per-file loudness gain (AE-2), the stop fade-out
// (`SoundEnvelope.fadeOutSeconds`, linear, as before), the optional fade-in of
// a demonstration (`play(fadeInSeconds:)`), and the transitions. The pan is
// the main mixer's (`AVAudioMixing.pan` on the mono node), which slews a change
// over ~25 ms itself (measured on the iPad, LoopXMixerPanTests).
//
// TWO VOICES (lane LOOPX, 2026-11-03; LOOPX.md). Every gate-open restarts the
// sound at its attack (as r16's `prepareCurrentTrack` did). A gate-open from
// SILENCE starts one voice exactly as before. A gate-open while something is
// still sounding (a stop fade, a held sound, a letter switch) used to duck the
// one voice to zero in 3 ms and restart it: a measured dropout/cut at every
// stroke that began inside the 0.4 s stop fade. Now the new voice starts at its
// attack on the slot's second renderer while the old voice keeps going and the
// two cross over with an equal-power curve over `crossfadeSeconds`. A third
// gate-open inside a running crossover waits for it to end (at most
// `crossfadeSeconds`), so no voice is ever cut. `close(fadeOutFrames: 0)` (a
// switch to another file while sounding, a background, an interruption) fades
// with a quarter-cosine over `duckSeconds` instead of 3 ms linear.
//
// Real-time contract: `render` allocates nothing, takes no lock and touches no
// Swift array, existential or retained reference. Renderers sit in fixed
// tables of `Unmanaged<TDPSOLA>` (two per slot) and are called through
// `_withUnsafeGuaranteedRef`. Main-thread commands are `Synchronization.Atomic`
// cells; the play token and the gate are published with release ordering after
// the slot and fade values, and read with acquire ordering, so a slot the
// render thread starts is always a registered one. Registered renderers are
// never removed (the study's five phonemes and the carrier, per process).

import Foundation
import Synchronization

nonisolated final class LiveSonificationKernel: @unchecked Sendable {

    /// The renderers' (and the source node's) sample rate. The assets are
    /// 44.1 kHz mono (measured: all five phonemes and the carrier); the main
    /// mixer converts to the hardware rate (48 kHz on the study iPad).
    static let sampleRate: Double = 44_100
    /// What every r17 phase row's `soundEngine` column carries.
    static let engineStamp = "TDPSOLA"
    /// The renderers are created for this many frames per call; the kernel
    /// splits any larger I/O request into chunks of it.
    static let chunkFrames = 512
    /// Slots in the table (two renderers each).
    static let capacity: UInt32 = 64
    static let noSlot: UInt32 = .max
    /// The three time constants of the kernel's transitions (lane POP2 sweep; POP2.md).
    struct Ramps: Sendable, Equatable {
        /// Raised-cosine onset of a voice that starts from silence (r17 shipped 0: the renderer's own 2 ms linear gate).
        var onsetSeconds: Double
        /// Equal-power crossover of a restart while sounding (LOOPX sweep; POP2 re-sweep).
        var crossfadeSeconds: Double
        /// Fade of `close(fadeOutFrames: 0)` (LOOPX sweep; was a 3 ms linear duck).
        var duckSeconds: Double
        /// A restart while the same sound still sounds continues that voice (no second copy, no crossover).
        var resumeSameSound: Bool = false
        /// ENV3 (2026-11-05): a pitch command that steps by more than `pitchJumpCents` while a voice sounds (the spatial arm's
        /// stroke that starts far, in y, from where the previous one ended, inside the lift hold: F's second stroke) is glided over
        /// this long instead of followed in the renderer's 2 ms. 0 = off. In-stroke tracking (steps of tens of cents) never reaches it.
        var pitchGlideSeconds: Double = 0
        var pitchJumpCents: Float = 300
        /// r17 as shipped before POP2 (2 ms gate only, 20 ms crossover, 20 ms duck): the sweep's baseline.
        static let r17 = Ramps(onsetSeconds: 0, crossfadeSeconds: 0.020, duckSeconds: 0.020)
        /// POP2 production values (chosen from the device-capture sweep; pinned by `PopOnsetRegressionTests`).
        static let production = Ramps(onsetSeconds: 0.008, crossfadeSeconds: 0.020, duckSeconds: 0.020, resumeSameSound: true,
                                      pitchGlideSeconds: ENV3Tuning.pitchGlideSeconds)
    }
    static let crossfadeSeconds = Ramps.production.crossfadeSeconds
    static let duckSeconds = Ramps.production.duckSeconds
    static let onsetSeconds = Ramps.production.onsetSeconds

    static let crossfadeFrames = Float((crossfadeSeconds * sampleRate).rounded())
    static let duckFrames = Float((duckSeconds * sampleRate).rounded())

    let ramps: Ramps
    private let crossFrames: Float
    private let duckLen: Float
    private let onsetFrames: Float
    private let glideFrames: Int
    private let jumpCents: Float

    // MARK: Tables (written on the main thread before publication)

    /// Renderer `v` of slot `s` is at `renderers[2 * s + v]`.
    private let renderers: UnsafeMutablePointer<Unmanaged<TDPSOLA>?>
    private let gains: UnsafeMutablePointer<Float>
    private var registered: UInt32 = 0

    // MARK: Commands (main -> render)

    private let wantSlot = Atomic<UInt32>(LiveSonificationKernel.noSlot)
    private let wantOpen = Atomic<UInt32>(0)
    private let playToken = Atomic<UInt32>(0)
    private let fadeInFrames = Atomic<UInt32>(0)
    private let fadeOutFrames = Atomic<UInt32>(0)
    /// ENV3: 1 = the pending close is a raised-cosine fade over `fadeOutFrames` (the letter-end fade), 0 = the linear fade / duck.
    private let fadeRaised = Atomic<UInt32>(0)
    private let rateBits = Atomic<UInt32>(Float(1).bitPattern)
    private let centsBits = Atomic<UInt32>(Float(0).bitPattern)

    // MARK: Status (render -> main, tests)

    private let soundingBits = Atomic<UInt32>(0)
    private let startCount = Atomic<UInt32>(0)

    // MARK: Render-thread state

    private struct Voice {
        var active = false
        var slot: UInt32 = LiveSonificationKernel.noSlot
        var gain: Float = 1
        var env: Float = 0          // linear envelope: fade-in, stop fade, duck
        var envTarget: Float = 0
        var envStep: Float = 0
        var closing = false
        var shape: Float = 1        // quarter-cosine/sine crossover factor, or the raised-cosine onset
        var shapePos: Float = 0     // 0...shapeLen
        var raisedFall = false      // the falling shape is a raised cosine (ENV3 letter-end fade)
        var shapeDir: Int8 = 0      // +1 rising (incoming), -1 falling (outgoing), 0 none
        var shapeLen: Float = LiveSonificationKernel.crossfadeFrames
        var raised = false          // rising shape is the raised cosine of an onset from silence (not the crossover sine)
    }
    private let voices: UnsafeMutablePointer<Voice>
    private var current = 0          // the voice the main thread's commands address
    private var appliedToken: UInt32 = 0
    private var restartPending = false
    private let scratch: UnsafeMutablePointer<Float>
    // The pitch the voices render with, and the stroke-start glide (ENV3).
    private var pitchApplied: Float = 0
    private var pitchPrevTarget: Float = 0
    private var glideFrom: Float = 0
    private var glidePos = 0
    private var glideLen = 0         // 0 = no glide running
    static let glideSubBlock = 64
    #if DEBUG || POPCAP
    private let cap = PopCapture.armed   // POPCAP: render-thread event ring; nil unless -popCapture
    #endif

    init(ramps: Ramps = .production) {
        self.ramps = ramps
        crossFrames = Float((ramps.crossfadeSeconds * Self.sampleRate).rounded())
        duckLen = Float((ramps.duckSeconds * Self.sampleRate).rounded())
        onsetFrames = Float((ramps.onsetSeconds * Self.sampleRate).rounded())
        glideFrames = Int((ramps.pitchGlideSeconds * Self.sampleRate).rounded())
        jumpCents = ramps.pitchJumpCents
        let n = Int(Self.capacity)
        renderers = .allocate(capacity: 2 * n); renderers.initialize(repeating: nil, count: 2 * n)
        gains = .allocate(capacity: n); gains.initialize(repeating: 1, count: n)
        voices = .allocate(capacity: 2); voices.initialize(repeating: Voice(), count: 2)
        scratch = .allocate(capacity: Self.chunkFrames); scratch.initialize(repeating: 0, count: Self.chunkFrames)
    }

    deinit {
        for i in 0..<(2 * Int(Self.capacity)) { renderers[i]?.release() }
        renderers.deallocate(); gains.deallocate()
        voices.deinitialize(count: 2); voices.deallocate()
        scratch.deallocate()
    }

    // MARK: Registration (main thread)

    /// Adds a slot: two renderers of the SAME source (the second is the voice
    /// a restart crosses over to). Nil when the table is full.
    func register(_ r: TDPSOLA, twin: TDPSOLA, gain: Float) -> UInt32? {
        guard registered < Self.capacity else { return nil }
        let i = registered
        renderers[2 * Int(i)] = Unmanaged.passRetained(r)
        renderers[2 * Int(i) + 1] = Unmanaged.passRetained(twin)
        gains[Int(i)] = gain
        registered += 1
        return i
    }

    // MARK: Commands (main thread)

    /// Open the gate on `slot`: restart at the source's attack (crossing over
    /// from whatever still sounds), ramping in over `fadeInFrames`
    /// (0 = the renderer's own click-free onset).
    func open(slot: UInt32, fadeInFrames fi: UInt32) {
        wantSlot.store(slot, ordering: .relaxed)
        fadeInFrames.store(fi, ordering: .relaxed)
        wantOpen.store(1, ordering: .releasing)
        playToken.wrappingAdd(1, ordering: .releasing)
    }

    /// Close the gate with a linear fade over `fadeOutFrames` (0 = the duck).
    func close(fadeOutFrames fo: UInt32) {
        fadeOutFrames.store(fo, ordering: .relaxed)
        fadeRaised.store(0, ordering: .relaxed)
        wantOpen.store(0, ordering: .releasing)
    }

    /// ENV3 (2026-11-05): close the gate with a RAISED-COSINE fade over `frames` (zero slope at both ends: no kink at the start,
    /// none at the end). The letter-end fade; the stall / hold-expiry stop keeps `close(fadeOutFrames:)`.
    func closeRaisedCosine(frames: UInt32) {
        fadeOutFrames.store(max(1, frames), ordering: .relaxed)
        fadeRaised.store(1, ordering: .relaxed)
        wantOpen.store(0, ordering: .releasing)
    }

    func setRate(_ rate: Float) {
        rateBits.store((rate.isFinite ? min(2, max(0.5, rate)) : 1).bitPattern, ordering: .relaxed)
    }

    func setPitchCents(_ cents: Float) {
        centsBits.store((cents.isFinite ? min(1200, max(-1200, cents)) : 0).bitPattern, ordering: .relaxed)
    }

    var isSounding: Bool { soundingBits.load(ordering: .relaxed) != 0 }
    var starts: UInt32 { startCount.load(ordering: .relaxed) }
    var gateRequested: Bool { wantOpen.load(ordering: .relaxed) != 0 }
    var requestedSlot: UInt32 { wantSlot.load(ordering: .relaxed) }
    var requestedRate: Float { Float(bitPattern: rateBits.load(ordering: .relaxed)) }
    var requestedCents: Float { Float(bitPattern: centsBits.load(ordering: .relaxed)) }

    // MARK: Render (render thread)

    /// Renders `frames` (any count; split into chunks). Returns true when the
    /// whole buffer is silence (the node's `isSilence`).
    @discardableResult
    func render(into out: UnsafeMutablePointer<Float>, frames: Int) -> Bool {
        var done = 0, silent = true
        while done < frames {
            let n = min(Self.chunkFrames, frames - done)
            if !renderMono(into: out + done, frames: n) { silent = false }
            done += n
        }
        return silent
    }

    /// One chunk (<= chunkFrames). Returns true when it is silence.
    private func renderMono(into out: UnsafeMutablePointer<Float>, frames n: Int) -> Bool {
        applyCommands()
        out.update(repeating: 0, count: n)
        var any = false
        // `while`, not `for ... in 0..<n`: at -Onone a Range iterator's `next`
        // runs through a coroutine whose frame is malloc'd (swift_coroFrameAlloc),
        // one allocation per iteration in Debug-Study (measured on the iPad:
        // 2,496,860 in the test's 4000 renders). Release inlines it; Debug does not.
        let target = Float(bitPattern: centsBits.load(ordering: .relaxed))
        trackPitchJump(target)
        if glideLen == 0 {
            pitchApplied = target
            any = renderVoices(into: out, frames: n)
        } else {
            // A stroke-start pitch jump is running: render in small sub-blocks, each at the next point of the glide.
            var off = 0
            while off < n {
                let m = min(Self.glideSubBlock, n - off)
                if glideLen > 0 {
                    glidePos += m
                    if glidePos >= glideLen { glideLen = 0; pitchApplied = target }
                    else {
                        let s = Float(glidePos) / Float(glideLen)
                        pitchApplied = glideFrom + (target - glideFrom) * (0.5 - 0.5 * cos(Float.pi * s))
                    }
                } else { pitchApplied = target }
                if renderVoices(into: out + off, frames: m) { any = true }
                off += m
            }
        }
        if restartPending && !(voices[0].active && voices[1].active) { begin() }
        soundingBits.store(voices[0].active || voices[1].active ? 1 : 0, ordering: .relaxed)
        return !any
    }

    /// Renders both voices into `out` at `pitchApplied`; true when either sounded.
    private func renderVoices(into out: UnsafeMutablePointer<Float>, frames n: Int) -> Bool {
        var any = false, v = 0
        while v < 2 {
            if voices[v].active { any = true; renderVoice(v, adding: out, frames: n) }
            v += 1
        }
        return any
    }

    /// Starts a glide when the pitch target steps by more than `jumpCents` while something sounds; with nothing
    /// sounding the pitch simply is the target (a stroke from silence starts at its pitch, as before).
    private func trackPitchJump(_ target: Float) {
        if !(voices[0].active || voices[1].active) {
            pitchApplied = target; pitchPrevTarget = target; glideLen = 0
            return
        }
        if glideFrames > 0, abs(target - pitchPrevTarget) > jumpCents {
            glideFrom = pitchApplied; glidePos = 0; glideLen = glideFrames
        }
        pitchPrevTarget = target
    }

    private func applyCommands() {
        let token = playToken.load(ordering: .acquiring)
        let open = wantOpen.load(ordering: .acquiring) != 0
        if token != appliedToken {
            appliedToken = token
            if open { restartPending = true }
        }
        if !open {
            restartPending = false
            let cv = current
            if voices[cv].active && !voices[cv].closing {
                let fo = Float(fadeOutFrames.load(ordering: .relaxed))
                if fo > 0 && fadeRaised.load(ordering: .relaxed) != 0 { fadeRaisedCosine(cv, frames: fo) }
                else if fo > 0 { fadeLinear(cv, frames: fo) } else { fadeCosine(cv) }
            }
        }
        if restartPending && !(voices[0].active && voices[1].active) { begin() }
    }

    /// Starts the requested slot on a free voice; the voice that was current
    /// (if still sounding) becomes the outgoing half of the crossover.
    private func begin() {
        restartPending = false
        let slot = wantSlot.load(ordering: .relaxed)
        guard slot < registered else { return }
        let old = current
        // POP2: a restart while the SAME sound still sounds continues that voice and ramps its level back up over the crossover
        // length, instead of crossing over to a second copy. Two copies of one periodic sound at unrelated phase cancel: measured
        // on the iPad (spatial arm, the carrier: -2 to -16 dB dips at restarts inside the stop fade) and offline over restart
        // phases (carrier worst -12 dB, M -19 dB, I -14 dB, 2 ms frames). The recordings' attack is 8 ms (the files are trimmed at
        // the sound's start), so "restart at the attack" adds only the level step the ramp already gives. A different sound
        // (a letter switch) still crosses over.
        if ramps.resumeSameSound, voices[old].active, voices[old].slot == slot, voices[old].shapeDir <= 0,
           fadeInFrames.load(ordering: .relaxed) == 0 {
            voices[old].closing = false
            voices[old].envTarget = 1
            voices[old].envStep = max((1 - voices[old].env) / max(1, crossFrames), 1e-9)
            startCount.wrappingAdd(1, ordering: .relaxed)
            #if DEBUG || POPCAP
            cap?.kernelEvent(2, a: Int32(slot), x: Double(Float(bitPattern: rateBits.load(ordering: .relaxed))), y: 0, z: Double(old) + 0.25)
            #endif
            return
        }
        let v = voices[old].active ? 1 - old : old
        let fi = Float(fadeInFrames.load(ordering: .relaxed))
        let crossing = voices[old].active
        if crossing { fadeCosine(old, frames: crossFrames) }
        let r = Float(bitPattern: rateBits.load(ordering: .relaxed))
        let cTarget = Float(bitPattern: centsBits.load(ordering: .relaxed))
        if !crossing { pitchApplied = cTarget; pitchPrevTarget = cTarget; glideLen = 0 }
        let c = crossing ? pitchApplied : cTarget
        renderers[2 * Int(slot) + v]!._withUnsafeGuaranteedRef {
            $0.reset(); $0.setRate(r); $0.setPitchCents(c); $0.setGate(true)
        }
        var voice = Voice()
        voice.active = true
        voice.slot = slot
        voice.gain = gains[Int(slot)]
        voice.envTarget = 1
        if fi > 0 { voice.env = 0; voice.envStep = 1 / fi } else { voice.env = 1 }
        if crossing && fi == 0 {
            voice.shape = 0; voice.shapePos = 0; voice.shapeDir = 1; voice.shapeLen = crossFrames
        } else if !crossing && fi == 0 && onsetFrames > 0 {
            // POP2: a voice that starts from silence rises on a raised cosine (no hard attack, no splatter).
            voice.shape = 0; voice.shapePos = 0; voice.shapeDir = 1; voice.shapeLen = onsetFrames; voice.raised = true
        }
        voices[v] = voice
        current = v
        startCount.wrappingAdd(1, ordering: .relaxed)
        #if DEBUG || POPCAP
        cap?.kernelEvent(2, a: Int32(slot), x: Double(r), y: Double(c), z: Double(v) + (crossing ? 0.5 : 0))
        #endif
    }

    /// Raised-cosine fall (0.5 + 0.5 cos) over `frames`, from the level the voice is at now.
    private func fadeRaisedCosine(_ v: Int, frames: Float) {
        voices[v].closing = true
        if voices[v].shapeDir == -1 { return }
        let s = min(1, max(0, voices[v].shape))
        voices[v].shapePos = acos(2 * s - 1) / Float.pi * frames
        voices[v].shapeDir = -1
        voices[v].shapeLen = frames
        voices[v].raisedFall = true
    }

    private func fadeLinear(_ v: Int, frames: Float) {
        voices[v].closing = true
        voices[v].envTarget = 0
        voices[v].envStep = max(voices[v].env / max(1, frames), 1e-9)
    }

    /// Quarter-cosine fade to zero over `frames` (the duck, the crossover's
    /// outgoing half), on top of any linear fade already running.
    private func fadeCosine(_ v: Int, frames: Float? = nil) {
        let frames = frames ?? duckLen
        voices[v].closing = true
        if voices[v].shapeDir == -1 { return }
        // Start the falling quarter-cosine at the level the shape is at now.
        let s = voices[v].shape
        voices[v].shapePos = (acos(min(1, max(0, s))) / (Float.pi / 2)) * frames
        voices[v].shapeDir = -1
        voices[v].shapeLen = frames
    }

    private func renderVoice(_ v: Int, adding out: UnsafeMutablePointer<Float>, frames n: Int) {
        let slot = voices[v].slot
        let r = Float(bitPattern: rateBits.load(ordering: .relaxed))
        let c = pitchApplied
        #if DEBUG || POPCAP
        var headBefore = 0.0
        if cap != nil { headBefore = renderers[2 * Int(slot) + v]!._withUnsafeGuaranteedRef { $0.debugReadHead } }
        #endif
        renderers[2 * Int(slot) + v]!._withUnsafeGuaranteedRef {
            $0.setRate(r); $0.setPitchCents(c); $0.render(into: scratch, frames: n)
        }
        #if DEBUG || POPCAP
        if let cap {
            let head = renderers[2 * Int(slot) + v]!._withUnsafeGuaranteedRef { $0.debugReadHead }
            if head < headBefore - 256 { cap.kernelEvent(3, a: Int32(v), x: Double(r), y: headBefore, z: head) }   // loop wrap
        }
        #endif
        var vc = voices[v]
        let len = vc.shapeLen
        let half = Float.pi / 2
        var i = 0
        while i < n {
            defer { i += 1 }
            if vc.env != vc.envTarget {
                if vc.env < vc.envTarget { vc.env = min(vc.envTarget, vc.env + vc.envStep) }
                else { vc.env = max(vc.envTarget, vc.env - vc.envStep) }
            }
            if vc.shapeDir > 0 {
                vc.shapePos += 1
                if vc.shapePos >= len { vc.shape = 1; vc.shapeDir = 0 }
                else if vc.raised { vc.shape = 0.5 - 0.5 * cos(Float.pi * vc.shapePos / len) }
                else { vc.shape = sin(half * vc.shapePos / len) }
            } else if vc.shapeDir < 0 {
                vc.shapePos += 1
                vc.shape = vc.shapePos >= len ? 0
                    : (vc.raisedFall ? 0.5 + 0.5 * cos(Float.pi * vc.shapePos / len) : cos(half * vc.shapePos / len))
            }
            out[i] += scratch[i] * vc.env * vc.shape * vc.gain
            if (vc.env == 0 && vc.envTarget == 0) || (vc.shapeDir < 0 && vc.shape == 0) {
                renderers[2 * Int(slot) + v]!._withUnsafeGuaranteedRef { $0.setGate(false) }
                #if DEBUG || POPCAP
                cap?.kernelEvent(4, a: Int32(v))
                #endif
                vc = Voice()
                break
            }
        }
        voices[v] = vc
    }
}
