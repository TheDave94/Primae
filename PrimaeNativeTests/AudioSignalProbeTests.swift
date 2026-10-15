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
            handler(Self.readOnlyView(buffer), AVAudioTime())
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
        handler(Self.readOnlyView(makeBuffer(sampleCount: 256, value: 0.0)), AVAudioTime())

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
        handler(Self.readOnlyView(buffer), AVAudioTime())

        #expect(counters.peak == 0.75)
    }

    /// Interleaved is a different memory layout — one pointer covering all
    /// channels — and reading it per-channel walks off the end of the
    /// allocation. The device handed this probe interleaved buffers, which
    /// is how that crash was found; the layout is now handled, so pin it.
    /// (This case only exercises the FIRST half of the block; the full
    /// layout matrix below is what pins the second half, R-070.)
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
        // frameLength counts FRAMES: 4 frames × 2 channels = 8 samples in one
        // block. Only frames 0 and 1 are written here.
        let samples = buffer.floatChannelData![0]
        samples[0] = 0.02; samples[1] = -0.02
        samples[2] = 0.03; samples[3] = 0.9
        handler(Self.readOnlyView(buffer), AVAudioTime())

        #expect(counters.peak == 0.9)
    }

    // MARK: - Every sample of every layout (R-070)

    /// One case of the layout × format × channel matrix: a stereo buffer
    /// whose only non-zero sample sits in the LAST frame, on the given
    /// channel(s). For an interleaved buffer that sample lies in the second
    /// half of the single data block — exactly the half a scan of
    /// `frameLength` SAMPLES (instead of frames × channels) never reads.
    struct LayoutCase: Sendable, CustomTestStringConvertible {
        let interleaved: Bool
        let int16: Bool
        let left: Bool
        let right: Bool
        var testDescription: String {
            "\(interleaved ? "interleaved" : "planar") \(int16 ? "int16" : "float32") "
                + (left && right ? "both" : left ? "left-only" : "right-only")
        }
    }

    static let layoutCases: [LayoutCase] = [true, false].flatMap { interleaved in
        [false, true].flatMap { int16 in
            [(true, false), (false, true), (true, true)].map {
                LayoutCase(interleaved: interleaved, int16: int16, left: $0.0, right: $0.1)
            }
        }
    }

    /// A zero-filled stereo buffer of `frames` frames, with `value` written
    /// at (`frame`, `channel`) for each listed channel.
    private func makeStereo(
        interleaved: Bool, int16: Bool, frames: Int,
        writes: [(frame: Int, channel: Int, value: Float)]
    ) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: int16 ? .pcmFormatInt16 : .pcmFormatFloat32,
            sampleRate: 44_100, channels: 2, interleaved: interleaved
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        func index(_ frame: Int, _ channel: Int) -> (pointer: Int, offset: Int) {
            interleaved ? (0, frame * 2 + channel) : (channel, frame)
        }
        for frame in 0..<frames {
            for channel in 0..<2 {
                let (p, o) = index(frame, channel)
                if int16 { buffer.int16ChannelData![p][o] = 0 } else { buffer.floatChannelData![p][o] = 0 }
            }
        }
        for w in writes {
            let (p, o) = index(w.frame, w.channel)
            if int16 {
                buffer.int16ChannelData![p][o] = Int16(w.value * Float(Int16.max))
            } else {
                buffer.floatChannelData![p][o] = w.value
            }
        }
        return buffer
    }

    /// The peak the probe records for `buffer`, read through the real tap
    /// handler — the path AVFAudio drives on the device.
    private func probedPeak(_ buffer: AVAudioPCMBuffer) -> (peak: Float, nonSilent: Int) {
        let counters = AudioSignalCounters()
        let handler = AudioSignalProbe.makeTapHandler(counters: counters, threshold: 0.001)
        handler(Self.readOnlyView(buffer), AVAudioTime())
        return (counters.peak, counters.nonSilent)
    }

    /// Wrap `buffer` for the tap handler the way AVFAudio wraps the buffers
    /// it hands a tap: a read-only view over the buffer's OWN memory, not a
    /// copy of it.
    ///
    /// MEASURED ON CI 2026-10-14 (xcode-27 image, iOS 27.0 simulator
    /// runtime): `AVReadOnlyAudioPCMBuffer(copying:)` delivers an
    /// INTERLEAVED payload's samples only up to `frameLength` — the second
    /// half of the block arrives zeroed. Every layout case whose only
    /// signal sat in the last frame (the second half) read silence and
    /// failed, float32 and int16 alike, while the same tests passed on the
    /// 27.2 runtime; early-frame interleaved signals were copied and seen,
    /// which is what pinned the loss on the copy and not on the write or
    /// the scan. So the harness copies nothing: `unsafeRetaining` keeps the
    /// scan on the exact memory `makeStereo` wrote, and every buffer handed
    /// through here outlives the handler call, which is the documented
    /// precondition of that initializer.
    private static func readOnlyView(_ buffer: AVAudioPCMBuffer) -> AVReadOnlyAudioPCMBuffer {
        AVReadOnlyAudioPCMBuffer(unsafeRetaining: buffer)
    }

    /// What the probe is actually handed: the block count, and for each block
    /// its channel count and byte size, plus the frame length and format the
    /// buffer reports. Read from the same memory the handler scans (the
    /// original buffer), so a failing layout case prints the shape of what
    /// was really handed, not of a copy that may differ from it.
    private func shape(of buffer: AVAudioPCMBuffer) -> String {
        let blocks = buffer.withUnsafeAudioBufferList { list -> String in
            UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
                .map { "ch=\($0.mNumberChannels) bytes=\($0.mDataByteSize)" }
                .joined(separator: "; ")
        }
        return "frameLength=\(buffer.frameLength) interleaved=\(buffer.format.isInterleaved) "
            + "channels=\(buffer.format.channelCount) common=\(buffer.format.commonFormat.rawValue) blocks=[\(blocks)]"
    }

    @Test("a signal in the last frame is seen on every layout and channel",
          arguments: layoutCases)
    func lastFrameSignalIsSeen(_ c: LayoutCase) {
        let frames = 256
        var writes: [(frame: Int, channel: Int, value: Float)] = []
        if c.left { writes.append((frames - 1, 0, 0.5)) }
        if c.right { writes.append((frames - 1, 1, -0.5)) }
        let buffer = makeStereo(interleaved: c.interleaved, int16: c.int16, frames: frames, writes: writes)

        let expected: Float = c.int16
            ? Float(Int16(0.5 * Float(Int16.max))) / Float(Int16.max)
            : 0.5
        let result = probedPeak(buffer)
        let seen = shape(of: buffer)
        #expect(result.peak == expected, "\(c.testDescription): the probe reported \(result.peak); handed \(seen)")
        #expect(result.nonSilent == 1, "\(c.testDescription): a signal read as silence; handed \(seen)")
    }

    @Test("samples past frameLength are not read", arguments: [true, false])
    func samplesPastFrameLengthAreIgnored(_ interleaved: Bool) {
        // Signal only in frame 6 of 8, then shorten the buffer to 4 frames:
        // the probe must report silence, not the stale tail.
        let buffer = makeStereo(interleaved: interleaved, int16: false, frames: 8,
                                writes: [(6, 0, 0.7), (6, 1, 0.7)])
        buffer.frameLength = 4
        let result = probedPeak(buffer)
        #expect(result.peak == 0)
        #expect(result.nonSilent == 0)
    }

    /// The pure scan, on a hand-built list with no AVAudioPCMBuffer in the
    /// way: one interleaved stereo block of 4 frames (8 samples). The count
    /// comes from frameLength × mNumberChannels and is clamped by the
    /// block's own byte size, so a block that claims fewer bytes than that
    /// is never read past its end.
    @Test("the pure scan reads frameLength × channels, clamped by byte size")
    func pureScanCountsAndClamps() {
        var samples: [Float] = [0, 0, 0, 0, 0, 0, 0, 0.6]   // last sample = frame 3, right
        samples.withUnsafeMutableBytes { raw in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(raw.count),
                                      mData: raw.baseAddress))
            #expect(AudioSignalProbe.peakMagnitude(of: &list, frameLength: 4,
                                                   commonFormat: .pcmFormatFloat32) == 0.6)
            // frameLength 3 stops before the last frame.
            #expect(AudioSignalProbe.peakMagnitude(of: &list, frameLength: 3,
                                                   commonFormat: .pcmFormatFloat32) == 0)
            // A byte size smaller than the frames claim wins.
            list.mBuffers.mDataByteSize = UInt32(7 * MemoryLayout<Float>.size)
            #expect(AudioSignalProbe.peakMagnitude(of: &list, frameLength: 4,
                                                   commonFormat: .pcmFormatFloat32) == 0)
        }
    }

    /// `reset()` opens a fresh window for the next phase. If it leaked state
    /// across phases, a silent phase would inherit the previous phase's
    /// peak and every per-phase reading would be suspect.
    @Test("reset clears the window")
    func resetClearsCounters() {
        let counters = AudioSignalCounters()
        let handler = AudioSignalProbe.makeTapHandler(counters: counters, threshold: 0.001)
        handler(AVReadOnlyAudioPCMBuffer(copying: makeBuffer(sampleCount: 128, value: 0.8)), AVAudioTime())
        #expect(counters.nonSilent == 1)

        counters.reset()
        #expect(counters.total == 0)
        #expect(counters.nonSilent == 0)
        #expect(counters.peak == 0)
    }

    // MARK: - Probe log append (R-070)

    /// The append must report a failed write as a Swift error. The legacy
    /// `seekToEndOfFile()`/`write(_:)` raise an Objective-C exception
    /// instead, which Swift cannot catch: this test then TRAPS rather than
    /// failing cleanly (read a vanished run of this suite that way).
    @Test("a failed probe-log append throws instead of crashing")
    func failedAppendThrows() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("probe-append-\(UUID().uuidString).log")
        try Data("x\n".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        // A read-only handle: every write through it fails.
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        #expect(throws: (any Error).self) {
            try AudioSignalProbe.append("line", to: handle)
        }
    }

    /// And on a writable handle it APPENDS — two calls, two lines, the
    /// existing content kept.
    @Test("probe-log append adds a line at the end")
    func appendAddsALineAtTheEnd() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("probe-append-\(UUID().uuidString).log")
        try Data("first\n".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forWritingTo: url)
        try AudioSignalProbe.append("second", to: handle)
        try AudioSignalProbe.append("third", to: handle)
        try handle.close()
        #expect(try String(contentsOf: url, encoding: .utf8) == "first\nsecond\nthird\n")
    }

    // MARK: - Tap lifetime (R-070)

    /// Releasing the probe takes its tap off the mixer. Observed through
    /// the API itself: `installAudioTap` throws while a tap is on the bus,
    /// so a second install fails while the probe lives and succeeds once
    /// it is gone. An OFFLINE (manual-rendering) engine, never started, so
    /// no audio hardware or converter service is involved.
    @MainActor
    @Test("releasing the probe removes its tap")
    func deinitRemovesTheTap() throws {
        let engine = AVAudioEngine()
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
        let mixer = engine.mainMixerNode
        let noop: @Sendable (AVReadOnlyAudioPCMBuffer, AVAudioTime) -> Void = { _, _ in }

        var probe: AudioSignalProbe? = AudioSignalProbe()
        probe?.arm(on: engine)
        #expect(throws: (any Error).self, "precondition: the probe's tap is on bus 0") {
            try mixer.installAudioTap(onBus: 0, bufferSize: 1024, format: nil, tapProvider: noop)
        }

        probe = nil
        #expect(throws: Never.self, "the released probe left its tap on bus 0") {
            try mixer.installAudioTap(onBus: 0, bufferSize: 1024, format: nil, tapProvider: noop)
        }
        mixer.removeTap(onBus: 0)
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
    ///
    /// SKIPPED, visibly, when the source file is not readable: `#filePath` is
    /// the Mac checkout's path baked in at compile time, and a test bundle
    /// running on the physical iPad cannot open it. The skip shows in the
    /// results with its reason (it is not a known issue and not a silent pass);
    /// the check still runs, and can fail, wherever the checkout is readable
    /// (the simulator and the Mac).
    @Test("the tap is never installed with an inline closure literal",
          .enabled(if: Self.probeSourceIsReadable,
                   "AudioSignalProbe.swift is not readable here (#filePath is a Mac path; on the physical iPad the checkout does not exist)"))
    func tapIsNotInstalledWithAnInlineClosure() throws {
        let source = try String(contentsOf: probeSourceURL(), encoding: .utf8)

        // Strip comments so the prohibition does not fire on the very
        // comments explaining why it exists.
        let code = stripComments(source)

        // A trailing closure immediately after installTap( ... ) — the exact
        // shape that crashed three times.
        #expect(
            !code.contains("installAudioTap(onBus: 0, bufferSize: 1024, format: format) {"),
            "AudioSignalProbe installs its tap with an inline closure literal, which inherits @MainActor and SIGTRAPs on AVFAudio's realtime thread. Pass tapProvider: a handler from makeTapHandler."
        )

        // And positively: the installation must go through the factory.
        #expect(code.contains("tapProvider: handler"))
    }

    private static var probeSourceIsReadable: Bool {
        FileManager.default.isReadableFile(atPath: probeSourceURL().path)
    }

    private func probeSourceURL() -> URL { Self.probeSourceURL() }

    private static func probeSourceURL() -> URL {
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