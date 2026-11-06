// equalise_phoneme_periods.swift: offline, one-time processing of a voiced phoneme recording (lane POP2, 2026-11-04).
//
// Equalises the per-pitch-period energy of the recording toward a slowly varying envelope, so the sustained sound does
// not carry period-to-period loudness shimmer that the time-stretch turns into audible flutter (David: "I can even hear
// loudness fluctuations ... for A specifically"). Build and run with scripts/equalise_phoneme_periods.sh.
//
// usage: equalise_phoneme_periods <in.wav> <out.wav> [--smooth seconds=0.12] [--protect seconds=0.15] [--max-db 3]
//
// What it does, in order:
//   1. pitch marks and periods from the engine's own analysis (`TDPSOLAAnalysis`), so the marks are the renderer's;
//   2. the level (dB) of each period from the loop's first mark on; the target is the mean of the periods within
//      +/- smooth/2 seconds; the correction is target - level, clamped to +/- max-db, interpolated linearly in dB
//      between mark centres (structure slower than ~smooth is left as recorded);
//   3. nothing changes before `protect` (the attack); the correction rises from 0 over the next 50 ms (smoothstep);
//   4. one overall gain on the corrected region (through the same fade) brings the file RMS back to the original's;
//   5. the output keeps the input's header bytes and length (mono, 44.1 kHz, Int16); it refuses to write a clipped file.
import Foundation

func fail(_ s: String) -> Never { FileHandle.standardError.write((s + "\n").data(using: .utf8)!); exit(1) }
let args = CommandLine.arguments
guard args.count >= 3 else { fail("usage: equalise_phoneme_periods <in.wav> <out.wav> [--smooth s] [--protect s] [--max-db d]") }
func opt(_ k: String, _ d: Double) -> Double { if let i = args.firstIndex(of: k), i + 1 < args.count, let v = Double(args[i + 1]) { return v }; return d }
let smooth = opt("--smooth", 0.12), protect = opt("--protect", 0.15), maxDB = opt("--max-db", 3)
let fadeSeconds = 0.05
guard let data = FileManager.default.contents(atPath: args[1]) else { fail("cannot read \(args[1])") }
let bytes = [UInt8](data)
// locate the data chunk
var pos = 12, dataAt = -1, dataLen = 0
while pos + 8 <= bytes.count {
    let id = String(bytes: bytes[pos..<(pos + 4)], encoding: .ascii) ?? ""
    let len = Int(bytes[pos + 4]) | Int(bytes[pos + 5]) << 8 | Int(bytes[pos + 6]) << 16 | Int(bytes[pos + 7]) << 24
    if id == "data" { dataAt = pos + 8; dataLen = len; break }
    pos += 8 + len + (len & 1)
}
guard dataAt > 0 else { fail("no data chunk") }
let fmtChannels = Int(bytes[22]) | Int(bytes[23]) << 8, rate = Int(bytes[24]) | Int(bytes[25]) << 8 | Int(bytes[26]) << 16
let bits = Int(bytes[34]) | Int(bytes[35]) << 8
guard fmtChannels == 1, rate == 44100, bits == 16 else { fail("expected mono 44.1 kHz Int16, got \(fmtChannels) ch \(rate) Hz \(bits) bit") }
let n = dataLen / 2
let sr = 44100.0
var x = [Float](repeating: 0, count: n)
for i in 0..<n { x[i] = Float(Int16(bitPattern: UInt16(bytes[dataAt + 2 * i]) | UInt16(bytes[dataAt + 2 * i + 1]) << 8)) / 32768 }
let a = TDPSOLAAnalysis.analyse(x, sampleRate: sr, kind: .voicedPhoneme)
guard a.isVoiced, a.loopEndIndex > a.attackIndex + 4 else { fail("not a voiced recording (analysis found no loop of pitch periods)") }

func levels(_ from: Int, _ to: Int) -> [Double] {
    (from...to).map { i in
        let m = a.marks[i], p = max(8, a.periods[i])
        let lo = max(0, Int((m - p / 2).rounded())), hi = min(n, Int((m + p / 2).rounded()))
        guard hi > lo else { return -120 }
        var e = 0.0; for j in lo..<hi { e += Double(x[j]) * Double(x[j]) }
        return 10 * log10(e / Double(hi - lo) + 1e-12)
    }
}
let from = a.attackIndex, to = a.loopEndIndex
// correction starts at the first mark at or after the protected attack
var first = from; while first < to && a.marks[first] < protect * sr { first += 1 }
let lv = levels(first, to)
let half = smooth * sr / 2
var sm = [Double](repeating: 0, count: lv.count)
do {
    var lo = 0, hi = 0, sum = 0.0
    for i in 0..<lv.count {
        while hi < lv.count && a.marks[first + hi] - a.marks[first + i] <= half { sum += lv[hi]; hi += 1 }
        while a.marks[first + i] - a.marks[first + lo] > half { sum -= lv[lo]; lo += 1 }
        sm[i] = sum / Double(hi - lo)
    }
}
let corr = zip(lv, sm).map { max(-maxDB, min(maxDB, $1 - $0)) }
func render(extraDB: Double) -> [Float] {
    var y = x
    var k = 0
    let startS = Int(a.marks[first].rounded())
    for j in startS..<n {
        while k + 1 < corr.count && Double(j) >= a.marks[first + k + 1] { k += 1 }
        let c0 = corr[k], c1 = k + 1 < corr.count ? corr[k + 1] : corr[k]
        let u = k + 1 < corr.count ? (Double(j) - a.marks[first + k]) / max(1, a.marks[first + k + 1] - a.marks[first + k]) : 0
        let f = max(0, min(1, (Double(j) - protect * sr) / (fadeSeconds * sr)))
        let dB = (c0 + (c1 - c0) * max(0, min(1, u)) + extraDB) * f * f * (3 - 2 * f)
        y[j] = Float(Double(x[j]) * pow(10, dB / 20))
    }
    return y
}
func rmsDB(_ v: [Float]) -> Double { 10 * log10(v.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(v.count) + 1e-12) }
var y = render(extraDB: 0)
var extra = 0.0
for _ in 0..<4 { let d = rmsDB(x) - rmsDB(y); if abs(d) < 0.005 { break }; extra += d; y = render(extraDB: extra) }
let q = y.map { Int16(max(-32768, min(32767, ($0 * 32768).rounded()))) }
if y.contains(where: { abs($0) * 32768 > 32767 }) { fail("clipping: peak \(y.map { abs($0) }.max()! * 32768) > 32767") }
var out = Array(bytes[0..<dataAt])
for v in q { let u = UInt16(bitPattern: v); out.append(UInt8(u & 255)); out.append(UInt8(u >> 8)) }
out.append(contentsOf: bytes[(dataAt + dataLen)...])
guard out.count == bytes.count else { fail("length changed") }
do { try Data(out).write(to: URL(fileURLWithPath: args[2])) } catch { fail("cannot write \(args[2]): \(error)") }
let peakIn = x.map { abs($0) }.max()! * 32768, peakOut = y.map { abs($0) }.max()! * 32768
print(String(format: "smooth %.0f ms protect %.2f s: periods %d, correction rms %.2f dB max %.2f dB | RMS %.3f dB -> %.3f dB (diff %+.3f) | peak %.0f -> %.0f | %d samples, header and length unchanged",
             smooth * 1000, protect, corr.count, (corr.map { $0 * $0 }.reduce(0, +) / Double(corr.count)).squareRoot(), corr.map { abs($0) }.max() ?? 0,
             rmsDB(x), rmsDB(y), rmsDB(y) - rmsDB(x), peakIn, peakOut, n))
