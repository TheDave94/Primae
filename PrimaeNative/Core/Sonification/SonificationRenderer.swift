// SonificationRenderer.swift
// PrimaeNative
//
// The ONE protocol every candidate in the sonification bake-off
// (2026-11-02) implements. The text of the protocol below is copied
// verbatim from the bake-off spec (BAKEOFF.md, "The protocol"); the
// bench (`PrimaeNativeTests/SonificationBakeoff/`) drives every
// registered candidate (`BakeoffCandidates.all`) through it.
//
// Bench conventions a candidate can rely on (they are the harness's,
// not extra protocol requirements):
// - The bench creates a fresh instance per (source, scenario) and calls
//   `reset()` once before rendering.
// - Parameter writes land BETWEEN render calls, at buffer granularity,
//   the way a touch-thread write lands at the next I/O callback.
// - The bench renders in 256-frame buffers; `maxFramesPerRender` is 512.

import Foundation

/// One candidate algorithm. Created and configured OFF the render thread; `render` is called ON it.
/// Every method except `render` and the setters may allocate. The setters and `render` must be real-time safe
/// (no allocation, locks, ARC traffic, actor hops, I/O). The module default isolation is MainActor: conformers and
/// these requirements are `nonisolated`.
nonisolated protocol SonificationRenderer: AnyObject {
    /// Short identifier used in bench output, e.g. "AppleTimePitch-o8", "TDPSOLA".
    static var candidateName: String { get }
    /// `source` is the whole mono source (Float32, -1..1) at `sampleRate`; the renderer loops it.
    /// `kind` tells it whether the source is a voiced phoneme, an unvoiced phoneme, or the tonal carrier.
    init(source: [Float], sampleRate: Double, kind: SourceKind, maxFramesPerRender: Int)
    /// Targets; the renderer smooths internally. Thread-safe, lock-free (written from the touch thread).
    func setRate(_ rate: Float)          // 0.5 ... 2.0, duration scale (2.0 = twice as fast)
    func setPitchCents(_ cents: Float)   // -1200 ... +1200 (0 in the phoneme arm)
    func setGate(_ open: Bool)           // sound on/off; must click-free, onset as fast as possible
    /// Render `frames` mono samples (<= maxFramesPerRender) into `out`. Pan is applied by the caller.
    func render(into out: UnsafeMutablePointer<Float>, frames: Int)
    /// Algorithmic latency the candidate CLAIMS (frames from setGate(true)/parameter change to effect); the bench
    /// measures the truth independently.
    var claimedLatencyFrames: Int { get }
    /// Back to the initial state (gate closed, read position at the source start).
    func reset()
}
nonisolated enum SourceKind: Sendable { case voicedPhoneme, unvoicedPhoneme, carrier }
