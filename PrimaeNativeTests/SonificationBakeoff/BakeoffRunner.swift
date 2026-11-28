// BakeoffRunner.swift
// PrimaeNativeTests — sonification bake-off harness (BENCH lane, 2026-11-02)
//
// Drives one candidate through one scenario (256-frame buffers, parameter
// writes between buffers, CPU time per buffer) and turns the render into
// CSV rows: one row per candidate x source x scenario x metric.

import Foundation
@testable import PrimaeNative

struct BakeoffRender {
    let samples: [Float]
    /// Wall time of each 256-frame `render` call, nanoseconds.
    let cpuNanos: [UInt64]
    let claimedLatencyFrames: Int
    /// Renderer construction (init-time analysis), nanoseconds.
    var initNanos: UInt64 = 0
    /// Process physical footprint after minus before the renderer was built, bytes (C3 banks; noisy for small sizes).
    var initFootprintDelta: Int64 = 0
}

enum BakeoffMemory {
    /// task_vm_info.phys_footprint, bytes (0 when unavailable).
    static func footprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }
}

struct BakeoffRow {
    let candidate: String
    let source: String
    let kind: String
    let sampleRate: Int
    let scenario: String
    let metric: String
    let value: Double
    let unit: String

    static let header = "candidate,source,kind,sample_rate,scenario,metric,value,unit"
    var csv: String {
        let v = value.isFinite ? String(format: "%.6g", value) : "nan"
        return "\(candidate),\(source),\(kind),\(sampleRate),\(scenario),\(metric),\(v),\(unit)"
    }
}

enum BakeoffRunner {
    static let bufferFrames = 256
    static let maxFramesPerRender = 512

    /// The frame at which an event written at `time` takes effect: the start
    /// of the first buffer at or after it.
    static func appliedFrame(_ time: Double, sampleRate: Double) -> Int {
        let f = Int((time * sampleRate).rounded(.up))
        return ((f + bufferFrames - 1) / bufferFrames) * bufferFrames
    }

    static func render(_ type: any SonificationRenderer.Type, source: BakeoffSource,
                       scenario: BakeoffScenario, ignoreRateAndPitch: Bool = false) -> BakeoffRender {
        let before = BakeoffMemory.footprint()
        let t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let renderer = type.init(source: source.samples, sampleRate: source.sampleRate, kind: source.kind,
                                 maxFramesPerRender: maxFramesPerRender)
        let initNanos = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0
        return drive(renderer, sampleRate: source.sampleRate, scenario: scenario, ignoreRateAndPitch: ignoreRateAndPitch,
                     initNanos: initNanos, initFootprintDelta: BakeoffMemory.footprint() - before)
    }

    /// Pitch bench: a registered candidate, built by its factory from the production source, with optional xor seed
    /// and pre-computed TDPSOLA2 template (reusing invariant analysis/GCIs for seeds > 0).
    static func render(_ candidate: BakeoffCandidate, source: BakeoffSource, scenario: BakeoffScenario,
                       seedXor: UInt64 = 0, template: TDPSOLA2? = nil) -> BakeoffRender {
        let before = BakeoffMemory.footprint()
        let t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let renderer = candidate.makeSeeded(source.sonification, maxFramesPerRender, seedXor, template)
        let initNanos = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0
        return drive(renderer, sampleRate: source.sampleRate, scenario: scenario, ignoreRateAndPitch: false,
                     initNanos: initNanos, initFootprintDelta: BakeoffMemory.footprint() - before)
    }

    /// Builds a template `TDPSOLA2` once per (candidate, source) so seed-spread runs reuse invariant analysis/GCIs.
    static func template(_ candidate: BakeoffCandidate, source: BakeoffSource) -> TDPSOLA2? {
        candidate.makeSeeded(source.sonification, maxFramesPerRender, 0, nil) as? TDPSOLA2
    }

    static func drive(_ renderer: any SonificationRenderer, sampleRate sr: Double, scenario: BakeoffScenario,
                      ignoreRateAndPitch: Bool, initNanos: UInt64 = 0, initFootprintDelta: Int64 = 0) -> BakeoffRender {
        renderer.reset()
        let total = Int(scenario.duration * sr)
        var out = [Float](repeating: 0, count: total)
        var cpu: [UInt64] = []
        cpu.reserveCapacity(total / bufferFrames + 1)
        var ev = 0
        var frame = 0
        let events = scenario.events
        while frame < total {
            while ev < events.count && appliedFrame(events[ev].time, sampleRate: sr) <= frame {
                switch events[ev].kind {
                case .rate(let r): if !ignoreRateAndPitch { renderer.setRate(r) }
                case .cents(let c): if !ignoreRateAndPitch { renderer.setPitchCents(c) }
                case .gate(let g): renderer.setGate(g)
                }
                ev += 1
            }
            let n = min(bufferFrames, total - frame)
            let start = frame
            let t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            out.withUnsafeMutableBufferPointer { renderer.render(into: $0.baseAddress! + start, frames: n) }
            let t1 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            if n == bufferFrames { cpu.append(t1 - t0) }
            frame += n
        }
        return BakeoffRender(samples: out, cpuNanos: cpu, claimedLatencyFrames: renderer.claimedLatencyFrames,
                             initNanos: initNanos, initFootprintDelta: initFootprintDelta)
    }

    /// The hidden reference of the listening test: the unprocessed source
    /// at rate 1, pitch 0, gated like the scenario (2 ms ramps).
    static func sourceReference(source: BakeoffSource, scenario: BakeoffScenario) -> BakeoffRender {
        render(NaiveResampleRenderer.self, source: source, scenario: scenario, ignoreRateAndPitch: true)
    }

    // MARK: - Metrics

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    static func metrics(candidate: String, render: BakeoffRender, source: BakeoffSource,
                        scenario: BakeoffScenario, sourceRef: BakeoffRender,
                        reference: BakeoffRender?) -> [BakeoffRow] {
        typealias M = BakeoffMetrics
        let sr = source.sampleRate
        let x = render.samples
        var rows: [BakeoffRow] = []
        func add(_ metric: String, _ value: Double?, _ unit: String) {
            guard let value else { return }
            rows.append(BakeoffRow(candidate: candidate, source: source.name, kind: source.kindLabel,
                                   sampleRate: Int(sr), scenario: scenario.name, metric: metric,
                                   value: value, unit: unit))
        }
        func ms(_ frames: Int?) -> Double? { frames.map { Double($0) / sr * 1000 } }

        // CPU per 256-frame buffer.
        let cpu = render.cpuNanos.map { Double($0) / 1000 }
        add("cpu_median_us", M.median(cpu), "us")
        add("cpu_p99_us", M.percentile(cpu, 99), "us")
        add("cpu_max_us", cpu.max(), "us")
        add("init_ms", Double(render.initNanos) / 1e6, "ms")
        add("init_footprint_kb", Double(render.initFootprintDelta) / 1024, "kB")
        if let med = M.median(cpu) { add("cpu_realtime_pct", med / (Double(bufferFrames) / sr * 1e6) * 100, "%") }
        add("claimed_latency_frames", Double(render.claimedLatencyFrames), "frames")

        let intervals = scenario.openIntervals.map {
            (open: appliedFrame($0.open, sampleRate: sr), close: min(x.count, appliedFrame($0.close, sampleRate: sr)))
        }
        guard let first = intervals.first else { return rows }

        // Onset of the first gate-open.
        let on = M.onset(x, gateFrame: first.open, openEnd: first.close, sampleRate: sr)
        let refOn = M.onset(sourceRef.samples, gateFrame: first.open, openEnd: first.close, sampleRate: sr)
        add("onset_m20_frames", on.toMinus20dB.map(Double.init) ?? .nan, "frames")
        add("onset_m20_ms", ms(on.toMinus20dB) ?? .nan, "ms")
        add("onset_nonzero_ms", ms(on.toNonZero) ?? .nan, "ms")
        if let a = on.toMinus20dB, let b = refOn.toMinus20dB { add("onset_m20_excess_ms", Double(a - b) / sr * 1000, "ms") }
        add("onset_rise_10_90_ms", M.riseTime10to90(x, gateFrame: first.open, openEnd: first.close, sampleRate: sr).map { $0 * 1000 }, "ms")
        add("level_db", Double(M.dB(on.steadyRMS)), "dBFS")
        add("level_re_source_db", Double(M.dB(on.steadyRMS) - M.dB(refOn.steadyRMS)), "dB")

        // Discontinuities at gate events, relative to the output's own steady motion.
        let steadyFrom = first.open + Int(0.2 * sr)
        let typical = M.typicalDelta(x, steadyFrom, max(steadyFrom + 1, first.close))
        if typical > 0 {
            var openClick: Float = 0, closeClick: Float = 0
            for iv in intervals {
                // From the gate to 20 ms past the -20 dB onset (or the first
                // non-zero sample if later), so a late-sounding candidate's real
                // onset is inside the window: a vocoder's sub-audible pre-ring
                // makes "first non-zero" far earlier than its audible start.
                let on = M.onset(x, gateFrame: iv.open, openEnd: iv.close, sampleRate: sr)
                let sounding = max(on.toMinus20dB ?? 0, on.toNonZero ?? 0)
                openClick = max(openClick, M.maxAbsDelta(x, iv.open - Int(0.001 * sr),
                                                         iv.open + sounding + Int(0.02 * sr)))
                if iv.close < x.count {
                    closeClick = max(closeClick, M.maxAbsDelta(x, iv.close, iv.close + Int(0.03 * sr)))
                }
            }
            add("gate_open_click_ratio", Double(openClick / typical), "x")
            if intervals.contains(where: { $0.close < x.count }) { add("gate_close_click_ratio", Double(closeClick / typical), "x") }
        }
        // Leak while closed (>= 100 ms after a close, until the next open).
        var leak: [Float] = []
        for (i, iv) in intervals.enumerated() where iv.close < x.count {
            let from = iv.close + Int(0.1 * sr)
            let to = i + 1 < intervals.count ? intervals[i + 1].open : x.count
            if to - from > Int(0.05 * sr) { leak.append(M.rms(x, from, to - from)) }
        }
        if let worst = leak.max(), on.steadyRMS > 0 { add("gate_leak_db", Double(M.dB(worst) - M.dB(on.steadyRMS)), "dB") }

        // Spectral flux spikes over the first open span.
        let specFrom = first.open + Int(0.05 * sr)
        let spec = M.spectrogram(x, from: specFrom, to: first.close)
        if let f = M.fluxSpikes(spec) {
            add("flux_spike_ratio", f.ratio, "x")
            add("flux_spike_count", Double(f.count), "frames")
        }
        // Quality vs the offline reference (AppleTimePitch-o32), latency-compensated
        // by aligning the -20 dB onsets.
        if let reference {
            let refOnset = M.onset(reference.samples, gateFrame: first.open, openEnd: first.close, sampleRate: sr)
            if let a = on.toMinus20dB, let b = refOnset.toMinus20dB {
                let shift = b - a   // reference lags the candidate by `shift`
                let candFrom = specFrom, candTo = first.close
                let refSpec = M.spectrogram(reference.samples, from: candFrom + shift, to: candTo + shift)
                add("lsd_vs_ref_db", M.logSpectralDistance(spec, refSpec, maxBin: 1024 / 2), "dB")
                let ma = M.modulationSpectrum(x, from: candFrom, to: candTo, sampleRate: sr)
                let mb = M.modulationSpectrum(reference.samples, from: candFrom + shift, to: candTo + shift, sampleRate: sr)
                add("modspec_dev_db", M.modulationDeviation(ma, mb), "dB")
            }
        }

        // Source pitch (YIN, voiced frames) for the pitch metrics.
        let isVoiced = source.kind != .unvoicedPhoneme
        let (fmin, fmax) = source.kind == .carrier ? (150.0, 1900.0) : (75.0, 600.0)
        let srcTrack = M.yinTrack(source.samples, start: 0, end: source.samples.count, sampleRate: sr,
                                  hop: Int(0.005 * sr), fmin: fmin, fmax: fmax)
        let srcF0 = M.medianF0(srcTrack)
        let srcAp = M.median(srcTrack.filter { $0.f0 != nil }.map(\.aperiodicity))
        func f0Track(_ from: Int, _ to: Int, hopSeconds: Double) -> [M.PitchFrame] {
            M.yinTrack(x, start: from, end: to, sampleRate: sr, hop: max(1, Int(hopSeconds * sr)),
                       fmin: fmin, fmax: fmax, levelRef: on.steadyRMS)
        }
        let seconds = { (f: Int) in Double(f) / sr }

        switch scenario.family {
        case .fixedRate(let r):
            let from = first.open + Int(0.3 * sr), to = min(first.close, first.open + Int(3.3 * sr)) - Int(0.05 * sr)
            if source.isProbe {
                let rates = M.localRate(M.sweepTrack(x, from: from, to: to, sampleRate: sr))
                if let med = M.median(rates.map(\.rate)) {
                    add("duration_scale", med, "x")
                    add("duration_scale_err_pct", (med / Double(r) - 1) * 100, "%")
                }
            }
            if isVoiced, !source.isProbe, let srcF0 {
                let tr = f0Track(from, first.close, hopSeconds: 0.005)
                if let f = M.medianF0(tr) {
                    if source.kind == .carrier {
                        add("carrier_cents_err", M.cents(f, re: srcF0), "cents")
                    } else {
                        add("f0_err_pct", (f / srcF0 - 1) * 100, "%")
                    }
                }
                if let a = M.median(tr.filter { $0.f0 != nil }.map(\.aperiodicity)), let srcAp {
                    add("aperiodicity_delta", a - srcAp, "dip")
                }
                add("voiced_fraction", M.voicedFraction(tr), "frac")
            }
            // Loop seams: expected at onset + k * loop / rate.
            if let onset = on.toMinus20dB, typical > 0 {
                let loopOut = Double(source.samples.count) / Double(r)
                var worst: Float = 0
                var k = 1.0
                while true {
                    let c = first.open + onset + Int(k * loopOut)
                    if c + Int(0.01 * sr) >= first.close { break }
                    worst = max(worst, M.maxAbsDelta(x, c - Int(0.01 * sr), c + Int(0.01 * sr)))
                    k += 1
                }
                if k > 1 { add("loop_seam_click_ratio", Double(worst / typical), "x") }
            }

        case .fixedPitch(let c):
            if let srcF0, let f = M.medianF0(f0Track(first.open + Int(0.3 * sr), first.close, hopSeconds: 0.005)) {
                add("carrier_cents_err", M.cents(f, re: srcF0) - Double(c), "cents")
            }

        case .pitchStep(let c, let at):
            let stepFrame = appliedFrame(at, sampleRate: sr)
            if let srcF0 {
                let tr = f0Track(first.open + Int(0.1 * sr), first.close, hopSeconds: 0.001)
                // Timed at the YIN window centre (window 1024).
                let series = tr.compactMap { p in p.f0.map { (t: seconds(p.frame + 512), v: M.cents($0, re: srcF0)) } }
                if let s = M.stepResponse(series, stepTime: seconds(stepFrame)) {
                    add("pitch_step_delay10_ms", s.delayTo10 * 1000, "ms")
                    add("pitch_step_delay90_ms", s.delayTo90 * 1000, "ms")
                    add("pitch_step_rise_ms", s.rise10to90 * 1000, "ms")
                }
                let post = series.filter { $0.t >= seconds(stepFrame) + 0.4 }.map(\.v)
                if let m = M.median(post) { add("carrier_cents_err_after_step", m - Double(c), "cents") }
            }
            if typical > 0 {
                add("param_step_click_ratio",
                    Double(M.maxAbsDelta(x, stepFrame, stepFrame + Int(0.1 * sr)) / typical), "x")
            }

        case .rateStep(_, _, let at):
            let stepFrame = appliedFrame(at, sampleRate: sr)
            if source.isProbe {
                let rates = M.localRate(M.sweepTrack(x, from: first.open, to: first.close, sampleRate: sr))
                let series = rates.map { (t: seconds($0.frame), v: $0.rate) }
                if let s = M.stepResponse(series, stepTime: seconds(stepFrame)) {
                    add("rate_step_delay10_ms", s.delayTo10 * 1000, "ms")
                    add("rate_step_delay90_ms", s.delayTo90 * 1000, "ms")
                    add("rate_step_rise_ms", s.rise10to90 * 1000, "ms")
                }
            }
            if isVoiced, !source.isProbe, let srcF0 {
                let tr = f0Track(stepFrame + Int(0.3 * sr), first.close, hopSeconds: 0.005)
                if let f = M.medianF0(tr) {
                    if source.kind == .carrier {
                        add("carrier_cents_err_after_step", M.cents(f, re: srcF0), "cents")
                    } else {
                        add("f0_err_after_step_pct", (f / srcF0 - 1) * 100, "%")
                    }
                }
            }
            if typical > 0 {
                add("param_step_click_ratio",
                    Double(M.maxAbsDelta(x, stepFrame, stepFrame + Int(0.1 * sr)) / typical), "x")
            }

        case .heldPitch, .pitchStepRated, .pitchSweep:
            break   // PitchRunner.rows

        case .gateCycle:
            if intervals.count > 1 {
                let re = M.onset(x, gateFrame: intervals[1].open, openEnd: intervals[1].close, sampleRate: sr)
                add("reonset_m20_ms", ms(re.toMinus20dB) ?? .nan, "ms")
            }

        case .trajectory(_, _, let commandedRate, let commandedCents):
            var onsets: [Double] = []
            var times: [Double] = [], measuredCents: [Double?] = [], measuredRate: [Double?] = []
            var f0Dev: [Double] = []
            for iv in intervals {
                let o = M.onset(x, gateFrame: iv.open, openEnd: iv.close, sampleRate: sr)
                if let m = o.toMinus20dB { onsets.append(Double(m) / sr * 1000) }
                if source.kind == .carrier, let srcF0 {
                    for p in f0Track(iv.open, iv.close, hopSeconds: 0.0025) {
                        times.append(seconds(p.frame + 512))   // YIN window centre
                        measuredCents.append(p.f0.map { M.cents($0, re: srcF0) })
                    }
                } else {
                    if source.isProbe {
                        for r in M.localRate(M.sweepTrack(x, from: iv.open, to: iv.close, sampleRate: sr)) {
                            times.append(seconds(r.frame))
                            measuredRate.append(r.rate)
                        }
                    }
                    if source.kind == .voicedPhoneme, !source.isProbe, let srcF0 {
                        for p in f0Track(iv.open, iv.close, hopSeconds: 0.005) {
                            if let f = p.f0 { f0Dev.append(abs(f / srcF0 - 1) * 100) }
                        }
                    }
                }
            }
            add("traj_onset_m20_median_ms", M.median(onsets), "ms")
            add("traj_onset_m20_max_ms", onsets.max(), "ms")
            if source.kind == .carrier {
                if let t = M.trackingLag(times: times, commanded: { BakeoffScenarios.commanded(commandedCents, at: $0) },
                                         measured: measuredCents) {
                    add("traj_pitch_lag_ms", t.lag * 1000, "ms")
                    add("traj_pitch_rms_cents", t.rmsAtLag, "cents")
                    add("traj_pitch_rms_cents_zero_lag", t.rmsAtZero, "cents")
                }
            } else if source.isProbe {
                if let t = M.trackingLag(times: times, commanded: { BakeoffScenarios.commanded(commandedRate, at: $0) },
                                         measured: measuredRate) {
                    add("traj_rate_lag_ms", t.lag * 1000, "ms")
                    add("traj_rate_rms_err", t.rmsAtLag, "x")
                    add("traj_rate_rms_err_zero_lag", t.rmsAtZero, "x")
                }
            } else if !commandedCents.contains(where: { $0.v != 0 }) {
                // Pitch held (r17 phoneme arm); a height-coupled trajectory is measured by PitchRunner.
                add("traj_f0_dev_p95_pct", M.percentile(f0Dev, 95), "%")
            }
        }
        return rows
    }
}
