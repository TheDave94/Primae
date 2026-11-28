// RenderDump.swift — opt-in render dump for the offline pitch bench (lane BENCHWIN2).
// Off unless DUMP_DIR is set. DUMP (comma list of "<source>/<scenario>", e.g. "A_phoneme1/pitch_-600@2") selects the
// cells; DUMP_CANDS (comma list) narrows the candidates (default: all). For each selected cell and seed it writes the
// exact held analysis window the gates measure (`PitchRunner.heldWindow`) as 32-bit float mono WAV:
//   <DUMP_DIR>/<candidate>__<source>__<scenario>__s<seed>.wav
// and once per source the steady slice the jitter/shimmer reference is read from:
//   <DUMP_DIR>/SOURCE__<source>.wav
import Foundation
@testable import PrimaeNative

enum RenderDump {
    static let env = ProcessInfo.processInfo.environment
    static let dir: URL? = env["DUMP_DIR"].map { URL(fileURLWithPath: $0) }
    static let cells: Set<String> = Set((env["DUMP"] ?? "").split(separator: ",").map(String.init))
    static let cands: Set<String>? = env["DUMP_CANDS"].map { Set($0.split(separator: ",").map(String.init)) }

    static func wants(candidate: String, source: String, scenario: String) -> Bool {
        guard dir != nil, cells.contains("\(source)/\(scenario)") else { return false }
        return cands?.contains(candidate) ?? true
    }

    static func writeSource(_ ref: PitchSourceRef) throws {
        guard let dir, cells.contains(where: { $0.hasPrefix(ref.source.name + "/") }) else { return }
        try write(Array(ref.steady), sampleRate: ref.source.sampleRate,
                  to: dir.appendingPathComponent("SOURCE__\(ref.source.name).wav"))
    }

    static func writeRender(_ samples: ArraySlice<Float>, sampleRate: Double, candidate: String, source: String,
                            scenario: String, seed: Int) throws {
        guard let dir else { return }
        let name = "\(candidate)__\(source)__\(scenario)__s\(seed).wav"
        try write(Array(samples), sampleRate: sampleRate, to: dir.appendingPathComponent(name))
    }

    /// RIFF/WAVE, format 3 (IEEE float), mono, 32-bit.
    static func write(_ x: [Float], sampleRate: Double, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let sr = UInt32(sampleRate.rounded())
        let bytes = UInt32(x.count * 4)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(3); u16(1); u32(sr); u32(sr * 4); u16(4); u16(32)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        x.withUnsafeBufferPointer { d.append(UnsafeBufferPointer(start: UnsafeRawPointer($0.baseAddress!)
            .assumingMemoryBound(to: UInt8.self), count: x.count * 4)) }
        try d.write(to: url)
    }
}

/// MODE=perturb: reads every WAV named on stdin (one path per line; as written by `RenderDump.write`) and prints
/// `path,jitter_pct,shimmer_pct,jitter_unanchored_pct,shimmer_unanchored_pct` with the gate's estimator
/// (`PitchMetrics.perturbation`) and the one it replaced, for the Praat cross-check (scripts/envgap_harness/praat_jitter.praat).
@MainActor func perturbDump() throws {
    print("path,jitter_pct,shimmer_pct,jitter_unanchored_pct,shimmer_unanchored_pct")
    while let line = readLine() {
        let url = URL(fileURLWithPath: line.trimmingCharacters(in: .whitespaces))
        let d = try Data(contentsOf: url)
        // Our own float WAVs: 44-byte header, rate at byte 24.
        let sr = Double(d.subdata(in: 24..<28).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
        let n = (d.count - 44) / 4
        let x: [Float] = d.subdata(in: 44..<(44 + 4 * n)).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        let p = PitchMetrics.perturbation(x[...], sampleRate: sr)
        let u = PitchMetrics.perturbationUnanchored(x[...], sampleRate: sr)
        func f(_ v: Double?) -> String { v.map { String(format: "%.5f", $0) } ?? "nan" }
        print("\(line),\(f(p?.jitterPct)),\(f(p?.shimmerPct)),\(f(u?.jitterPct)),\(f(u?.shimmerPct))")
    }
}
