// EnvDump.swift — ENVGAP diagnosis: per-band envelope comparison of a candidate's held render (and optionally a
// Praat render of the same source) against the source envelope, with the bench's own metric code.
import AVFAudio
import Foundation
@testable import PrimaeNative

@MainActor func envDump() throws {
    let env = ProcessInfo.processInfo.environment
    let sr = env["RATE"].flatMap(Double.init) ?? 48_000
    let letter = env["LETTERS"] ?? "I"
    let cents = Float(env["CENTS"] ?? "600")!
    let rate = Float(env["PRATE"] ?? "1")!
    let out = URL(fileURLWithPath: env["OUT"] ?? "envdump")
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let src = try BakeoffSources.pitchSources(letters: [letter], sampleRate: sr)[0]
    let ref = PitchSourceRef(src)
    // Source WAV for Praat (the exact samples the bench measures against).
    if env["WRITE_SRC"] == "1" {
        try BakeoffWAV.writeFloat(src.samples, sampleRate: sr, to: out.appendingPathComponent("\(letter)_src_\(Int(sr)).wav"))
        let st = src.steadyRange
        try "\(st.lowerBound) \(st.upperBound)\n".write(to: out.appendingPathComponent("\(letter)_steady_\(Int(sr)).txt"), atomically: false, encoding: .utf8)
    }
    let scenarios = try PitchScenarios.standard(letter: letter, sampleRate: sr, rates: [rate], loopSeconds: src.loopSeconds)
    let name = cents == 0 ? "pitch_0@\(PitchScenarios.rateLabel(rate))" : String(format: "pitch_%+d@%@", Int(cents), PitchScenarios.rateLabel(rate))
    guard let scen = scenarios.first(where: { $0.name == name }) else { fatalError("no scenario \(name)") }
    var rows = "who,f,env_db\n"
    var ltasRows = "who,f,ltas_db\n"
    do {
        let lt = PitchMetrics.ltas(ref.steady, sampleRate: sr)
        for i in lt.f.indices where lt.f[i] >= 100 && lt.f[i] <= 5000 { ltasRows += "source,\(lt.f[i]),\(10 * log10(max(lt.p[i], 1e-30)))\n" }
    }
    let f = ref.envelope.f
    for i in f.indices where f[i] >= 150 && f[i] <= 5000 { rows += "source,\(f[i]),\(ref.envelope.e[i])\n" }
    let pool = BakeoffCandidates.all + EnvgapCandidates.all
    let names = (env["CANDS"] ?? "r31").split(separator: ",").map(String.init)
    let frame: (Double) -> Int = { Int(($0 * sr).rounded()) }
    for cn in names {
        guard let cand = pool.first(where: { $0.name == cn }) else { continue }
        let render = BakeoffRunner.render(cand, source: src, scenario: scen, seedXor: 0, template: nil)
        let x = render.samples
        let winFrom = PitchScenarios.heldRegion.from
        let winDur = PitchScenarios.heldAnalysisDuration(rate: rate, loopSeconds: src.loopSeconds)
        let winTo = min(Double(x.count) / sr, winFrom + winDur)
        let y = x[frame(winFrom)..<frame(winTo)]
        let lt = PitchMetrics.ltas(y, sampleRate: sr)
        for i in lt.f.indices where lt.f[i] >= 100 && lt.f[i] <= 5000 { ltasRows += "\(cn),\(lt.f[i]),\(10 * log10(max(lt.p[i], 1e-30)))\n" }
        let e = PitchMetrics.envelopeDB(ltas: lt, sampleRate: sr, f0max: 360)
        let c = PitchMetrics.envelopeCompare(f: e.f, source: ref.envelope.e, output: e.e, refine: false)
        print("ENV \(cn) \(letter) \(name) @\(Int(sr)) lsd=\(String(format: "%.4f", c.lsd))")
        for i in e.f.indices where e.f[i] >= 150 && e.f[i] <= 5000 { rows += "\(cn),\(e.f[i]),\(e.e[i])\n" }
        if env["WRITE_RENDER"] == "1" {
            try BakeoffWAV.writeFloat(Array(y), sampleRate: sr, to: out.appendingPathComponent("\(cn)_\(letter)_\(name)_\(Int(sr)).wav"))
        }
    }
    if env["FLOOR"] == "1" {
        let r = LiveSonificationAudio.makeRenderer(src.sonification)
        let lo = Int(r.analysis.loopStart.rounded(.up)), hi = Int(r.analysis.loopEnd.rounded(.down))
        let e = PitchMetrics.envelopeDB(ltas: PitchMetrics.ltas(src.samples[lo..<hi], sampleRate: sr), sampleRate: sr, f0max: 360)
        let c = PitchMetrics.envelopeCompare(f: e.f, source: ref.envelope.e, output: e.e, refine: false)
        // The bench's own 0 c held render (seed 0) vs the raw loop range: what the renderer's loop playback adds.
        let sc0 = try PitchScenarios.standard(letter: letter, sampleRate: sr, rates: [1], loopSeconds: src.loopSeconds)
            .first { $0.name == "pitch_0@1" }!
        let cand = BakeoffCandidates.all.first { $0.name == "r31" }!
        let x0 = BakeoffRunner.render(cand, source: src, scenario: sc0, seedXor: 0, template: nil).samples
        let wd = PitchScenarios.heldAnalysisDuration(rate: 1, loopSeconds: src.loopSeconds)
        let y0 = x0[Int((0.6 * sr).rounded())..<Int(((0.6 + wd) * sr).rounded())]
        let e0 = PitchMetrics.envelopeDB(ltas: PitchMetrics.ltas(y0, sampleRate: sr), sampleRate: sr, f0max: 360)
        let c0 = PitchMetrics.envelopeCompare(f: e.f, source: e.e, output: e0.e, refine: false)
        let prep = TDPSOLA2.prepared(src.samples, sampleRate: sr, analysis: r.analysis, kind: .voicedPhoneme,
                                     tuning: .default, outputGain: src.gain).played
        let ep = PitchMetrics.envelopeDB(ltas: PitchMetrics.ltas(prep[lo..<hi], sampleRate: sr), sampleRate: sr, f0max: 360)
        let cp = PitchMetrics.envelopeCompare(f: e.f, source: e.e, output: ep.e, refine: false)
        let cps = PitchMetrics.envelopeCompare(f: e.f, source: ref.envelope.e, output: ep.e, refine: false)
        let c0p = PitchMetrics.envelopeCompare(f: e.f, source: ep.e, output: e0.e, refine: false)
        print("FLOOR \(letter) @\(Int(sr)): prepared (SEAM2 + TDQ declick) vs raw, loop range: lsd=\(String(format: "%.4f", cp.lsd)); prepared loop vs steady: \(String(format: "%.4f", cps.lsd)); 0 c render vs prepared loop: \(String(format: "%.4f", c0p.lsd))")
        // Sample-level identity check: best integer lag of the 0 c render against the prepared buffer, residual energy.
        do {
            let a0 = Int((0.6 * sr).rounded()), len = Int(0.2 * sr)
            var best = (lag: 0, err: Double.infinity)
            let onset = Double(r.analysis.onset)
            for lag in -400...400 {
                var e = 0.0, p = 0.0
                for i in 0..<len {
                    let si = Int(onset) + a0 + i + lag
                    guard si >= 0 && si < prep.count else { e = .infinity; break }
                    let d = Double(x0[a0 + i]) - Double(prep[si]); e += d * d; p += Double(prep[si]) * Double(prep[si])
                }
                if e / max(p, 1e-30) < best.err { best = (lag, e / max(p, 1e-30)) }
            }
            print("FLOOR \(letter): 0 c render vs prepared at onset+t+lag, best lag \(best.lag), residual \(String(format: "%.2f", 10 * log10(best.err))) dB")
            // residual over time (per 20 ms block) across the whole analysis window at that lag
            var line = ""
            var t = a0
            while t + Int(0.02 * sr) < a0 + Int(wd * sr) {
                var e = 0.0, p = 0.0
                for i in t..<(t + Int(0.02 * sr)) {
                    var si = Int(onset) + i + best.lag
                    while Double(si) >= r.analysis.loopEnd { si -= Int((r.analysis.loopEnd - r.analysis.loopStart).rounded()) }
                    let d = Double(x0[i]) - Double(prep[si]); e += d * d; p += Double(prep[si]) * Double(prep[si])
                }
                line += String(format: "%.0f ", 10 * log10(max(e, 1e-30) / max(p, 1e-30)))
                t += Int(0.1 * sr)
            }
            print("FLOOR \(letter): residual per 20 ms block every 100 ms: \(line)")
        }
        print("FLOOR \(letter) @\(Int(sr)): 0 c @1 render vs raw loop range: lsd=\(String(format: "%.4f", c0.lsd))")
        print("FLOOR \(letter) @\(Int(sr)): raw source over the loop range [\(lo), \(hi)) vs steady \(src.steadyRange): lsd=\(String(format: "%.4f", c.lsd))")
    }
    if env["WRITE_MARKS"] == "1" {
        let r = LiveSonificationAudio.makeRenderer(src.sonification)
        var t = "mark,period,attackIndex=\(r.analysis.attackIndex),loopStart=\(r.analysis.loopStart),loopEnd=\(r.analysis.loopEnd),applied=\(String(describing: r.epochReport))\n"
        for (m, p) in zip(r.analysis.marks, r.analysis.periods) { t += "\(m),\(p)\n" }
        try t.write(to: out.appendingPathComponent("marks_\(letter)_\(Int(sr)).csv"), atomically: false, encoding: .utf8)
    }
    if let praat = env["PRAAT_WAV"] {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: praat))
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buf)
        let p = Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
        let st = src.steadyRange
        let y = p[min(st.lowerBound, p.count - 1)..<min(st.upperBound, p.count)]
        let lt = PitchMetrics.ltas(y, sampleRate: sr)
        for i in lt.f.indices where lt.f[i] >= 100 && lt.f[i] <= 5000 { ltasRows += "praat,\(lt.f[i]),\(10 * log10(max(lt.p[i], 1e-30)))\n" }
        let e = PitchMetrics.envelopeDB(ltas: lt, sampleRate: sr, f0max: 360)
        let c = PitchMetrics.envelopeCompare(f: e.f, source: ref.envelope.e, output: e.e, refine: false)
        print("ENV praat \(letter) \(name) @\(Int(sr)) lsd=\(String(format: "%.4f", c.lsd)) (steady \(st))")
        for i in e.f.indices where e.f[i] >= 150 && e.f[i] <= 5000 { rows += "praat,\(e.f[i]),\(e.e[i])\n" }
    }
    try ltasRows.write(to: out.appendingPathComponent("ltas_\(letter)_\(name)_\(Int(sr)).csv"), atomically: false, encoding: .utf8)
    try rows.write(to: out.appendingPathComponent("env_\(letter)_\(name)_\(Int(sr)).csv"), atomically: false, encoding: .utf8)
}
