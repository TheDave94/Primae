// LoopXDiagnosisTests.swift
// PrimaeNativeTests — lane LOOPX (2026-11-03): the diagnosis instrument.
//
// 1. Detector controls: every study source as recorded and steady renders
//    (negative), and planted defects (positive): a hard cut, a hard restart
//    splice, a 3/4-period loop jump, an aligned 1-period jump. Scores are
//    printed ("LOOPX-CTRL"); the test asserts only what the detector must do
//    to be usable as evidence (planted cut found everywhere, steady renders
//    clean outside the onset, the "res" measure live: a reachable threshold
//    and the known residual splices found by it).
// 2. App scenarios S1-S4 (LoopXScenarios) through the real kernel with the
//    app's own constants, both arms, every study source: each event above
//    threshold with its time and the mechanism active then ("LOOPX-SCEN"),
//    and the stereo render written to tmp/loopx-<tree>/ for the listening page.
// Instrument output, run on the physical iPad (the Primae-DeviceTests scheme):
// the counts are read from the log, not asserted, except where noted.

import XCTest
import CoreGraphics
@testable import PrimaeNative

final class LoopXDiagnosisTests: XCTestCase {

    static let sr = LiveSonificationKernel.sampleRate

    @MainActor
    static func constants() -> LoopXConstants {
        LoopXConstants(stall: SoundEnvelope.stallSeconds, hold: SoundEnvelope.liftHoldSeconds,
                       fade: SoundEnvelope.fadeOutSeconds,
                       speed: { v in MainActor.assumeIsolated { TouchDispatcher.mapVelocityToSpeed(v) } },
                       pitch: { y in MainActor.assumeIsolated { SpatialSonification.pitchCents(forNormalizedY: y) } })
    }

    static func steady(_ s: StudySource, seconds: Double, rate: Float) -> [Float] {
        var tl = LoopXTimeline()
        tl.commands = [(0, .rate(rate)), (0, .open(s.name, fadeIn: 0))]
        tl.duration = seconds
        let r = LoopXKernelDriver.render(tl, sources: [s.name: s])
        return zip(r.left, r.right).map { $0 + $1 }   // pan 0: L + R = sqrt 2 x mono; level does not matter
    }

    static func events(_ y: [Float], _ p: LoopXKernelDriver.Profile) -> [LoopXDetector.Event] {
        var e = LoopXDetector.detect(y, sr: sr)
        if let period = p.period { e += LoopXDetector.residual(y, sr: sr, period: period, threshold: p.resThreshold) }
        return LoopXDetector.merge(e, within: 0.010)
    }

    /// Planted splices the "res" measure itself must find (MEASURED, TESTWARN 2026-11-25, iPad). A loop
    /// jump of 3/4 period keeps the level and the spectrum, so `detect` alone misses it in I_phoneme1.
    static let knownResidualCases: Set<String> = ["I_phoneme1 jump3/4P", "spatial_carrier jump3/4P"]

    func testDetectorControls() throws {
        var residualHits: Set<String> = []
        for s in try StudySources.all() {
            let p = LoopXKernelDriver.profile(samples: s.samples, kind: s.kind, spatial: false)
            let y = Self.steady(s, seconds: 1.6, rate: 1)
            var t0 = Int(0.8 * Self.sr)
            for i in t0..<(t0 + 400) where abs(y[i]) > abs(y[t0]) { t0 = i }   // splice at a waveform peak
            let a = TDPSOLAAnalysis.analyse(s.samples, sampleRate: Self.sr, kind: s.kind)
            let period = a.isVoiced ? a.medianPeriod : 0.0025 * Self.sr
            var cut = y; for i in t0..<cut.count { cut[i] = 0 }
            let restart = Array(y[0..<t0]) + Array(y[0..<(y.count - t0)])
            let j34 = Int((0.75 * period).rounded()), j1 = Int(period.rounded())
            let jump = Array(y[0..<t0]) + Array(y[(t0 - j34)..<(y.count - j34)])
            let jump1 = Array(y[0..<t0]) + Array(y[(t0 - j1)..<(y.count - j1)])
            let tc = Double(t0) / Self.sr
            // Each planted signal is analysed once: the printed line and the assertions read the same events.
            var splice: [String: [LoopXDetector.Event]] = [:]
            for (label, x) in [("cut", cut), ("restart", restart), ("jump3/4P", jump), ("jump1P(aligned)", jump1)] {
                let m = Self.events(x, p).filter { abs($0.time - tc) < 0.015 }
                splice[label] = m
                // `kind` of a merged event is "a+b"; "res" among its parts = the residual path found the splice.
                if m.contains(where: { $0.kind.split(separator: "+").contains("res") }) { residualHits.insert("\(s.name) \(label)") }
            }
            func at(_ label: String) -> String {
                let m = splice[label]!.map { "\($0.kind) \(String(format: "%.2f", $0.score))" }
                return m.isEmpty ? "MISSED" : m.joined(separator: ",")
            }
            let end = Double(s.samples.count) / Self.sr - 0.05
            let rawEv = Self.events(s.samples, p).filter { $0.time > 0.15 && $0.time < end }
            let steadyEv = Self.events(y, p).filter { $0.time > 0.05 }
            let slowEv = Self.events(Self.steady(s, seconds: 2.2, rate: 0.7), p).filter { $0.time > 0.05 && $0.time < 2.15 }
            print("LOOPX-CTRL \(s.name) resThreshold \(String(format: "%.2f", p.resThreshold)) | NEG raw \(rawEv.count) \(rawEv.map(\.description)) | steady r1 \(steadyEv.count) | steady r0.7 \(slowEv.count) \(slowEv.map(\.description))")
            print("LOOPX-CTRL \(s.name) | POS cut: \(at("cut")) | restart: \(at("restart")) | jump3/4P: \(at("jump3/4P")) | jump1P(aligned): \(at("jump1P(aligned)"))")
            XCTAssertNotEqual(at("cut"), "MISSED", "\(s.name): a planted hard cut was not detected")
            XCTAssertEqual(steadyEv.count, 0, "\(s.name): events in a steady rate-1 render: \(steadyEv)")
            // A "res" score is 1 - (best normalised correlation), so it never exceeds 1: a self-calibrated
            // threshold >= 1 can never fire, i.e. the residual measure is inert for this source.
            if p.period != nil {
                XCTAssertLessThan(p.resThreshold, 1, "\(s.name): residual threshold \(p.resThreshold) is unreachable (>= 1): the res path is inert")
            }
        }
        for c in Self.knownResidualCases.sorted() {
            XCTAssertTrue(residualHits.contains(c), "\(c): the residual path did not find the planted splice (res hits: \(residualHits.sorted()))")
        }
    }

    @MainActor
    func testAppScenarios() async throws {
        // SEAM2 (2026-11-04): a diagnostic, not a regression pin (LoopXRegressionTests are the pins). 46 kernel renders
        // of 8-13 s each: 21 s at -O, ~30 s per render at -Onone (Debug-Study, MEASURED on the iPad), ~23 min serial.
        // Each render owns its kernel and touches no shared state, so they run across the cores; the scenario
        // timelines (which read the app's MainActor constants) are built here first, and the lines print in
        // catalogue order afterwards. Runs on the iPad in the Primae-DeviceTests scheme, unconditionally.
        // The renders run OFF the main thread, at user-initiated QoS, on all cores but two (TESTWARN, 2026-11-24, MEASURED):
        // a concurrentPerform called from the main thread inherits user-interactive QoS and took all 8 cores of the
        // iPad; the stackshot at 23:20:48 showed 8 Primae threads in TH_RUN at QOS_CLASS_USER_INTERACTIVE, 74 MB
        // resident, no memory pressure, while bluetoothd timed out its XPC ("BT XPC Timeout"), and the test host was
        // SIGKILLed 5 m 27 s in ("Test crashed with signal kill", no crash report). At utility QoS the run passed but
        // took 1658 s, slower than serial.
        let names = StudySources.names
        let phonemes = names.filter { $0 != "spatial_carrier" }
        var src: [String: StudySource] = [:]
        var prof: [String: LoopXKernelDriver.Profile] = [:]
        for n in names {
            let s = try StudySources.load(n); src[n] = s
            prof[n] = LoopXKernelDriver.profile(samples: s.samples, kind: s.kind, spatial: false)
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("loopx-\(LoopXKernelDriver.treeTag)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let cases = LoopXScenarioBuilder.catalogue(phonemes: phonemes, carrier: "spatial_carrier", k: Self.constants())
        XCTAssertFalse(cases.isEmpty, "the scenario catalogue is empty: nothing was diagnosed")
        let results = LoopXScenarioResults(count: cases.count)
        let (sources, profiles, sr) = (src, prof, Self.sr)
        let workers = max(1, min(cases.count, ProcessInfo.processInfo.activeProcessorCount - 2))
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                DispatchQueue.concurrentPerform(iterations: workers) { _ in
                    while let i = results.claim() {
                        let c = cases[i]
                        var sub: [String: StudySource] = [:]
                        for f in c.files { sub[f] = sources[f] }
                        let r = LoopXKernelDriver.render(c.timeline, sources: sub)
                        let ps = c.files.map { profiles[$0]! }
                        let periods = ps.compactMap(\.period)
                        let period = periods.count == ps.count
                            ? periods.dropFirst().reduce(periods[0]) { min($0.lowerBound, $1.lowerBound)...max($0.upperBound, $1.upperBound) } : nil
                        let e = LoopXDetector.detect(left: r.left, right: r.right, sr: sr, marks: r.marks,
                                                     period: period, resThreshold: ps.map(\.resThreshold).max()!)
                        let wraps = r.marks.filter { $0.label == "wrap" }.count
                        let line = "LOOPX-SCEN \(c.name) | \(c.arm) \(c.files.joined(separator: "+")) | wraps \(wraps) | events \(e.count): \(e.map(\.description).joined(separator: "; "))"
                        let fn = "\(c.name)-\(c.arm)-\(c.files.joined(separator: "+"))"
                            .replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "/", with: "-")
                        let written: Error?
                        do { try LoopXDetector.writeWAV([r.left, r.right], sr: sr, to: dir.appendingPathComponent("\(fn).wav")); written = nil }
                        catch { written = error }
                        results.set(i, .init(line: line, mechanisms: e.map(\.mechanism), writeError: written))
                    }
                }
                done.resume()
            }
        }
        var totals: [String: Int] = [:]
        for (i, r) in results.all.enumerated() {
            guard let r else { XCTFail("scenario \(cases[i].name) produced no result"); continue }
            print(r.line)
            for m in r.mechanisms { totals[m, default: 0] += 1 }
            if let err = r.writeError { XCTFail("scenario \(cases[i].name): WAV not written: \(err)") }
        }
        print("LOOPX-TOTALS \(LoopXKernelDriver.treeTag) \(totals.sorted { $0.key < $1.key })")
        print("LOOPX-WAVDIR \(dir.path)")
    }
}

/// One scenario's output, gathered from the concurrent renders and printed in order.
private nonisolated final class LoopXScenarioResults: @unchecked Sendable {
    struct Result { let line: String; let mechanisms: [String]; let writeError: Error? }
    private let lock = NSLock()
    private var slots: [Result?]
    private var next = 0
    init(count: Int) { slots = Array(repeating: nil, count: count) }
    /// The next scenario index for a worker, or nil when every scenario is taken.
    func claim() -> Int? { lock.withLock { guard next < slots.count else { return nil }; defer { next += 1 }; return next } }
    func set(_ i: Int, _ r: Result) { lock.withLock { slots[i] = r } }
    var all: [Result?] { lock.withLock { slots } }
}
