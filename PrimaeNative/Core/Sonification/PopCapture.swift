// PopCapture.swift
// PrimaeNative
//
// POPCAP (2026-11-04): records what the app REALLY outputs while a pen
// writes, so pops can be found in the device's own audio instead of in kernel
// renders. DEBUG-only (`#if DEBUG || POPCAP`; POPCAP is defined only by a
// throwaway build clone that wants an -O build with the instrument; the
// Release-Study artefact has neither, proved by nm/strings in POPCAP.md).
// Armed per launch by `-popCapture` (`-popCaptureTag <name>` names the run).
//
// What it writes, under Documents/popcap/<tag>-<time>/ in the app container:
//   mixer.wav   float32, the main mixer's output (a tap from OUR code; the
//               signal the hardware is handed: pan, sample-rate conversion,
//               every voice that goes through the engine)
//   kernel.wav  float32 mono 44.1 kHz, the live kernel's own render output,
//               copied in the source node's render block (r17 builds only)
//   rt.tsv      render-thread and tap-thread records on the mach clock:
//               R  one render callback  (frames, sampleTime, duration, ioHostTime)
//               T  one mixer-tap buffer (frames, sampleTime)
//               K  kernel events: begin (slot, rate, cents, voice), wrap
//               (voice, rate), voiceEnd
//   events.tsv  everything else, same clock: touch, gate, play/stop/restart,
//               rate/pan/pitch commands, letter/phase, renderer builds (thread,
//               ms), session/route/interruption/lifecycle, prompts
//   meta.txt    device, session, buffer, rates, ring overflow counters
// The clock is mach_absolute_time converted to ns: one clock for the app and
// (on the same device) for the UI test's own log.
//
// Real-time contract: the render path calls `renderEnd` / `kernelEvent`
// (lock-free SPSC rings, no allocation, no lock); the tap callback calls
// `tapBuffer` (its own rings). A utility queue drains every 50 ms to disk.
// A ring that overflows drops the WHOLE write and counts it (meta.txt); an
// analysis must treat a non-zero count as a hole, not a signal.

#if DEBUG || POPCAP
import AVFoundation
import Foundation
import OSLog
import Synchronization

nonisolated struct PopRec {
    var t: UInt64 = 0          // mach ticks
    var kind: UInt32 = 0
    var a: Int32 = 0
    var x: Double = 0
    var y: Double = 0
    var z: Double = 0
}

/// Single-producer single-consumer ring of plain values.
nonisolated final class PopRing<T>: @unchecked Sendable {
    let cap: Int, mask: Int
    private let buf: UnsafeMutablePointer<T>
    private let w = Atomic<Int>(0), r = Atomic<Int>(0)
    let dropped = Atomic<Int>(0)
    init(capacityPow2: Int, zero: T) {
        cap = capacityPow2; mask = cap - 1
        buf = .allocate(capacity: cap); buf.initialize(repeating: zero, count: cap)
    }
    func write(_ p: UnsafePointer<T>, _ n: Int) {
        let wi = w.load(ordering: .relaxed), ri = r.load(ordering: .acquiring)
        guard cap - (wi - ri) >= n else { dropped.wrappingAdd(n, ordering: .relaxed); return }
        var i = 0
        while i < n { buf[(wi + i) & mask] = p[i]; i += 1 }
        w.store(wi + n, ordering: .releasing)
    }
    func write(_ v: T) { var x = v; withUnsafePointer(to: &x) { write($0, 1) } }
    /// Consumer: hands out up to everything available, in one or two contiguous runs.
    func drain(_ body: (UnsafePointer<T>, Int) -> Void) {
        let wi = w.load(ordering: .acquiring), ri = r.load(ordering: .relaxed)
        var n = wi - ri
        guard n > 0 else { return }
        var pos = ri
        while n > 0 {
            let s = pos & mask, run = min(n, cap - s)
            body(buf + s, run)
            pos += run; n -= run
        }
        r.store(wi, ordering: .releasing)
    }
}

nonisolated final class PopWav {
    private let fh: FileHandle
    private var bytes = 0
    init?(url: URL, channels: Int, rate: Int) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let f = try? FileHandle(forWritingTo: url) else { return nil }
        fh = f
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36)
        d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(3); u16(UInt16(channels))
        u32(UInt32(rate)); u32(UInt32(rate * channels * 4)); u16(UInt16(channels * 4)); u16(32)
        d.append(contentsOf: Array("data".utf8)); u32(0)
        try? f.write(contentsOf: d)
    }
    func append(_ p: UnsafePointer<Float>, _ n: Int) {
        _ = try? fh.seekToEnd()
        try? fh.write(contentsOf: Data(bytes: p, count: n * 4))
        bytes += n * 4
    }
    func sync() {
        func le(_ v: Int) -> Data { var x = UInt32(truncatingIfNeeded: v).littleEndian; return Data(bytes: &x, count: 4) }
        try? fh.seek(toOffset: 4); try? fh.write(contentsOf: le(36 + bytes))
        try? fh.seek(toOffset: 40); try? fh.write(contentsOf: le(bytes))
    }
}

nonisolated final class PopCapture: @unchecked Sendable {
    static let launchArgument = "-popCapture"
    /// Non-nil only in a process launched with `-popCapture`.
    static let armed: PopCapture? = ProcessInfo.processInfo.arguments.contains(launchArgument) ? PopCapture() : nil

    // MARK: Clock
    private static let timebase: mach_timebase_info_data_t = {
        var t = mach_timebase_info_data_t(); mach_timebase_info(&t); return t
    }()
    static func ns(_ ticks: UInt64) -> UInt64 { ticks * UInt64(timebase.numer) / UInt64(timebase.denom) }
    static func nowNs() -> UInt64 { ns(mach_absolute_time()) }

    // MARK: State
    let directory: URL
    private let log = Logger(subsystem: "de.flamingistan.primae", category: "PopCapture")
    private let rtRecs = PopRing<PopRec>(capacityPow2: 1 << 16, zero: PopRec())
    private let tapRecs = PopRing<PopRec>(capacityPow2: 1 << 14, zero: PopRec())
    private let rawRing = PopRing<Float>(capacityPow2: 1 << 19, zero: 0)
    private let mixRing = PopRing<Float>(capacityPow2: 1 << 20, zero: 0)
    private let lock = NSLock()
    private var lines: [String] = []
    private var rawWav: PopWav?, mixWav: PopWav?
    private var rtHandle: FileHandle?, evHandle: FileHandle?
    private let queue = DispatchQueue(label: "popcap.drain", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var tapChannels = 0
    private var scratch: UnsafeMutablePointer<Float>?
    private var tapInstalledOn: AVAudioNode?

    private init() {
        let tag = Self.argument("-popCaptureTag") ?? "run"
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directory = docs.appendingPathComponent("popcap/\(tag)-\(f.string(from: Date()))")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for n in ["rt.tsv", "events.tsv"] { FileManager.default.createFile(atPath: directory.appendingPathComponent(n).path, contents: nil) }
        rtHandle = try? FileHandle(forWritingTo: directory.appendingPathComponent("rt.tsv"))
        evHandle = try? FileHandle(forWritingTo: directory.appendingPathComponent("events.tsv"))
        rawWav = PopWav(url: directory.appendingPathComponent("kernel.wav"), channels: 1, rate: 44_100)
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.05, repeating: 0.05)
        t.setEventHandler { [unowned self] in self.drain() }
        t.resume(); timer = t
        event("capture.start", "dir=\(directory.lastPathComponent) tag=\(tag)")
        observeSession()
    }

    static func argument(_ name: String) -> String? {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
        return a[i + 1]
    }

    // MARK: Any thread except the render and tap threads

    func event(_ kind: String, _ detail: String = "") {
        let line = "\(Self.nowNs())\t\(kind)\t\(detail)\(Thread.isMainThread ? "" : "\tbg")\n"
        lock.lock(); lines.append(line); lock.unlock()
    }

    // MARK: Render thread

    @inline(__always) func renderEnd(start: UInt64, sampleTime: Double, ioHostTime: UInt64, frames: Int,
                                     silent: Bool, out: UnsafePointer<Float>) {
        let end = mach_absolute_time()
        rtRecs.write(PopRec(t: start, kind: 1, a: Int32(frames), x: sampleTime,
                            y: Double(Self.ns(end &- start)), z: Double(Self.ns(ioHostTime))))
        rawRing.write(out, frames)
        _ = silent
    }

    /// kind 2 begin(a = slot, x = rate, y = cents, z = voice), 3 wrap(a = voice, x = rate), 4 voiceEnd(a = voice)
    @inline(__always) func kernelEvent(_ kind: UInt32, a: Int32 = 0, x: Double = 0, y: Double = 0, z: Double = 0) {
        rtRecs.write(PopRec(t: mach_absolute_time(), kind: kind, a: a, x: x, y: y, z: z))
    }

    // MARK: The mixer tap (installed from our code; AudioEngine.swift is not touched)

    func installTap(on node: AVAudioNode) {
        guard tapInstalledOn == nil else { return }
        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0, format.commonFormat == .pcmFormatFloat32 else {
            event("tap.skipped", "format=\(format)"); return
        }
        tapChannels = Int(format.channelCount)
        scratch = .allocate(capacity: 8192 * tapChannels)
        mixWav = PopWav(url: directory.appendingPathComponent("mixer.wav"), channels: tapChannels, rate: Int(format.sampleRate))
        let handler = Self.makeTapHandler(self)
        do {
            try node.installAudioTap(onBus: 0, bufferSize: 1024, format: format, tapProvider: handler)
            tapInstalledOn = node
            event("tap.installed", "rate=\(format.sampleRate) ch=\(format.channelCount)")
        } catch { event("tap.failed", "\(error)") }
    }

    /// Built outside any actor-isolated context (the probe's lesson, AudioSignalProbe.swift).
    nonisolated static func makeTapHandler(_ cap: PopCapture) -> @Sendable (AVReadOnlyAudioPCMBuffer, AVAudioTime) -> Void {
        { buffer, time in
            let start = mach_absolute_time()
            let frames = Int(buffer.frameLength)
            buffer.withUnsafeAudioBufferList { abl in
                cap.tapBuffer(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl)), frames: frames)
            }
            cap.tapRecs.write(PopRec(t: time.isHostTimeValid ? time.hostTime : start, kind: 10, a: Int32(frames),
                                     x: time.isSampleTimeValid ? Double(time.sampleTime) : -1,
                                     y: Double(Self.ns(mach_absolute_time() &- start)), z: 0))
        }
    }

    fileprivate func tapBuffer(_ blocks: UnsafeMutableAudioBufferListPointer, frames: Int) {
        let ch = tapChannels
        if blocks.count == 1, let d = blocks[0].mData {
            mixRing.write(d.assumingMemoryBound(to: Float.self), frames * ch)
        } else if blocks.count == ch, let s = scratch, frames * ch <= 8192 * ch {
            var c = 0
            while c < ch {
                if let d = blocks[c].mData?.assumingMemoryBound(to: Float.self) {
                    var i = 0
                    while i < frames { s[i * ch + c] = d[i]; i += 1 }
                }
                c += 1
            }
            mixRing.write(s, frames * ch)
        }
    }

    // MARK: Drain (utility queue)

    private func drain() {
        var text = ""
        rtRecs.drain { p, n in
            for i in 0..<n { let r = p[i]
                let k = r.kind == 1 ? "R" : "K\(r.kind)"
                text += "\(Self.ns(r.t))\t\(k)\t\(r.a)\t\(r.x)\t\(r.y)\t\(r.z)\n" }
        }
        tapRecs.drain { p, n in
            for i in 0..<n { let r = p[i]; text += "\(Self.ns(r.t))\tT\t\(r.a)\t\(r.x)\t\(r.y)\t\(r.z)\n" }
        }
        if !text.isEmpty { try? rtHandle?.write(contentsOf: Data(text.utf8)) }
        lock.lock(); let ev = lines; lines.removeAll(keepingCapacity: true); lock.unlock()
        if !ev.isEmpty { try? evHandle?.write(contentsOf: Data(ev.joined().utf8)) }
        rawRing.drain { p, n in rawWav?.append(p, n) }
        mixRing.drain { p, n in mixWav?.append(p, n) }
        rawWav?.sync(); mixWav?.sync()
        let meta = "rtDropped=\(rtRecs.dropped.load(ordering: .relaxed)) tapRecDropped=\(tapRecs.dropped.load(ordering: .relaxed)) "
            + "rawDroppedSamples=\(rawRing.dropped.load(ordering: .relaxed)) mixDroppedSamples=\(mixRing.dropped.load(ordering: .relaxed)) "
            + "tapChannels=\(tapChannels) sessionRate=\(AVAudioSession.sharedInstance().sampleRate) "
            + "ioBuffer=\(AVAudioSession.sharedInstance().ioBufferDuration)\n"
        try? meta.write(to: directory.appendingPathComponent("meta.txt"), atomically: true, encoding: .utf8)
    }

    // MARK: Session, route, lifecycle

    private func observeSession() {
        let nc = NotificationCenter.default
        func route() -> String {
            AVAudioSession.sharedInstance().currentRoute.outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        }
        nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { [self] n in
            event("session.route", "reason=\(n.userInfo?[AVAudioSessionRouteChangeReasonKey] ?? "?") route=\(route())")
        }
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [self] n in
            event("session.interruption", "type=\(n.userInfo?[AVAudioSessionInterruptionTypeKey] ?? "?")")
        }
        nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) { [self] _ in
            event("session.mediaReset")
        }
        nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil) { [self] _ in
            event("engine.configChange")
        }
        for (name, label) in [(Notification.Name("UIApplicationDidEnterBackgroundNotification"), "app.background"),
                              (Notification.Name("UIApplicationDidBecomeActiveNotification"), "app.active"),
                              (Notification.Name("UIApplicationWillResignActiveNotification"), "app.resign")] {
            nc.addObserver(forName: name, object: nil, queue: nil) { [self] _ in event(label) }
        }
        event("session.start", "route=\(route()) rate=\(AVAudioSession.sharedInstance().sampleRate) io=\(AVAudioSession.sharedInstance().ioBufferDuration)")
    }
}
#endif
