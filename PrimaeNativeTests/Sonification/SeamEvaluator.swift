// SeamEvaluator.swift
// PrimaeNativeTests — lane SEAM2 (2026-11-04): step across a wrap vs the steps
// inside the loop, per feature (see SeamMeter.swift).
//
// step(t) = mean of the feature over [t, t+W) minus its mean over [t-W, t).
// A wrap is flagged when its |step| exceeds the 95th percentile of |step| at
// every position at least W away from any wrap (and from the loop entry), and
// a per-feature floor (below which a step is inaudible by construction).
// Timbre is the band-profile step with the level removed (per-band dB minus
// the frame's mean band dB), reported as the RMS over bands.

import Foundation

nonisolated struct SeamFeatureResult {
    var name: String
    var atWraps: [Double]       // step at each wrap (signed; timbre/flux are >= 0)
    var inside: [Double]        // |step| at all inside positions, sorted
    var floor: Double
    var p50: Double { inside.isEmpty ? 0 : inside[inside.count / 2] }
    var p95: Double { inside.isEmpty ? 0 : inside[min(inside.count - 1, Int(Double(inside.count) * 0.95))] }
    var wrapMean: Double { atWraps.isEmpty ? 0 : atWraps.map { abs($0) }.reduce(0, +) / Double(atWraps.count) }
    var threshold: Double { max(p95, floor) }
    var flagged: Bool { wrapMean > threshold }
    /// Seam score: the wrap step over the larger of the inside p95 and the floor (<= 1 means within the loop's own steps).
    var score: Double { wrapMean / threshold }
}

nonisolated struct SeamDrift {
    var resetDB: [Double]       // level step across each wrap (W = 400 ms), signed
    var slopeDBPerSecond: [Double]   // least-squares level slope inside each full cycle
    var peakToPeakDB: [Double]  // range of the 200 ms smoothed level inside each full cycle
    var meanReset: Double { resetDB.isEmpty ? 0 : resetDB.reduce(0, +) / Double(resetDB.count) }
}

nonisolated enum SeamEvaluator {
    static let floors: [String: Double] = ["level dB": 0.1, "timbre dB": 0.3, "centroid st": 0.25,
                                           "f0 cents": 5, "periodicity": 0.03, "flux": 1.0]

    static func mean(_ v: [Double], _ lo: Int, _ hi: Int) -> Double {
        var s = 0.0, c = 0
        for i in max(0, lo)..<min(v.count, max(hi, 0)) where v[i].isFinite { s += v[i]; c += 1 }
        return c > 0 ? s / Double(c) : .nan
    }

    /// First frame index with centre time >= `time`.
    static func index(_ tr: SeamTrack, _ time: Double) -> Int {
        max(0, Int((time * tr.sr - Double(SeamTrack.frame / 2)) / Double(SeamTrack.hop)))
    }

    /// Step of every feature at frame index `k`, window `w` frames.
    /// Frames whose 46 ms window straddles the wrap are skipped on both sides (`gap`), so a step is measured
    /// between clean material and a hard step reads at its true size.
    static let gap = 3

    static func steps(_ tr: SeamTrack, at k: Int, w: Int) -> [String: Double] {
        var out: [String: Double] = [:]
        let g = gap
        out["level dB"] = mean(tr.level, k + g, k + g + w) - mean(tr.level, k - g - w, k - g)
        out["centroid st"] = mean(tr.centroid, k + g, k + g + w) - mean(tr.centroid, k - g - w, k - g)
        out["f0 cents"] = mean(tr.f0, k + g, k + g + w) - mean(tr.f0, k - g - w, k - g)
        out["periodicity"] = mean(tr.periodicity, k + g, k + g + w) - mean(tr.periodicity, k - g - w, k - g)
        var sq = 0.0
        // Band profile means, level removed.
        let nb = tr.bands[0].count
        var after = [Double](repeating: 0, count: nb), before = after
        var ca = 0, cb = 0
        for i in max(0, k - g - w)..<min(tr.bands.count, k + g + w) where i < k - g || i >= k + g {
            let m = tr.bands[i].reduce(0, +) / Double(nb)
            for b in 0..<nb {
                if i >= k + g { after[b] += tr.bands[i][b] - m } else { before[b] += tr.bands[i][b] - m }
            }
            if i >= k + g { ca += 1 } else { cb += 1 }
        }
        if ca > 0 && cb > 0 {
            for b in 0..<nb { let d = after[b] / Double(ca) - before[b] / Double(cb); sq += d * d }
            out["timbre dB"] = (sq / Double(nb)).squareRoot()
        } else { out["timbre dB"] = .nan }
        // Flux: the largest frame-to-frame change within +-40 ms.
        var fmax = 0.0
        for i in max(0, k - 4)..<min(tr.flux.count, k + 5) { fmax = max(fmax, tr.flux[i]) }
        out["flux"] = fmax
        return out
    }

    /// `wraps`: wrap times in seconds; `start`: loop entry time (steps before start + W are not "inside").
    static func evaluate(_ tr: SeamTrack, wraps: [Double], start: Double, window: Double = 0.1) -> [SeamFeatureResult] {
        guard tr.t.count > 8 else { return [] }
        let w = max(2, Int((window / tr.hopSeconds).rounded()))
        let wrapIdx = wraps.map { index(tr, $0) }.filter { $0 - gap - w >= 0 && $0 + gap + w <= tr.t.count }
        let lo = index(tr, start) + w + gap
        let names = ["level dB", "timbre dB", "centroid st", "f0 cents", "periodicity", "flux"]
        var atWraps: [String: [Double]] = [:], inside: [String: [Double]] = [:]
        for k in wrapIdx { for (n, v) in steps(tr, at: k, w: w) where v.isFinite { atWraps[n, default: []].append(v) } }
        var k = lo
        while k + w + gap <= tr.t.count {
            if !wrapIdx.contains(where: { abs($0 - k) < w + gap + 4 }) {
                for (n, v) in steps(tr, at: k, w: w) where v.isFinite { inside[n, default: []].append(abs(v)) }
            }
            k += 1
        }
        return names.map {
            SeamFeatureResult(name: $0, atWraps: atWraps[$0] ?? [], inside: (inside[$0] ?? []).sorted(), floor: floors[$0] ?? 0)
        }
    }

    /// The slow trajectory: level step across each wrap (400 ms) and the slope / range inside each full cycle.
    static func drift(_ tr: SeamTrack, wraps: [Double], start: Double) -> SeamDrift {
        var d = SeamDrift(resetDB: [], slopeDBPerSecond: [], peakToPeakDB: [])
        let w = max(2, Int((0.4 / tr.hopSeconds).rounded()))
        for t in wraps {
            let k = index(tr, t)
            let g = gap
            if k - w - g >= 0 && k + w + g <= tr.t.count { d.resetDB.append(mean(tr.level, k + g, k + g + w) - mean(tr.level, k - g - w, k - g)) }
        }
        let edges = [start] + wraps
        for c in 0..<(edges.count - 1) {
            let a = index(tr, edges[c]) + 2, b = index(tr, edges[c + 1]) - 2
            guard b - a > 3 * w else { continue }
            var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0, n = 0.0
            for i in a..<b { let x = tr.t[i], y = tr.level[i]; sx += x; sy += y; sxx += x * x; sxy += x * y; n += 1 }
            let den = n * sxx - sx * sx
            d.slopeDBPerSecond.append(den > 0 ? (n * sxy - sx * sy) / den : 0)
            var mn = Double.infinity, mx = -Double.infinity
            for i in a..<(b - w) { let m = mean(tr.level, i, i + w); mn = min(mn, m); mx = max(mx, m) }
            d.peakToPeakDB.append(mx - mn)
        }
        return d
    }
}
