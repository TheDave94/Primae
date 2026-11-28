// main.swift — ENVGAP offline pitch bench driver. A line-for-line port of
// SonificationBakeoffBench.runPitch (BENCH-R31 worktree) without XCTest: same sources, scenarios, seed derivation,
// median-of-N aggregation, per-letter mean gate. Output: <out>/gates.csv, <out>/bench.csv.
// Env: PRIMAE_RES (resources root), RATE (48000|44100), SEEDS (8), CANDS (comma list), OUT (dir), LETTERS (opt).
import Foundation
@testable import PrimaeNative

@MainActor func runMain() throws {
    let env = ProcessInfo.processInfo.environment
    let sr = env["RATE"].flatMap(Double.init) ?? 48_000
    let seedCount = max(1, env["SEEDS"].flatMap(Int.init) ?? PitchRunner.baseSeedXors.count)
    let pool = BakeoffCandidates.all + EnvgapCandidates.all + EnvgapACandidates.all
    let filter = env["CANDS"].map { Set($0.split(separator: ",").map { String($0) }) }
    let candidates = pool.filter { filter?.contains($0.name) ?? true }
    precondition(!candidates.isEmpty, "no candidate matches CANDS")
    let root = URL(fileURLWithPath: env["OUT"] ?? "envgap_out")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let csvURL = root.appendingPathComponent("bench.csv")
    let gatesURL = root.appendingPathComponent("gates.csv")
    var csv = BakeoffRow.header + "\n"
    var gates = PitchGateRow.header + "\n"
    var passCounts: [String: Int] = [:]
    var failCounts: [String: Int] = [:]
    let letters = env["LETTERS"].map { $0.split(separator: ",").map(String.init) } ?? TrainedLetterSubset.studyLetters
    let sources = try BakeoffSources.pitchSources(letters: letters, sampleRate: sr)
    let rates = PitchScenarios.rates
    let scenFilter = env["SCEN"].map { Set($0.split(separator: ",").map(String.init)) }
    let t0 = Date()

    for source in sources {
        let ref = PitchSourceRef(source)
        try RenderDump.writeSource(ref)
        var scenarios = try PitchScenarios.standard(letter: source.letter, sampleRate: source.sampleRate,
                                                    rates: rates, loopSeconds: source.loopSeconds)
        if let sf = scenFilter { scenarios = scenarios.filter { sf.contains($0.name) || $0.name.hasPrefix("pitch_0@") } }
        var templates: [String: TDPSOLA2] = [:]
        for c in candidates where c.isSeedDependent {
            if let t = BakeoffRunner.template(c, source: source) { templates[c.name] = t }
        }
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
                var render0: BakeoffRender?
                if isShiftedVoicedHeld && shiftedLSDByCandSeed[candidate.name] == nil {
                    shiftedLSDByCandSeed[candidate.name] = Array(repeating: [], count: nSeeds)
                }
                for si in 0..<nSeeds {
                    let xor = useSpread
                        ? PitchRunner.cellSeedXor(source: source.name, scenario: scenario.name, seedIndex: si) : 0
                    let tmpl = si > 0 ? templates[candidate.name] : nil
                    let render = BakeoffRunner.render(candidate, source: source, scenario: scenario,
                                                      seedXor: xor, template: tmpl)
                    if si == 0 { render0 = render }
                    if case .heldPitch(_, let r) = scenario.family,
                       RenderDump.wants(candidate: candidate.name, source: source.name, scenario: scenario.name) {
                        let w = PitchRunner.heldWindow(count: render.samples.count, sampleRate: source.sampleRate,
                                                       rate: r, loopSeconds: source.loopSeconds)
                        try RenderDump.writeRender(render.samples[w], sampleRate: source.sampleRate,
                                                   candidate: candidate.name, source: source.name,
                                                   scenario: scenario.name, seed: si)
                    }
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
            }
        }
        if ref.isVoiced, let letter = source.letter, scenFilter == nil {
            for candidate in candidates {
                guard let perSeed = shiftedLSDByCandSeed[candidate.name], !perSeed.isEmpty else { continue }
                let seedMeans = perSeed.compactMap { arr -> Double? in arr.isEmpty ? nil : arr.reduce(0, +) / Double(arr.count) }
                guard !seedMeans.isEmpty, let medMean = PitchMetrics.median(seedMeans),
                      var res = PitchGates.envelopeLetterMeanLSD(medMean, letter: letter, sampleRate: sr) else { continue }
                let seedPass = seedMeans.filter { res.predicate($0) }.count
                res.spread = PitchGates.Spread(min: seedMeans.min() ?? medMean, max: seedMeans.max() ?? medMean,
                                               passCount: seedPass, total: seedMeans.count)
                gates += PitchGateRow(candidate: candidate.name, source: source.name,
                                      scenario: "letter_shifted_mean", result: res).csv + "\n"
                if res.pass { passCounts[candidate.name, default: 0] += 1 } else { failCounts[candidate.name, default: 0] += 1 }
            }
        }
        try csv.write(to: csvURL, atomically: false, encoding: .utf8)
        try gates.write(to: gatesURL, atomically: false, encoding: .utf8)
        FileHandle.standardError.write("done \(source.name) t=\(Int(Date().timeIntervalSince(t0)))s\n".data(using: .utf8)!)
    }
    for c in candidates {
        print("PITCHBENCH \(c.name) @\(Int(sr))Hz seeds=\(seedCount): PASS \(passCounts[c.name, default: 0]) / FAIL \(failCounts[c.name, default: 0])")
    }
}

try MainActor.assumeIsolated {
    switch ProcessInfo.processInfo.environment["MODE"] {
    case "envdump": try envDump()
    case "stages": try loopStages()
    case "seam": try seamCheck()
    case "perturb": try perturbDump()
    default: try runMain()
    }
}
