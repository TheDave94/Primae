// AudioSignalProbe.swift
// PrimaeNative
//
// MEASURES WHETHER SOUND ACTUALLY CAME OUT.
//
// The problem this solves, in the proctor's words on 2026-10-02: he
// reported "no audio for the demonstration and no audio for the free write
// mode, just the Nachspuren one", and NOTHING in the test suite could
// confirm or refute it. Every existing audio assertion asks whether
// `play()` was CALLED. That is a statement about intent, not about the
// speaker — an engine that failed to start, a file that failed to
// resolve, a route with no output, or a gain of zero all pass every
// current assertion while the child hears nothing.
//
// The technique is the documented one: tap the engine's main mixer and
// read the samples. An `AVAudioPCMBuffer` from the output bus is what the
// speaker is about to be handed, so a non-zero peak in it is evidence of
// a signal, and a run of zero-valued buffers is evidence of silence —
// measured, not inferred.
//
// WHY IT IS OFF BY DEFAULT AND LAUNCH-GATED. `installTap` on the main
// mixer is not free: it must be installed exactly once (a second
// installTap is a documented crash), it must be removed before the engine
// is torn down, and on a device it pulls the output bus through the tap.
// None of that belongs in a pilot artefact that a child is holding. So
// the probe arms only when the process was started with the probe
// argument, which is what an XCUI test launch does and nothing else does.
//
// THE TWO GOTCHAS THIS IS BUILT AGAINST, both found in the research
// rather than invented here:
//   1. Tapping the main mixer can create a feedback loop, because the tap
//      is downstream of the output. This probe only READS the buffer and
//      never reconnects or re-routes anything, so there is no path back
//      into the graph.
//   2. `installTap` after the engine has stopped throws. Arming is done
//      once at init, before anything plays, and removal is deferred to
//      deinit.

import AVFoundation
import Foundation
import os

/// Test-only observer of the engine's real output samples.
///
/// Deliberately NOT part of `AudioControlling`: it observes the engine,
/// it does not drive it, and putting it on the protocol would invite
/// production call sites to depend on a measurement aid.

/// Plain, non-actor-isolated counters for the realtime tap thread.
///
/// MEASURED CRASH, 2026-10-02, and the reason this type exists. The first
/// version kept the counters as `@MainActor` properties on the probe and
/// hopped to the main actor to increment them, and the second moved the
/// counters into this box but still built the tap closure INSIDE the
/// `@MainActor` method that installs it. AVFAudio calls that closure on its
/// REALTIME thread, so Swift's isolation check fired immediately and took
/// the app down both times: `_dispatch_assert_queue_fail` ->
/// `swift_task_checkIsolatedSwift` -> `closure #1 in arm(on:)`. Two device
/// runs, two crashes, while the same test passed with the probe disarmed.
///
/// The lesson the second attempt missed: under `.defaultIsolation(MainActor.self)`
/// a closure literal INHERITS the isolation of its enclosing context, so
/// capturing only non-isolated values is NOT enough — the closure itself
/// was still MainActor. What has to be non-isolated is where the closure is
/// *formed*, which is why `makeTapHandler` is `nonisolated`.
///
/// These counters are plain storage behind a lock: the tap writes them
/// directly, and the main actor reads them when a phase window closes.
///
/// MARK THE TYPE, NOT JUST ITS MEMBERS. Under
/// `.defaultIsolation(MainActor.self)` EVERY declaration in this module
/// defaults to `@MainActor` — including the methods of a plain class — so
/// being `Sendable` was never sufficient: `record` was still isolated, and
/// calling it from a `nonisolated` context does not compile. Marking the
/// type `nonisolated` is what makes the whole box genuinely callable from
/// the realtime thread.
///
/// That compile error is worth keeping in mind as a diagnostic: once the
/// handler itself became `nonisolated`, the compiler immediately reported
/// the next isolation leak underneath it. Isolation bugs in this module
/// surface one layer at a time, and the layer below shows up as a build
/// failure rather than a device crash — which is the cheap way to find it.
nonisolated final class AudioSignalCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var _nonSilent = 0
    private var _total = 0
    private var _peak: Float = 0

    var nonSilent: Int { lock.withLock { _nonSilent } }
    var total: Int { lock.withLock { _total } }
    var peak: Float { lock.withLock { _peak } }

    func record(peak samplePeak: Float, threshold: Float) {
        lock.withLock {
            _total += 1
            if samplePeak > threshold {
                _nonSilent += 1
                _peak = max(_peak, samplePeak)
            }
        }
    }

    func reset() {
        lock.withLock { _nonSilent = 0; _total = 0; _peak = 0 }
    }
}

/// `@Observable` MEASURED-NECESSARY (2026-10-02). Without it the
/// accessibility readout never appeared: this is a plain class, so
/// SwiftUI has no way to observe `latestSummaryLine` changing, the view
/// body was evaluated once while the value was still nil, and nothing
/// re-rendered it when the first measurement arrived. The value was
/// correct in the model and invisible in the UI — which reads exactly
/// like "the probe never ran", and cost several device runs to
/// distinguish from that.
///
/// Deliberately `@MainActor` as well as `@Observable`: every mutation
/// happens from the ticker or a phase transition, and the tap thread
/// touches only the separate non-isolated counters box.
@MainActor
@Observable
final class AudioSignalProbe {

    /// Set from the launch environment by an XCUI test. Absent in a
    /// proctor's hands and in every CI unit run.
    static var isArmedByLaunchArgument: Bool {
        ProcessInfo.processInfo.arguments.contains("-audioSignalProbe")
    }

    private let log = Logger(subsystem: "de.flamingistan.primae", category: "AudioSignal")
    private var isInstalled = false

    /// Buffers whose peak sample magnitude exceeded this. Chosen well
    /// above denormal noise and well below anything a child would hear as
    /// a tone: -60 dBFS is about 0.001, and the quietest arm content sits
    /// far above it.
    private let silenceThreshold: Float = 0.001

    private let counters = AudioSignalCounters()
    private var nonSilentBufferCount: Int { counters.nonSilent }
    private var totalBufferCount: Int { counters.total }
    private var peakMagnitude: Float { counters.peak }

    /// Install the tap. Safe to call once; a second call is ignored
    /// rather than attempted, because a duplicate `installTap` is the
    /// documented crash.
    func arm(on engine: AVAudioEngine) {
        guard !isInstalled, !engine.isRunning else { return }
        let mixer = engine.mainMixerNode
        let format = mixer.outputFormat(forBus: 0)
        // A tap needs a real PCM format. If the output bus reports
        // something unusable (no route, hardware in a weird state), skip
        // rather than install a tap that would crash the pilot.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            log.error("AudioSignalProbe: output bus unusable (rate \(format.sampleRate), channels \(format.channelCount)) — not arming")
            return
        }
        // The closure below runs on AVFAudio's REALTIME thread, so it is
        // BUILT by a `nonisolated` function rather than as a literal here.
        // A literal written in this `@MainActor` method would inherit
        // `@MainActor` and trap on the realtime thread — see the note on
        // `AudioSignalCounters`.
        let handler = Self.makeTapHandler(counters: counters, threshold: silenceThreshold)
        mixer.installTap(onBus: 0, bufferSize: 1024, format: format, block: handler)
        isInstalled = true
        log.notice("AudioSignalProbe armed at \(format.sampleRate) Hz, \(format.channelCount) ch")
    }

    /// Build the tap handler OUTSIDE any actor-isolated context.
    ///
    /// This is the load-bearing part of the crash fix, so it is
    /// `internal` rather than `private`: `AudioSignalProbeTests` calls this
    /// from a background queue and invokes the result, which reproduces the
    /// realtime-thread call on the simulator in milliseconds. The bug took
    /// three device runs and two crashes to find; it should never again take
    /// more than one unit test to detect.
    nonisolated static func makeTapHandler(
        counters: AudioSignalCounters,
        threshold: Float
    ) -> AVAudioNodeTapBlock {
        { buffer, _ in
            counters.record(peak: peakMagnitude(of: buffer), threshold: threshold)
        }
    }

    func remove(from engine: AVAudioEngine) {
        guard isInstalled else { return }
        engine.mainMixerNode.removeTap(onBus: 0)
        isInstalled = false
    }

    /// Peak absolute sample across every channel, computed off the tap's
    /// own buffer rather than converted through AVAudioPCMBuffer's float
    /// path, so it works for both float32 and int16 sessions.
    ///
    /// MEASURED CRASH, 2026-10-02: the first version of this walked one
    /// pointer per channel (`floatChannelData[channel]`), which is the
    /// NON-interleaved layout only. The device's output bus delivers
    /// INTERLEAVED buffers, where `floatChannelData` holds a single
    /// pointer covering every channel; indexing it per channel ran off the
    /// end of the allocation and took the app down. The rail enrolment
    /// test passed with the probe disarmed and crashed with it armed,
    /// which is what isolated it here rather than in the audio engine.
    ///
    /// Both layouts are now handled, and the frame count is clamped to
    /// what the buffer actually holds so a future mismatch degrades to a
    /// quiet reading instead of a crash.
    private nonisolated static func peakMagnitude(of buffer: AVAudioPCMBuffer) -> Float {
        let channels = max(1, Int(buffer.format.channelCount))
        var peak: Float = 0

        if let floats = buffer.floatChannelData {
            if buffer.format.isInterleaved {
                // ONE buffer, channels interleaved: frameLength already
                // counts every sample in it.
                let total = Int(buffer.frameLength)
                guard total > 0 else { return 0 }
                let samples = floats[0]
                for i in 0..<min(total, Int(buffer.mutableAudioBufferList.pointee.mBuffers.mDataByteSize) / MemoryLayout<Float>.size) {
                    peak = max(peak, abs(samples[i]))
                }
            } else {
                let frames = Int(buffer.frameLength)
                guard frames > 0 else { return 0 }
                for channel in 0..<channels {
                    let samples = floats[channel]
                    for i in 0..<frames { peak = max(peak, abs(samples[i])) }
                }
            }
            return peak
        }

        if let ints = buffer.int16ChannelData {
            let frames = Int(buffer.frameLength)
            guard frames > 0 else { return 0 }
            if buffer.format.isInterleaved {
                let total = Int(buffer.frameLength)
                let samples = ints[0]
                for i in 0..<min(total, Int(buffer.mutableAudioBufferList.pointee.mBuffers.mDataByteSize) / MemoryLayout<Int16>.size) {
                    peak = max(peak, abs(Float(samples[i]) / Float(Int16.max)))
                }
            } else {
                for channel in 0..<channels {
                    let samples = ints[channel]
                    for i in 0..<frames {
                        peak = max(peak, abs(Float(samples[i]) / Float(Int16.max)))
                    }
                }
            }
        }
        return peak
    }

    /// The line an XCUI test greps for. Emitted on request rather than
    /// continuously so a test can mark a WINDOW (a phase) and read only
    /// that window's numbers.
    /// Append one line to the probe log in the app container.
    ///
    /// The unified log on a physical device is awkward to pull from an
    /// automated run, and the whole point of this probe is that a machine
    /// can read the answer. Written only when armed, so the pilot artefact
    /// never produces the file.
    private func writeLine(_ line: String) {
        guard Self.isArmedByLaunchArgument else { return }
        writeLineUnconditionally(line)
    }

    /// The actual write. Deliberately has NO arm guard, so the debugging
    /// dump above can reach it: a guard on the only write path is exactly
    /// what made this failure invisible.
    private func writeLineUnconditionally(_ line: String) {
        Self.appendLineUnconditionally(line)
    }

    /// The one place a probe line reaches disk, reachable from a `static`
    /// context with no instance at all.
    ///
    /// Added 2026-10-02 to settle an open question by measurement: the
    /// engine's own `signalProbe.trace` lines reached the file while every
    /// view-model trace did not, even though `strings` proved all of them
    /// compiled into the shipped framework. A static, instance-free,
    /// ungated entry point distinguishes "this code never runs" from
    /// "this code runs and its output is swallowed" in a single run,
    /// which two rounds of indirect tracing had not.
    ///
    /// No arm guard, so CALL SITES must be `#if DEBUG` — the pilot
    /// artefact must never write this file.
    static func appendLineUnconditionally(_ line: String) {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let folder = dir.appendingPathComponent("PrimaeNative", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("audio-signal-probe.log")
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write((line + "\n").data(using: .utf8) ?? Data())
            try? handle.close()
        } else {
            try? (line + "\n").data(using: .utf8)?.write(to: file)
        }
    }

    func reset() {
        counters.reset()
    }

    /// The most recent `AUDIO-SIGNAL` line, or nil.
    ///
    /// Published for the XCUI test rather than written to a shared path,
    /// because there is NO shared writable location: the app's tmp is
    /// sandboxed per-app (MEASURED — an XCUITest cannot read the app's
    /// container), and this project has no App Group to bridge them
    /// (measured 2026-09-11: no entitlements, no `UserDefaults(suiteName:)`,
    /// no `containerURL(forSecurityApplicationGroupIdentifier:)` anywhere).
    /// The accessibility tree is the one channel that already crosses the
    /// process boundary, so the number rides on it.
    private(set) var latestSummaryLine: String?

    /// Record a summary line and, if asked, publish it.
    func emitSummary(label: String) {
        let line = "AUDIO-SIGNAL \(label) nonSilent=\(nonSilentBufferCount) total=\(totalBufferCount) peak=\(peakMagnitude)"
        log.notice("\(line)")
        latestSummaryLine = line
        writeLine(line)
    }
}
