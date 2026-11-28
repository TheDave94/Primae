// LoopStages.swift — lane ENVGAP-A: per-stage decomposition of the voiced loop path's envelope floor, per seed.
// MODE=stages. For each letter, each loop-preparation variant (TDPSOLATuning with one stage removed) and each seed:
//   (a) an identity "tile play" of the variant's prepared buffer at rate 1 (out[t] = buf[wrap(onset + t)], the
//       renderer's own wrap rule and loop bounds), measured over the gate's own held window;
//   (b) the 0 c renders at @0.5/@1/@2 and every shifted held cell, with the gate's own env_lsd measure
//       (LTAS nfft 4096 -> true envelope at order 0.5 fs / 360 -> level-free LSD 150-5000 Hz vs the steady segment).
// Plus metric controls on the source itself (steady halves, the raw loop as one slice vs tiled).
// Env: RATE, SEEDS, LETTERS, OUT, VARIANTS (opt, comma list of variant names), OPTS (opt: ENVGAP-A option preset).
// Output: <OUT>/stages.csv  (letter,rate_hz,variant,stage,seed,lsd)
import Foundation
@testable import PrimaeNative

@MainActor func loopStages() throws {
    let env = ProcessInfo.processInfo.environment
    let sr = env["RATE"].flatMap(Double.init) ?? 48_000
    let seedCount = max(1, env["SEEDS"].flatMap(Int.init) ?? 8)
    let letters = env["LETTERS"].map { $0.split(separator: ",").map(String.init) } ?? TrainedLetterSubset.studyLetters
    let out = URL(fileURLWithPath: env["OUT"] ?? "stages_out")
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let base = TDPSOLATuning.default
    var variants: [(String, TDPSOLATuning)] = [
        ("prod", base),
        ("noTDQ", { var t = base; t.pulseCrestCap = 0; return t }()),
        ("noXF", { var t = base; t.loopCrossfadeSeconds = 0; return t }()),
        ("noFlat", { var t = base; t.loopFlattenDB = 0; return t }()),
        ("noSeam", { var t = base; t.loopCrossfadeSeconds = 0; t.loopFlattenDB = 0; return t }()),
        ("none", { var t = base; t.loopCrossfadeSeconds = 0; t.loopFlattenDB = 0; t.pulseCrestCap = 0; return t }()),
        ("xf0.2", { var t = base; t.loopCrossfadeSeconds = 0.2; return t }()),
        ("xf0.1", { var t = base; t.loopCrossfadeSeconds = 0.1; return t }()),
        ("xf0.05", { var t = base; t.loopCrossfadeSeconds = 0.05; return t }()),
    ]
    if let vf = env["VARIANTS"] { let s = Set(vf.split(separator: ",").map(String.init)); variants = variants.filter { s.contains($0.0) } }
    let options = envgapAOptions(env["OPTS"] ?? "production")
    var csv = "letter,rate_hz,variant,stage,seed,lsd\n"
    let frame: (Double) -> Int = { Int(($0 * sr).rounded()) }
    let altRef = env["ALTREF"] == "1"
    let sources = try BakeoffSources.pitchSources(letters: letters, sampleRate: sr)
    for src in sources {
        let ref = PitchSourceRef(src)
        let letter = src.letter ?? src.name
        func lsd(_ y: ArraySlice<Float>) -> Double {
            let e = PitchMetrics.envelopeDB(ltas: PitchMetrics.ltas(y, sampleRate: sr), sampleRate: sr, f0max: 360)
            return PitchMetrics.envelopeCompare(f: e.f, source: ref.envelope.e, output: e.e, refine: false).lsd
        }
        func row(_ v: String, _ stage: String, _ seed: Int, _ x: Double) {
            csv += "\(letter),\(Int(sr)),\(v),\(stage),\(seed),\(String(format: "%.5f", x))\n"
        }
        // Metric controls on the source itself.
        let st = src.steadyRange
        let mid = (st.lowerBound + st.upperBound) / 2
        row("src", "steady_first_half", 0, lsd(src.samples[st.lowerBound..<mid]))
        row("src", "steady_second_half", 0, lsd(src.samples[mid..<st.upperBound]))
        let scenarios = try PitchScenarios.standard(letter: letter, sampleRate: sr, rates: PitchScenarios.rates,
                                                    loopSeconds: src.loopSeconds)
            .filter { if case .heldPitch = $0.family { return true }; return false }
        for (vname, tuning) in variants {
            let t0 = TDPSOLA2(source: src.samples, sampleRate: sr, kind: src.kind,
                              maxFramesPerRender: LiveSonificationKernel.chunkFrames, tuning: tuning, options: options,
                              onset: src.onset, outputGain: src.gain, file: src.fileSource)
            let a = t0.analysis
            if a.isVoiced {
                // (a) identity tile play of the prepared buffer (and of the raw source over the same bounds).
                let prep = TDPSOLA2.prepared(src.samples, sampleRate: sr, analysis: a, kind: src.kind, tuning: tuning,
                                             outputGain: src.gain, seam: options.seamBlend)
                let wd = PitchScenarios.heldAnalysisDuration(rate: 1, loopSeconds: src.loopSeconds)
                func tile(_ buf: [Float], loopEnd: Double) -> [Float] {
                    let ls = a.loopStart, ll = max(1, loopEnd - ls)
                    let n = frame(wd)
                    var y = [Float](repeating: 0, count: n)
                    for i in 0..<n {
                        var p = Double(a.onset) + 0.6 * sr + Double(i)
                        while p >= loopEnd { p -= ll }
                        let k = Int(p), f = Float(p - Double(k))
                        y[i] = buf[k] * (1 - f) + buf[min(buf.count - 1, k + 1)] * f
                    }
                    return y
                }
                row(vname, "tile_prepared@1", 0, lsd(tile(prep.played, loopEnd: prep.loopEnd)[...]))
                row(vname, "tile_raw_same_bounds@1", 0, lsd(tile(src.samples, loopEnd: prep.loopEnd)[...]))
                row(vname, "slice_prepared_played_loop", 0,
                    lsd(prep.played[Int(a.loopStart.rounded(.up))..<Int(prep.loopEnd.rounded(.down))]))
                if env["DUMP"] == "1" {
                    // Envelope curves (dB, the gate's measure) of the loop's parts, for the mechanism analysis.
                    let ls = Int(a.loopStart.rounded(.up)), le = Int(prep.loopEnd.rounded(.down))
                    let re = Int(a.loopEnd.rounded(.down)), hl = re - le
                    var parts: [(String, ArraySlice<Float>)] = [
                        ("steady", src.samples[src.steadyRange]),
                        ("raw_head", src.samples[ls..<(ls + hl)]), ("raw_tail", src.samples[le..<re]),
                        ("raw_middle", src.samples[(ls + hl)..<le]),
                        ("prep_head", prep.played[ls..<(ls + hl)]), ("prep_middle", prep.played[(ls + hl)..<le]),
                    ]
                    for j in 0..<3 {
                        let q0 = j * hl / 3, q1 = (j + 1) * hl / 3
                        parts.append(("raw_head_\(j)", src.samples[(ls + q0)..<(ls + q1)]))
                        parts.append(("raw_tail_\(j)", src.samples[(le + q0)..<(le + q1)]))
                        parts.append(("prep_head_\(j)", prep.played[(ls + q0)..<(ls + q1)]))
                    }
                    parts.append(("tile_prepared", tile(prep.played, loopEnd: prep.loopEnd)[...]))
                    parts.append(("tile_raw", tile(src.samples, loopEnd: a.loopEnd)[...]))
                    var d = "part,f,env_db,ltas_db\n"
                    for (pn, y) in parts {
                        let lt = PitchMetrics.ltas(y, sampleRate: sr)
                        let e = PitchMetrics.envelopeDB(ltas: lt, sampleRate: sr, f0max: 360)
                        for i in e.f.indices where e.f[i] >= 100 && e.f[i] <= 5200 {
                            d += "\(pn),\(e.f[i]),\(e.e[i]),\(10 * log10(lt.p[i]))\n"
                        }
                        row(vname, "part_" + pn, 0, lsd(y))
                    }
                    try d.write(to: out.appendingPathComponent("parts_\(letter)_\(vname)_\(Int(sr)).csv"), atomically: false, encoding: .utf8)
                }
                if env["TILEPROBE"] == "1" {
                    // Window-weighting probe: the prepared loop tiled from the loop start or from the gate's start, over
                    // fractional and whole numbers of effective loops.
                    let ll = prep.loopEnd - a.loopStart
                    func tileFrom(_ start: Double, loops: Double) -> ArraySlice<Float> {
                        let n = Int((loops * ll).rounded())
                        var y = [Float](repeating: 0, count: n)
                        for i in 0..<n {
                            var p = start + Double(i)
                            while p >= prep.loopEnd { p -= ll }
                            let k = Int(p), f = Float(p - Double(k))
                            y[i] = prep.played[k] * (1 - f) + prep.played[min(prep.played.count - 1, k + 1)] * f
                        }
                        return y[...]
                    }
                    let g0 = Double(a.onset) + 0.6 * sr
                    for (lab, st0) in [("loopStart", a.loopStart), ("gateStart", g0), ("loopMid", a.loopStart + 0.5 * ll)] {
                        for k in [1.0, 1.257, 2.0, 3.0, 6.0] {
                            row(vname, "tileprobe_\(lab)_x\(k)", 0, lsd(tileFrom(st0, loops: k)))
                        }
                    }
                }
                if vname == "prod" {
                    row("src", "slice_raw_loop", 0, lsd(src.samples[Int(a.loopStart.rounded(.up))..<Int(a.loopEnd.rounded(.down))]))
                    row("src", "tile_raw_loop@1", 0, lsd(tile(src.samples, loopEnd: a.loopEnd)[...]))
                    row("src", "slice_prepared_to_raw_loopEnd", 0,
                        lsd(prep.played[Int(a.loopStart.rounded(.up))..<Int(a.loopEnd.rounded(.down))]))
                    row("src", "eff_loop_seconds", 0, (prep.loopEnd - a.loopStart) / sr)
                    row("src", "raw_loop_seconds", 0, (a.loopEnd - a.loopStart) / sr)
                }
            }
            // Alternative references (ALTREF=1, evidence for a ruling; the gate itself is untouched): the envelope of
            // the prepared loop as it plays (rate-1 identity tile over two whole effective loops from the loop start).
            var prepRefEnv: [Double]? = nil
            var effLoop = 0.0
            if altRef && a.isVoiced {
                let prep = TDPSOLA2.prepared(src.samples, sampleRate: sr, analysis: a, kind: src.kind, tuning: tuning,
                                             outputGain: src.gain, seam: options.seamBlend)
                effLoop = prep.loopEnd - a.loopStart
                let n = Int((2 * effLoop).rounded())
                var y = [Float](repeating: 0, count: n)
                for i in 0..<n {
                    var p = a.loopStart + Double(i)
                    while p >= prep.loopEnd { p -= effLoop }
                    let k = Int(p), f = Float(p - Double(k))
                    y[i] = prep.played[k] * (1 - f) + prep.played[min(prep.played.count - 1, k + 1)] * f
                }
                prepRefEnv = PitchMetrics.envelopeDB(ltas: PitchMetrics.ltas(y[...], sampleRate: sr), sampleRate: sr, f0max: 360).e
            }
            // (b) renders: every held cell, every seed (unvoiced F: one seed, as the bench).
            let nSeeds = a.isVoiced && options.harmonicNoiseSwap ? seedCount : 1
            for scen in scenarios {
                guard case .heldPitch(let c, let r) = scen.family else { continue }
                for si in 0..<nSeeds {
                    let xor = PitchRunner.cellSeedXor(source: src.name, scenario: scen.name, seedIndex: si)
                    var o = options; o.noiseSeedXor = xor
                    let rnd: TDPSOLA2 = si == 0 && xor == 0 && vname == "prod" && env["OPTS"] == nil
                        ? LiveSonificationAudio.makeRenderer(src.sonification)
                        : TDPSOLA2(source: src.samples, sampleRate: sr, kind: src.kind,
                                   maxFramesPerRender: LiveSonificationKernel.chunkFrames, analysis: t0.coarseAnalysis,
                                   tuning: tuning, options: o, outputGain: src.gain,
                                   refined: (t0.analysis, t0.epochReport), firstMark: t0.attackFirstMark)
                    let x = BakeoffRunner.drive(rnd, sampleRate: sr, scenario: scen, ignoreRateAndPitch: false).samples
                    let from = PitchScenarios.heldRegion.from
                    let wd = a.isVoiced ? PitchScenarios.heldAnalysisDuration(rate: r, loopSeconds: src.loopSeconds)
                                        : PitchScenarios.heldRegion.to - from
                    let to = min(Double(x.count) / sr, from + wd)
                    let y = x[frame(from)..<frame(to)]
                    let v: Double
                    if a.isVoiced {
                        v = lsd(y)
                    } else {
                        let e = PitchMetrics.envelopeDB(y, sampleRate: sr)
                        v = PitchMetrics.envelopeCompare(f: e.f, source: ref.envelope.e, output: e.e, refine: false).lsd
                    }
                    let cell = String(format: "%+d@%@", Int(c), PitchScenarios.rateLabel(r))
                    row(vname, cell, si, v)
                    if let pe = prepRefEnv {
                        let e = PitchMetrics.envelopeDB(ltas: PitchMetrics.ltas(y, sampleRate: sr), sampleRate: sr, f0max: 360)
                        row(vname, cell + "|refPrep", si, PitchMetrics.envelopeCompare(f: e.f, source: pe, output: e.e, refine: false).lsd)
                        // The bench's own scenario and window built from the EFFECTIVE loop length (SEAM2 shortens the loop
                        // the bench's `loopSeconds` measures): whole effective loops, rendered long enough to hold them.
                        let effScen = try PitchScenarios.standard(letter: letter, sampleRate: sr, rates: [r],
                                                                  loopSeconds: effLoop / sr)
                            .first { $0.name == scen.name }!
                        let rndE = TDPSOLA2(source: src.samples, sampleRate: sr, kind: src.kind,
                                            maxFramesPerRender: LiveSonificationKernel.chunkFrames,
                                            analysis: t0.coarseAnalysis, tuning: tuning, options: o,
                                            outputGain: src.gain, refined: (t0.analysis, t0.epochReport),
                                            firstMark: t0.attackFirstMark)
                        let xe = BakeoffRunner.drive(rndE, sampleRate: sr, scenario: effScen, ignoreRateAndPitch: false).samples
                        let wde = PitchScenarios.heldAnalysisDuration(rate: r, loopSeconds: effLoop / sr)
                        precondition(from + wde <= Double(xe.count) / sr, "effWin window exceeds the render")
                        row(vname, cell + "|effWin", si, lsd(xe[frame(from)..<frame(from + wde)]))
                    }
                }
            }
            FileHandle.standardError.write("stages \(letter) \(vname) @\(Int(sr))\n".data(using: .utf8)!)
            try csv.write(to: out.appendingPathComponent("stages.csv"), atomically: false, encoding: .utf8)
        }
    }
}

/// ENVGAP-A option presets for the stages driver (harness only).
func envgapAOptions(_ name: String) -> TDPSOLA2Options {
    var o = TDPSOLA2Options.production
    EnvgapACandidates.apply(name, to: &o)
    return o
}
