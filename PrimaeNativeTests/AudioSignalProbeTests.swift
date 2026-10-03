// AudioSignalProbeTests.swift
// PrimaeNativeTests
//
// The probe's crash, made assertable — and reproduced WITHOUT a device.
//
// WHY THIS EXISTS. On 2026-10-02 the probe took the app down on the
// physical iPad, twice, with SIGTRAP:
//   _dispatch_assert_queue_fail -> swift_task_checkIsolatedSwift ->
//   closure #1 in AudioSignalProbe.arm(on:)
// AVFAudio invokes a tap closure on its REALTIME thread, and under
// `.defaultIsolation(MainActor.self)` a closure literal written inside a
// `@MainActor` method INHERITS that isolation — so it traps the moment
// the audio thread calls it. What the closure *captures* is irrelevant;
// where it is *formed* is the whole question.
//
// The first fix moved the counters into a non-isolated box and changed
// nothing observable, because the literal was still lexically inside
// `arm(on:)`. That is why the handler is now built by a `nonisolated`
// factory, and why that factory is tested rather than trusted.
//
// WHY THIS TEST IS WORTH HAVING. Discovering that failure cost three
// device runs, two app crashes, and a crash-log pull per attempt. The
// defect itself has nothing to do with hardware: any call into the
// handler from a non-main thread reproduces it. So the test does exactly
// that — builds the handler and invokes it off the main actor. It runs on
// the simulator, in milliseconds, forever.
//
// NOTE ON WHAT THIS CANNOT CATCH CLEANLY. If a future change makes the
// handler MainActor-isolated again, this test TRAPS rather than failing
// cleanly — the process dies mid-suite. That is still the correct
// outcome: the alternative is the same trap arriving later, on a child's
// iPad. Read a vanished or truncated run of this suite as "the isolation
// came back", not as a flake.

import AVFoundation
import Foundation
import Testing
import XCTest

@testable import PrimaeNative

@Suite("Audio signal probe")
struct AudioSignalProbeTests {

    /// A single-channel float buffer of the given length, filled with a
    /// constant sample value. The probe only reads samples, so a constant
    /// is the simplest buffer that carries a known peak.
    private func makeBuffer(sampleCount: Int, value: Float) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44_100,
            channels: 1,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(sampleCount)
        )!
        buffer.frameLength = AVAudioFrameCount(sampleCount)
        let samples = buffer.floatChannelData![0]
        for i in 0..<sampleCount { samples[i] = value }
        return buffer
    }

    /// The regression this file exists for: call the tap handler from a
    /// thread that is NOT the main actor, which is what AVFAudio does.
    @Test("tap handler survives being called off the main actor")
    func handlerIsCallableFromTheRealtimeThread() {
        let counters = AudioSignalCounters()
        let handler = AudioSignalProbe.makeTapHandler(counters: counters, threshold: 0.001)
        let buffer = makeBuffer(sampleCount: 256, value: 0.5)

        // A dedicated non-main thread, so the executor is provably not the
        // main actor — this is the exact condition that trapped. A
        // semaphore rather than a Swift Testing expectation: the point is
        // that the call RETURNS, and a crash inside the handler takes the
        // whole process down before any expectation could be reported.
        let ran = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            XCTAssertFalse(Thread.isMainThread)
            handler(buffer, AVAudioTime())
            ran.signal()
        }
        #expect(ran.wait(timeout: .now() + 5) == .success)

        // Not just "it did not crash": the samples it was handed were
        // actually read and recorded.
        #expect(counters.total == 1)
        #expect(counters.nonSilent == 1)
        #expect(counters.peak == 0.5)
    }

    /// Silence must read as silence. A probe that reports a signal when the
    /// output bus is quiet would make every audio assertion built on it a
    /// lie, so the negative case is pinned explicitly.
    @Test("a silent buffer records no signal")
    func silentBufferRecordsNothing() {
        let counters = AudioSignalCounters()
        let handler = AudioSignalProbe.makeTapHandler(counters: counters, threshold: 0.001)
        handler(makeBuffer(sampleCount: 256, value: 0.0), AVAudioTime())

        #expect(counters.total == 1)
        #expect(counters.nonSilent == 0)
        #expect(counters.peak == 0)
    }

    /// Peak is a magnitude over the WHOLE buffer, not just the first
    /// sample, and it spans every channel.
    @Test("peak spans the buffer and every channel")
    func peakSpansBufferAndChannels() {
        let counters = AudioSignalCounters()
        let handler = AudioSignalProbe.makeTapHandler(counters: counters, threshold: 0.001)

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44_100,
            channels: 2,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8)!
        buffer.frameLength = 8
        // Quiet everywhere except the LAST frame of the second channel: a
        // first-sample-only or first-channel-only peak would miss it.
        buffer.floatChannelData![0][0] = 0.01
        buffer.floatChannelData![1][7] = -0.75
        handler(buffer, AVAudioTime())

        #expect(counters.peak == 0.75)
    }

    /// Interleaved is a different memory layout — one pointer covering all
    /// channels — and reading it per-channel walks off the end of the
    /// allocation. The device handed this probe interleaved buffers, which
    /// is how that crash was found; the layout is now handled, so pin it.
    @Test("interleaved buffers are read across all channels")
    func interleavedBufferIsReadCorrectly() {
        let counters = AudioSignalCounters()
        let handler = AudioSignalProbe.makeTapHandler(counters: counters, threshold: 0.001)

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44_100,
            channels: 2,
            interleaved: true
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4)!
        buffer.frameLength = 4
        // frameLength counts SAMPLES when interleaved: 4 samples = 2 frames.
        let samples = buffer.floatChannelData![0]
        samples[0] = 0.02; samples[1] = -0.02
        samples[2] = 0.03; samples[3] = 0.9
        handler(buffer, AVAudioTime())

        #expect(counters.peak == 0.9)
    }

    /// `reset()` opens a fresh window for the next phase. If it leaked state
    /// across phases, a silent phase would inherit the previous phase's
    /// peak and every per-phase reading would be suspect.
    @Test("reset clears the window")
    func resetClearsCounters() {
        let counters = AudioSignalCounters()
        let handler = AudioSignalProbe.makeTapHandler(counters: counters, threshold: 0.001)
        handler(makeBuffer(sampleCount: 128, value: 0.8), AVAudioTime())
        #expect(counters.nonSilent == 1)

        counters.reset()
        #expect(counters.total == 0)
        #expect(counters.nonSilent == 0)
        #expect(counters.peak == 0)
    }

    // MARK: - The call-site guard

    /// MEASURED LIMITATION, 2026-10-02, and why this test exists.
    ///
    /// The off-thread test above is load-bearing for the HANDLER, but it is
    /// blind to the CALL SITE — and the call site is where the crash lived.
    /// Proven by mutation: putting the closure literal back inline in
    /// `arm(on:)` (the original crashing shape) COMPILES CLEANLY and every
    /// test in this file still passes. There is no compile-time diagnostic
    /// for it, because a MainActor-isolated closure passed where any
    /// `@Sendable`-ish function is expected is a legal program; it simply
    /// TRAPS when the audio thread calls it, on a device, in a pilot.
    ///
    /// So the regression is guarded structurally instead: the tap may only
    /// be installed by passing the handler the `nonisolated` factory built.
    /// A trailing-closure `installTap(...) { ... }` would inherit
    /// `@MainActor` from the enclosing method and is therefore banned here.
    /// This is a source-level check rather than a behavioural one because the
    /// behaviour in question is a trap that only a device can observe.
    @Test("the tap is never installed with an inline closure literal")
    func tapIsNotInstalledWithAnInlineClosure() throws {
        let source = try String(contentsOf: probeSourceURL(), encoding: .utf8)

        // Strip comments so the prohibition does not fire on the very
        // comments explaining why it exists.
        let code = stripComments(source)

        // A trailing closure immediately after installTap( ... ) — the exact
        // shape that crashed three times.
        #expect(
            !code.contains("installTap(onBus: 0, bufferSize: 1024, format: format) {"),
            "AudioSignalProbe installs its tap with an inline closure literal, which inherits @MainActor and SIGTRAPs on AVFAudio's realtime thread. Pass block: a handler from makeTapHandler."
        )

        // And positively: the installation must go through the factory.
        #expect(code.contains("block: handler"))
    }

    private func probeSourceURL() -> URL {
        // `#filePath` is this test file's absolute path AT COMPILE TIME, so
        // walking up from it reaches the repo root with no dependence on
        // bundle layout, build directory shape, or working directory.
        URL(fileURLWithPath: #filePath)          // .../PrimaeNativeTests/AudioSignalProbeTests.swift
            .deletingLastPathComponent()          // .../PrimaeNativeTests
            .deletingLastPathComponent()          // repo root
            .appendingPathComponent("PrimaeNative/Core/AudioSignalProbe.swift")
    }

    /// Remove `//` line comments. Deliberately simple: this file contains no
    /// string literals with `//` in them, and over-stripping a comment is
    /// harmless here because the assertions target call shapes.
    private func stripComments(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let range = line.range(of: "//") else { return String(line) }
                return String(line[line.startIndex..<range.lowerBound])
            }
            .joined(separator: "\n")
    }
}

/// Anchor for `Bundle(for:)`; the suite itself is not a class.
private final class ProbeBundleToken {}