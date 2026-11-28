// SonificationBakeoffBench.swift
// PrimaeNativeTests — sonification bake-off harness (BENCH 2026-11-02; pitch phase 2 2026-11-23; r31 BENCH-R31 2026-11-28)
//
// THE BENCH. Opt-in: it runs only when the test process has `PRIMAE_BAKEOFF` in its environment, so an ordinary suite
// run skips it (and `Primae.xcscheme` skips `SonificationBakeoffBench`; `Primae-DeviceTests` runs it).
//
//   pitch        r31 pitch bench: the five study phonemes x PitchScenarios.standard at 48 kHz (the iPad output rate;
//                override with `PRIMAE_BAKEOFF_RATE=44100`), 8-seed spread with per-cell xor seeds for seed-dependent
//                candidates (override with `PRIMAE_BAKEOFF_SEEDS`), gated on median-of-N.
//   pitch-quick  rate 1 only, A and F only.
//   full, quick  r17 time-stretch scenarios.
//
// Optional `PRIMAE_BAKEOFF_CANDIDATES` = comma-separated candidate names (e.g. `r31` or `ours,NaiveResample,TDPSOLA2-g0.3,r31`).
// Optional `PRIMAE_BAKEOFF_NO_WAV=1` skips writing float32 listening renders to save disk space.
//
// Output in the test host's container, Documents/bakeoff/:
//   bench.csv      candidate,source,kind,sample_rate,scenario,metric,value,unit
//   gates.csv      candidate,source,scenario,gate,value,threshold,pass,seed_count,seed_pass,seed_min,seed_max
//   run_info.json  device, OS, build flavour, mode, sample_rate, seed_count, candidates, gate_summary, timings

import XCTest
@testable import PrimaeNative

final class SonificationBakeoffBench: XCTestCase {

    @MainActor
    func testRunBench() throws {
        let env = ProcessInfo.processInfo.environment
        guard let mode = env["PRIMAE_BAKEOFF"], ["pitch", "pitch-quick", "full", "quick"].contains(mode) else {
            throw XCTSkip("bench is opt-in: set PRIMAE_BAKEOFF=pitch|pitch-quick|full|quick in the test environment")
        }
        let filter = env["PRIMAE_BAKEOFF_CANDIDATES"].map {
            Set($0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        }
        let candidates = BakeoffCandidates.all.filter { filter?.contains($0.name) ?? true }
        XCTAssertFalse(candidates.isEmpty, "no registered candidate matches PRIMAE_BAKEOFF_CANDIDATES")
        let sr = env["PRIMAE_BAKEOFF_RATE"].flatMap(Double.init) ?? BakeoffSources.pitchSampleRate
        let seedCount = max(1, env["PRIMAE_BAKEOFF_SEEDS"].flatMap(Int.init) ?? PitchRunner.baseSeedXors.count)
        let writeWAVs = env["PRIMAE_BAKEOFF_NO_WAV"] != "1"

        let docs = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        let root = docs.appendingPathComponent("bakeoff", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let started = Date()
        let csvURL = root.appendingPathComponent("bench.csv")
        let gatesURL = root.appendingPathComponent("gates.csv")
        var gateSummary: [String: [String: Int]] = [:]

        if mode.hasPrefix("pitch") {
            gateSummary = try runPitch(quick: mode == "pitch-quick", sampleRate: sr, seedCount: seedCount,
                                       writeWAVs: writeWAVs, candidates: candidates, root: root,
                                       csvURL: csvURL, gatesURL: gatesURL)
        } else {
            try runR17(quick: mode == "quick", candidates: candidates, root: root, csvURL: csvURL)
        }

        var machine = utsname()
        uname(&machine)
        let model = withUnsafeBytes(of: &machine.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        #if DEBUG
        let flavour = "DEBUG (-Onone test target; candidate module per its own configuration)"
        #else
        let flavour = "non-DEBUG (optimised)"
        #endif
        let info: [String: Any] = [
            "date": ISO8601DateFormatter().string(from: started),
            "seconds": Date().timeIntervalSince(started),
            "mode": mode,
            "device": model,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "build": flavour,
            "candidates": candidates.map(\.name),
            "buffer_frames": BakeoffRunner.bufferFrames,
            "sample_rate": mode.hasPrefix("pitch") ? sr : LiveSonificationKernel.referenceSampleRate,
            "seed_count": seedCount,
            "seed_statistic": "median",
            "gate_summary": gateSummary,
        ]
        try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("run_info.json"))

        for url in [csvURL, gatesURL] where FileManager.default.fileExists(atPath: url.path) {
            let attachment = XCTAttachment(contentsOfFile: url)
            attachment.name = url.lastPathComponent
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        // Optional strict-pass assertion when requested (default off: bench records all PASS/FAIL rows honestly to gates.csv).
        if mode.hasPrefix("pitch"), let r31 = gateSummary["r31"], env["PRIMAE_BAKEOFF_ASSERT_ZERO_FAILS"] == "1" {
            let fails = r31["fail"] ?? 0
            let passes = r31["pass"] ?? 0
            XCTAssertEqual(fails, 0, "r31 pitch bench had \(fails) failing gate(s) out of \(passes + fails) at \(Int(sr)) Hz (\(seedCount) seeds)")
        }
    }

    /// Listening-render filename for a pitch scenario, or nil when this scenario is not exported.
    static func renderName(scenario: BakeoffScenario, letter: String) -> String? {
        switch scenario.family {
        case .heldPitch(let c, let r) where r == 1:
            return c == 0 ? "\(letter)__0c.wav" : String(format: "%@__%+dc.wav", letter, Int(c))
        case .pitchSweep(let r, _) where r == 1:
            return "\(letter)__traj.wav"
        case .trajectory where scenario.name.hasSuffix("_height"):
            return "\(letter)__height.wav"
        default:
            return nil
        }
    }

    // swiftlint:disable:next function_body_length
    @MainActor
    private func runPitch(quick: Bool, sampleRate sr: Double, seedCount: Int, writeWAVs: Bool,
                          candidates: [BakeoffCandidate], root: URL, csvURL: URL, gatesURL: URL)
        throws -> [String: [String: Int]] {
        var csv = BakeoffRow.header + "\n"
        var gates = PitchGateRow.header + "\n"
        var passCounts: [String: Int] = [:]
        var failCounts: [String: Int] = [:]
        let letters = quick ? ["A", "F"] : TrainedLetterSubset.studyLetters
        let sources = try BakeoffSources.pitchSources(letters: letters, sampleRate: sr)
        let rates = quick ? [Float(1)] : PitchScenarios.rates

        for source in sources {
            let ref = PitchSourceRef(source)
            csv += BakeoffRow(candidate: "Source", source: source.name, kind: source.kindLabel,
                              sampleRate: Int(source.sampleRate), scenario: "-", metric: "voiced_fraction",
                              value: source.voicedFraction, unit: "frac").csv + "\n"
            if let f0 = ref.f0 {
                csv += BakeoffRow(candidate: "Source", source: source.name, kind: source.kindLabel,
                                  sampleRate: Int(source.sampleRate), scenario: "-", metric: "f0_hz",
                                  value: f0, unit: "Hz").csv + "\n"
            }
            if let p = ref.perturbation {
                for (m, v) in [("jitter_pct", p.jitterPct), ("shimmer_pct", p.shimmerPct)] {
                    csv += BakeoffRow(candidate: "Source", source: source.name, kind: source.kindLabel,
                                      sampleRate: Int(source.sampleRate), scenario: "-", metric: m,
                                      value: v, unit: "%").csv + "\n"
                }
            }
            let scenarios = try PitchScenarios.standard(letter: source.letter, sampleRate: source.sampleRate,
                                                        rates: rates, loopSeconds: source.loopSeconds)
            // Build one invariant analysis template per (candidate, source) so seed > 0 runs stay fast & bit-identical.
            var templates: [String: TDPSOLA2] = [:]
            for c in candidates where c.isSeedDependent {
                if let t = BakeoffRunner.template(c, source: source) { templates[c.name] = t }
            }
            // Collect per-seed shifted LSD values per candidate for the per-letter `env_lsd_letter_vs_praat` gate.
            var shiftedLSDByCandSeed: [String: [[Double]]] = [:]

            for scenario in scenarios {
                let sourceRef = BakeoffRunner.sourceReference(source: source, scenario: scenario)
                let isShiftedVoicedHeld: Bool = {
                    if case .heldPitch(let c, _) = scenario.family, ref.isVoiced, c != 0 { return true }
                    return false
                }()
                for candidate in candidates {
                    let useSpread = candidate.isSeedDependent && ref.isVoiced && scenario.name != "gate_cycle" && seedCount > 1
                    let nSeeds = useSpread ? seedCount : 1
                    var seedOutputs: [PitchRunner.Output] = []
                    seedOutputs.reserveCapacity(nSeeds)
                    var render0: BakeoffRender?
                    if isShiftedVoicedHeld && shiftedLSDByCandSeed[candidate.name] == nil {
                        shiftedLSDByCandSeed[candidate.name] = Array(repeating: [], count: nSeeds)
                    }
                    for si in 0..<nSeeds {
                        let xor = useSpread
                            ? PitchRunner.cellSeedXor(source: source.name, scenario: scenario.name, seedIndex: si)
                            : 0
                        let tmpl = si > 0 ? templates[candidate.name] : nil
                        let render = BakeoffRunner.render(candidate, source: source, scenario: scenario,
                                                          seedXor: xor, template: tmpl)
                        if si == 0 { render0 = render }
                        let out = PitchRunner.rows(candidate: candidate.name, render: render, ref: ref,
                                                   scenario: scenario, zeroKeySuffix: "#\(si)",
                                                   computeFramewiseLSD: si == 0)
                        seedOutputs.append(out)
                        if isShiftedVoicedHeld, let lsd = out.rows.first(where: { $0.metric == "env_lsd_db" })?.value {
                            shiftedLSDByCandSeed[candidate.name]?[si].append(lsd)
                        }
                    }
                    let agg = PitchRunner.aggregateSeedSpread(seedOutputs)
                    let r17 = render0.map {
                        BakeoffRunner.metrics(candidate: candidate.name, render: $0, source: source,
                                              scenario: scenario, sourceRef: sourceRef, reference: nil)
                    } ?? []
                    for row in r17 + agg.rows { csv += row.csv + "\n" }
                    for g in agg.gates {
                        gates += g.csv + "\n"
                        if g.result.pass { passCounts[candidate.name, default: 0] += 1 }
                        else { failCounts[candidate.name, default: 0] += 1 }
                    }
                    if writeWAVs, let r0 = render0, let letter = source.letter,
                       let name = Self.renderName(scenario: scenario, letter: letter) {
                        try BakeoffWAV.writeFloat(r0.samples.map { $0 * source.gain }, sampleRate: source.sampleRate,
                                                  to: root.appendingPathComponent("renders/\(candidate.name)/\(name)"))
                    }
                }
            }

            // Emit the per-letter shifted LSD mean gate (`<= 1.2 x` Praat per-letter mean) for each candidate.
            if ref.isVoiced, let letter = source.letter {
                for candidate in candidates {
                    guard let perSeed = shiftedLSDByCandSeed[candidate.name], !perSeed.isEmpty else { continue }
                    let seedMeans = perSeed.compactMap { arr -> Double? in
                        arr.isEmpty ? nil : arr.reduce(0, +) / Double(arr.count)
                    }
                    guard !seedMeans.isEmpty,
                          let medMean = PitchMetrics.median(seedMeans),
                          var res = PitchGates.envelopeLetterMeanLSD(medMean, letter: letter, sampleRate: sr) else {
                        continue
                    }
                    let seedPass = seedMeans.filter { res.predicate($0) }.count
                    res.spread = PitchGates.Spread(min: seedMeans.min() ?? medMean, max: seedMeans.max() ?? medMean,
                                                   passCount: seedPass, total: seedMeans.count)
                    let row = PitchGateRow(candidate: candidate.name, source: source.name,
                                           scenario: "letter_shifted_mean", result: res)
                    gates += row.csv + "\n"
                    csv += BakeoffRow(candidate: candidate.name, source: source.name, kind: source.kindLabel,
                                      sampleRate: Int(sr), scenario: "letter_shifted_mean",
                                      metric: "env_lsd_letter_mean_db", value: medMean, unit: "dB").csv + "\n"
                    if res.pass { passCounts[candidate.name, default: 0] += 1 }
                    else { failCounts[candidate.name, default: 0] += 1 }
                }
            }

            // Flush per source so a killed run still leaves data.
            try csv.write(to: csvURL, atomically: true, encoding: .utf8)
            try gates.write(to: gatesURL, atomically: true, encoding: .utf8)
        }

        var summary: [String: [String: Int]] = [:]
        for c in candidates {
            let p = passCounts[c.name, default: 0], f = failCounts[c.name, default: 0]
            summary[c.name] = ["pass": p, "fail": f]
            print("PITCHBENCH \(c.name) @\(Int(sr))Hz seeds=\(seedCount): PASS \(p) / FAIL \(f)")
        }
        return summary
    }

    private func runR17(quick: Bool, candidates: [BakeoffCandidate], root: URL, csvURL: URL) throws {
        var csv = BakeoffRow.header + "\n"
        let sr = LiveSonificationKernel.referenceSampleRate
        var sources = try BakeoffSources.all(sampleRate: sr)
        if quick { sources = sources.filter { ["A_phoneme1", "F_phoneme1", "spatial_carrier", "probe_sweep"].contains($0.name) } }
        for source in sources {
            let trajLetters = quick ? ["A"] : TrainedLetterSubset.studyLetters
            var scenarios = try BakeoffScenarios.standard(for: source, includeTrajectories: true,
                                                          trajectoryLetters: trajLetters)
            if quick && source.kind != .carrier {
                scenarios = scenarios.filter { !$0.name.hasPrefix("traj_") || $0.name.hasPrefix("traj_A_") }
            }
            for scenario in scenarios {
                let sourceRef = BakeoffRunner.sourceReference(source: source, scenario: scenario)
                try BakeoffWAV.write(sourceRef.samples, sampleRate: sr,
                                     to: root.appendingPathComponent("wav/\(scenario.name)/\(source.name)/Source.wav"))
                for candidate in candidates {
                    let render = BakeoffRunner.render(candidate, source: source, scenario: scenario)
                    let rows = BakeoffRunner.metrics(candidate: candidate.name, render: render, source: source,
                                                     scenario: scenario, sourceRef: sourceRef, reference: nil)
                    for row in rows { csv += row.csv + "\n" }
                    try BakeoffWAV.write(render.samples, sampleRate: sr, to: root.appendingPathComponent(
                        "wav/\(scenario.name)/\(source.name)/\(candidate.name).wav"))
                }
            }
            try csv.write(to: csvURL, atomically: true, encoding: .utf8)
        }
    }
}
