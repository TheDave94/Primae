// SoundEnvelope.swift
// PrimaeNative
//
// THE SOUND ARMS' ENVELOPE, in one place (supervisor ruling 2026-10-05,
// after David's own test of the pilot build; protocol revision 5). Retune
// any value here, in one line. Deliberately NOT a
// `StudyComparisonSettings` switch: this is the protocol, not a comparison
// axis, and a change to it is a `StudyProtocol` revision.
//
// Applies to every writing phase in both sound arms (guided, free-writing,
// the cold probes). The silent arm never reaches the engine (`SilentAudio`).

import AVFoundation
import Foundation
import os

enum SoundEnvelope {
    /// Linear fade-out applied by the engine's `stop()`. Was 0.12 s
    /// (`AudioEngine.fadeOutSeconds` default). Set at the engine's
    /// construction site — `AudioEngine.swift` is not edited.
    static let fadeOutSeconds: TimeInterval = 0.4
    /// A pen that stops moving (still touching) keeps sounding this long
    /// before the stall idle fires. Was 0.12 s
    /// (`PlaybackController.idleDebounceSeconds` default).
    static let stallSeconds: TimeInterval = 0.3
    /// ENV3 (2026-11-05, David: "fade immediately on end point of letters"): the fade when the letter's LAST stroke reaches its
    /// end, a raised cosine. Chosen by the 30/50/80 ms sweep (env3/fadesweep.txt, ENV3.md). The stall / hold-expiry stop keeps
    /// `fadeOutSeconds`.
    static let letterEndFadeSeconds: TimeInterval = 0.050
    /// After a LIFT the sound keeps playing this long; a re-touch inside
    /// the hold cancels the stop, so the sound does not cut between
    /// strokes. Was 0 (a lift stopped at once). From protocol r17 (RULINGS
    /// 2026-11-05) this is the SEED of the per-child adaptive hold
    /// (`StrokeTempo`): what a child hears until their own gaps are known.
    static let liftHoldSeconds: TimeInterval = 0.8

    /// Preferred I/O buffer, seconds (protocol r17; LAT.md candidate C1).
    /// The default 1024 frames (21.3 ms) was one of the two terms of the
    /// r16 onset; 5 ms is honoured on the study iPad as 256 frames (5.33 ms,
    /// measured). Session-wide: prompts and TTS share it.
    static let preferredIOBufferSeconds: TimeInterval = 0.005

    /// The production arm sound (protocol r17): the r16 `AudioEngine` as the
    /// session/mixer host, with the live grain voice (`LiveSonificationAudio`)
    /// attached to its graph. The IO buffer is set BEFORE the engine exists,
    /// so its first start already runs at 5 ms. `AudioEngine.swift` changes by
    /// graph wiring only (`attachLiveSonificationNode`).
    static func makeAudioEngine() -> AudioControlling {
        let voice: AudioControlling = LiveSonificationAudio.production(host: makeHostEngine(), fadeOutSeconds: fadeOutSeconds)
        #if DEBUG || POPCAP
        return PopCaptureAudio.wrap(voice)   // POPCAP: logs the commands; a no-op without -popCapture
        #else
        return voice
        #endif
    }

    /// The r16 engine alone, with the envelope's fade and the r17 IO buffer:
    /// the host of the live voice, and what the r16 device pins
    /// (`AudioEngineRenderPinTests`) still drive directly.
    static func makeHostEngine() -> AudioEngine {
        applyPreferredIOBuffer()
        let engine = AudioEngine()
        engine.fadeOutSeconds = fadeOutSeconds
        return engine
    }

    /// The buffer to ask for on a route (lane POP2, 2026-11-04): 5 ms on the built-in speaker and wired routes; nil
    /// (the system default, `setPreferredIOBufferDuration(0)`) when ANY output is Bluetooth (A2DP, HFP or LE): the
    /// radio path adds ~150-250 ms of its own, so a 5 ms buffer buys no onset there and costs a callback every 5 ms.
    static func ioBufferRequest(outputs: [AVAudioSession.Port]) -> TimeInterval? {
        let bluetooth: Set<AVAudioSession.Port> = [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE]
        return outputs.contains(where: bluetooth.contains) ? nil : preferredIOBufferSeconds
    }

    /// Applies the route's request and returns (route description, requested seconds or nil, effective seconds).
    /// Called before the engine exists and again on every route change (`LiveSonificationAudio.handleRouteChange`).
    @discardableResult
    static func applyPreferredIOBuffer(_ session: AVAudioSession = .sharedInstance()) -> (route: String, requested: TimeInterval?, effective: TimeInterval) {
        let outputs = session.currentRoute.outputs
        let want = ioBufferRequest(outputs: outputs.map(\.portType))
        do { try session.setPreferredIOBufferDuration(want ?? 0) } catch {
            // Not fatal: the session keeps its buffer and the onset is one buffer later (LAT.md: C1 alone is -65 ms).
        }
        let route = outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        let effective = session.ioBufferDuration
        Logger(subsystem: Bundle.main.bundleIdentifier ?? "PrimaeNative", category: "SoundEnvelope")
            .info("io buffer route=\(route, privacy: .public) requested=\(want.map { String($0) } ?? "default", privacy: .public) effective=\(effective)")
        #if DEBUG || POPCAP
        PopCapture.armed?.event("session.iobuffer", "route=\(route) requested=\(want.map { String($0) } ?? "default") effective=\(effective)")
        #endif
        return (route, want, effective)
    }
}

/// A child's writing tempo as the sound envelope sees it (protocol r17, RULINGS 2026-11-05): the lift-to-next-touch gaps
/// between strokes. The hold that keeps the sound going across a lift is `clamp(k x running median of the recent gaps)`,
/// seeded from the fixed 0.8 s of r5-r16 so a child's first strokes hear what the pilot heard. Pure value type; the
/// numbers (k 2.0, window 5, 2 seed gaps, 0.5 to 2.5 s) come from `env3/holdsim.txt` (ENV3.md).
struct StrokeTempo: Equatable {
    static let k = 2.0
    static let window = 5
    static let seedCount = 2
    static let minHold: TimeInterval = 0.5
    static let maxHold: TimeInterval = 2.5
    /// A lift-to-touch gap longer than this is a break, not a transition between strokes: not measured.
    static let maxGap: TimeInterval = 3.0
    /// The stall cutoff scales with the hold's ratio to the seed, never below today's 0.3 s, never above 0.6 s.
    static let minStall: TimeInterval = 0.3
    static let maxStall: TimeInterval = 0.6

    /// The recent gaps (seed copies first), at most `window` of them.
    private(set) var gaps: [TimeInterval]
    /// Gaps actually measured (seed copies excluded) since the child was enrolled.
    private(set) var measured = 0

    init() { gaps = Array(repeating: SoundEnvelope.liftHoldSeconds / Self.k, count: Self.seedCount) }

    /// Records one gap; false when it was a break and was ignored.
    @discardableResult
    mutating func record(gap: TimeInterval) -> Bool {
        guard gap.isFinite, gap > 0, gap <= Self.maxGap else { return false }
        gaps.append(gap)
        if gaps.count > Self.window { gaps.removeFirst(gaps.count - Self.window) }
        measured += 1
        return true
    }

    /// Median of the gaps in force (seed copies included while they last).
    var medianGap: TimeInterval {
        let s = gaps.sorted(), n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    var holdSeconds: TimeInterval { min(Self.maxHold, max(Self.minHold, Self.k * medianGap)) }
    var stallSeconds: TimeInterval {
        min(Self.maxStall, max(Self.minStall, SoundEnvelope.stallSeconds * holdSeconds / SoundEnvelope.liftHoldSeconds))
    }
}
