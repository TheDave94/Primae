// SeamCheck.swift — lane ENVGAP-A: SEAM2's own loop-seam gates (LoopSeamRegressionTests: level step <= 0.3 dB,
// drift-reset <= 0.3 dB, in-cycle drift <= 0.8 dB, five rates; wrap pulse <= 1.8x for A and M at 0.5/1/2) plus the
// meter's timbre/centroid wrap readings, for production and for an ENVGAP-A option preset. MODE=seam, OPTS=<preset>.
// Built exactly as the tests build it (StudySource: kernel reference rate, gain 1, recorded onset, tuning .default),
// with the preset's options in place of production's. Uses the repo's SeamMeter/SeamEvaluator/SeamRender sources.
import Foundation
@testable import PrimaeNative

@MainActor func seamCheck() throws {
    let env = ProcessInfo.processInfo.environment
    let preset = env["OPTS"] ?? "production"
    let opts = envgapAOptions(preset)
    let sr = LiveSonificationKernel.referenceSampleRate
    let names = (env["LETTERS"] ?? "A,F,I,L,M").split(separator: ",").map { "\($0)_phoneme1" }
    print("SEAM preset=\(preset) sr=\(Int(sr))")
    for name in names {
        let letter = String(name.prefix(1))
        let url = PrimaeBundle.resourceURL(firstOf: PrimaeBundle.layouts(dir: "Letters/\(letter)", name: name, ext: "wav"))!
        let samples = try SonificationSource.decodeMono(url: url, sampleRate: sr)
        let kind = SonificationSource.kind(forFileAt: url)
        let onset = PhonemeOnsets.onset(forFileNamed: "\(name).wav")
        func make() -> TDPSOLA2 {
            TDPSOLA2(source: samples, sampleRate: sr, kind: kind, maxFramesPerRender: LiveSonificationKernel.chunkFrames,
                     tuning: .default, options: opts, onset: onset, outputGain: 1)
        }
        for rate: Float in [0.5, 0.7, 1.0, 1.4, 2.0] {
            let r = make()
            let out = SeamRender.steady(r, rate: rate)
            let tr = SeamMeter.analyse(out.samples, sr: sr)
            let slow = SeamEvaluator.evaluate(tr, wraps: out.wraps, start: out.entry, window: 0.3)
            let level = slow.first { $0.name == "level dB" }!
            let d = SeamEvaluator.drift(tr, wraps: out.wraps, start: out.entry)
            let p2p = d.peakToPeakDB.max() ?? 0
            let ok = out.wraps.count >= 3 && level.wrapMean <= 0.3 && abs(d.meanReset) <= 0.3 && p2p <= 0.8
            let extra = slow.filter { $0.name != "level dB" }
                .map { "\($0.name)=\(String(format: "%.3f", $0.wrapMean))/\(String(format: "%.3f", $0.threshold))\($0.flagged ? "!" : "")" }
                .joined(separator: " ")
            print(String(format: "SEAMWRAP %@ %@ r%.1f wraps=%d level=%.3f reset=%.3f p2p=%.3f %@ | %@", preset, letter, rate,
                         out.wraps.count, level.wrapMean, d.meanReset, p2p, ok ? "PASS" : "FAIL", extra))
        }
        guard letter == "A" || letter == "M" else { continue }
        for rate: Float in [0.5, 1.0, 2.0] {
            let r = make()
            let out = SeamRender.steady(r, rate: rate, seconds: 9)
            let y = out.samples
            let per = max(40, Int(r.analysis.medianPeriod.rounded()))
            func pk(_ c: Int, _ h: Int) -> Double {
                var m: Float = 0
                for j in max(1, c - h)..<min(y.count, c + h) { m = max(m, abs(y[j] - y[j - 1])) }
                return Double(m)
            }
            var ratios: [Double] = []
            for w in out.wraps where w > 1.5 && w < Double(y.count) / sr - 0.2 {
                let c = Int(w * sr)
                var ctx: [Double] = []
                for k in 2...8 { ctx.append(pk(c + k * per, per / 2)); ctx.append(pk(c - k * per, per / 2)) }
                ctx.sort()
                ratios.append(pk(c, per) / max(1e-9, ctx[ctx.count / 2]))
            }
            let mean = ratios.isEmpty ? .infinity : ratios.reduce(0, +) / Double(ratios.count)
            print(String(format: "SEAMPULSE %@ %@ r%.1f n=%d pulse=%.3f %@", preset, letter, rate, ratios.count, mean,
                         ratios.count >= 2 && mean <= 1.8 ? "PASS" : "FAIL"))
        }
    }
}
