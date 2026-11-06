// LoopXDiagnosisTests.swift
// PrimaeNativeTests — lane LOOPX (2026-11-03): the diagnosis instrument.
//
// 1. Detector controls: every study source as recorded and steady renders
//    (negative), and planted defects (positive): a hard cut, a hard restart
//    splice, a 3/4-period loop jump, an aligned 1-period jump. Scores are
//    printed ("LOOPX-CTRL"); the test asserts only what the detector must do
//    to be usable as evidence (planted cut found everywhere, steady renders
//    clean outside the onset).
// 2. App scenarios S1-S4 (LoopXScenarios) through the real kernel with the
//    app's own constants, both arms, every study source: each event above
//    threshold with its time and the mechanism active then ("LOOPX-SCEN"),
//    and the stereo render written to tmp/loopx-<tree>/ for the listening page.
// Instrument output, run on the physical iPad (Release-Study, testability):
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

    func testDetectorControls() throws {
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
            func at(_ x: [Float]) -> String {
                let m = Self.events(x, p).filter { abs($0.time - tc) < 0.015 }.map { "\($0.kind) \(String(format: "%.2f", $0.score))" }
                return m.isEmpty ? "MISSED" : m.joined(separator: ",")
            }
            let end = Double(s.samples.count) / Self.sr - 0.05
            let rawEv = Self.events(s.samples, p).filter { $0.time > 0.15 && $0.time < end }
            let steadyEv = Self.events(y, p).filter { $0.time > 0.05 }
            let slowEv = Self.events(Self.steady(s, seconds: 2.2, rate: 0.7), p).filter { $0.time > 0.05 && $0.time < 2.15 }
            print("LOOPX-CTRL \(s.name) resThreshold \(String(format: "%.2f", p.resThreshold)) | NEG raw \(rawEv.count) \(rawEv.map(\.description)) | steady r1 \(steadyEv.count) | steady r0.7 \(slowEv.count) \(slowEv.map(\.description))")
            print("LOOPX-CTRL \(s.name) | POS cut: \(at(cut)) | restart: \(at(restart)) | jump3/4P: \(at(jump)) | jump1P(aligned): \(at(jump1))")
            XCTAssertNotEqual(at(cut), "MISSED", "\(s.name): a planted hard cut was not detected")
            XCTAssertEqual(steadyEv.count, 0, "\(s.name): events in a steady rate-1 render: \(steadyEv)")
        }
    }

    @MainActor
    func testAppScenarios() throws {
        // SEAM2 (2026-11-04): a diagnostic, not a regression pin (LoopXRegressionTests are the pins). 46 kernel renders
        // of 8-13 s each: 21 s at -O (Release-Study), but ~30 s per render at -Onone (Debug-Study, the CI and default
        // scheme configuration: 21 of 46 after 10 min on the iPad, still progressing, MEASURED), which overran a 30 min
        // suite limit. It runs in Release-Study only.
        #if DEBUG
        throw XCTSkip("LOOPX scenario diagnostic: ~25 min at -Onone; runs in Release-Study (21 s)")
        #endif
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
        var totals: [String: Int] = [:]
        for c in LoopXScenarioBuilder.catalogue(phonemes: phonemes, carrier: "spatial_carrier", k: Self.constants()) {
            var sub: [String: StudySource] = [:]
            for f in c.files { sub[f] = src[f] }
            let r = LoopXKernelDriver.render(c.timeline, sources: sub)
            let ps = c.files.map { prof[$0]! }
            let periods = ps.compactMap(\.period)
            let period = periods.count == ps.count
                ? periods.dropFirst().reduce(periods[0]) { min($0.lowerBound, $1.lowerBound)...max($0.upperBound, $1.upperBound) } : nil
            let e = LoopXDetector.detect(left: r.left, right: r.right, sr: Self.sr, marks: r.marks,
                                         period: period, resThreshold: ps.map(\.resThreshold).max()!)
            for x in e { totals[x.mechanism, default: 0] += 1 }
            let wraps = r.marks.filter { $0.label == "wrap" }.count
            print("LOOPX-SCEN \(c.name) | \(c.arm) \(c.files.joined(separator: "+")) | wraps \(wraps) | events \(e.count): \(e.map(\.description).joined(separator: "; "))")
            let fn = "\(c.name)-\(c.arm)-\(c.files.joined(separator: "+"))"
                .replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "/", with: "-")
            try LoopXDetector.writeWAV([r.left, r.right], sr: Self.sr, to: dir.appendingPathComponent("\(fn).wav"))
        }
        print("LOOPX-TOTALS \(LoopXKernelDriver.treeTag) \(totals.sorted { $0.key < $1.key })")
        print("LOOPX-WAVDIR \(dir.path)")
    }
}
