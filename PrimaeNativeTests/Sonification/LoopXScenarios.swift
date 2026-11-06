// LoopXScenarios.swift
// PrimaeNativeTests — lane LOOPX (2026-11-03): app-scenario timelines for the
// live kernel, built the way the app builds them.
//
// A scripted pen (120 Hz move samples along straight stroke segments, pauses
// with no samples, lifts and gaps) runs through a model of the playback
// machine as `TouchDispatcher` + `PlaybackController` + `LiveSonificationAudio`
// drive it, with the app's own constants injected by the caller
// (`SoundEnvelope.stallSeconds` / `liftHoldSeconds` / `fadeOutSeconds`,
// `TouchDispatcher.mapVelocityToSpeed`, `SpatialSonification.pitchCents`):
//   - a move while idle plays (kernel open: from silence, or while a stop
//     fade is still sounding); every move re-arms the stall stop;
//   - no move for `stall` while touching stops (fade `fade`);
//   - a lift while sounding holds for `hold`, then stops; a move inside the
//     hold just continues (no open: the machine is still active);
//   - at the lift the rate settles to the pre-flick smoothed velocity (B17);
//   - rate from the EWMA velocity (alpha 0.22, the dispatcher's), pan from
//     canvas x (`x * 2 - 1`), pitch from canvas y in the spatial arm only.
// Mechanism marks (open-from-silence, restart-in-fade, stop, stroke-start
// pan/pitch jumps) label the detector's events.

import Foundation
import CoreGraphics

nonisolated struct LoopXTimeline {
    enum Command { case open(String, fadeIn: Double), close(fade: Double), rate(Float), cents(Float), pan(Float) }
    var commands: [(t: Double, cmd: Command)] = []
    var marks: [(t: Double, label: String)] = []
    var duration = 0.0
}

nonisolated struct LoopXConstants {
    var stall: Double, hold: Double, fade: Double
    var speed: (CGFloat) -> Float
    var pitch: (CGFloat) -> Float
}

/// One stroke: straight segments through canvas-normalised points.
nonisolated struct LoopXStroke {
    var points: [CGPoint]
    var speed: CGFloat                       // pt/s along the path
    var pauses: [(atFraction: Double, seconds: Double)] = []
    var gapAfter: Double = 0.6               // lift to next touch-down
}

nonisolated enum LoopXScenarioBuilder {
    static let canvas = CGSize(width: 1000, height: 750)
    static let sampleDt = 1.0 / 120
    static let alpha: CGFloat = 0.22

    /// Cell-normalised letter point -> canvas-normalised (the letter cell
    /// assumed at x 0.15...0.85, y 0.05...0.95 of the canvas).
    static func canvasPoint(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: 0.15 + 0.7 * x, y: 0.05 + 0.9 * y) }

    /// The study letters' strokes (Regular strokes.json, first and last checkpoint: each is straight).
    static let letterStrokes: [String: [[(Double, Double)]]] = [
        "A": [[(0.583, 0.031), (0.058, 0.959)], [(0.587, 0.039), (0.936, 0.953)], [(0.286, 0.588), (0.798, 0.588)]],
        "F": [[(0.19, 0.04), (0.078, 0.949)], [(0.19, 0.041), (0.94, 0.04)], [(0.15, 0.48), (0.78, 0.48)]],
        "L": [[(0.2, 0.05), (0.09, 0.95)], [(0.09, 0.95), (0.94, 0.95)]],
    ]

    static func letter(_ name: String, speed: CGFloat, gap: Double) -> [LoopXStroke] {
        (letterStrokes[name] ?? []).map { seg in
            LoopXStroke(points: seg.map { canvasPoint($0.0, $0.1) }, speed: speed, gapAfter: gap)
        }
    }

    /// A long zig-zag (top <-> bottom, drifting right), `seconds` at `speed`.
    static func longStroke(speed: CGFloat, seconds: Double, pauses: [(Double, Double)] = []) -> LoopXStroke {
        let length = speed * CGFloat(seconds)
        var pts = [CGPoint(x: 0.2, y: 0.2)]
        var left = length, down = true
        while left > 0 {
            let last = pts[pts.count - 1]
            let leg = min(left, 450)
            let dy = leg / canvas.height * 0.98, dx = leg / canvas.width * 0.2
            pts.append(CGPoint(x: min(0.95, last.x + dx), y: down ? min(0.8, last.y + dy) : max(0.2, last.y - dy)))
            if pts[pts.count - 1].y >= 0.8 || pts[pts.count - 1].y <= 0.2 { down.toggle() }
            left -= leg
        }
        return LoopXStroke(points: pts, speed: speed, pauses: pauses.map { (atFraction: $0.0, seconds: $0.1) }, gapAfter: 1.5)
    }

    /// The timeline for `strokes`, playing `file`; `spatial` adds the pitch drive.
    static func pen(_ strokes: [LoopXStroke], file: String, spatial: Bool, k: LoopXConstants) -> LoopXTimeline {
        var tl = LoopXTimeline()
        var t = 0.2
        var active = false
        var stallAt: Double?, holdAt: Double?
        var stopEndsAt = -1.0
        var lastPan: Float?, lastCents: Float?
        func fire(upTo now: Double) {
            for (deadline, label) in [(stallAt, "stall-stop"), (holdAt, "hold-stop")] {
                if let d = deadline, d <= now, active {
                    tl.commands.append((d, .close(fade: k.fade))); tl.marks.append((d, label))
                    tl.marks.append((d + k.fade, "fade-end"))
                    active = false; stallAt = nil; holdAt = nil; stopEndsAt = d + k.fade
                }
            }
        }
        for stroke in strokes {
            fire(upTo: t)
            let pts = stroke.points.map { CGPoint(x: $0.x * canvas.width, y: $0.y * canvas.height) }
            var segLen: [CGFloat] = []
            for i in 1..<pts.count { segLen.append(hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y)) }
            let total = segLen.reduce(0, +)
            var travelled: CGFloat = 0
            var last = pts[0], lastT = t, smoothed: CGFloat = 0
            var history: [(t: Double, v: CGFloat)] = []
            var pauses = stroke.pauses.sorted { $0.atFraction < $1.atFraction }
            var firstSample = true
            while travelled < total {
                t += sampleDt
                if let p = pauses.first, Double(travelled / total) >= p.atFraction {
                    fire(upTo: t + p.seconds)
                    t += p.seconds; pauses.removeFirst()
                }
                fire(upTo: t)
                travelled = min(total, travelled + stroke.speed * CGFloat(sampleDt))
                var acc: CGFloat = 0, seg = 0
                while seg < segLen.count - 1 && acc + segLen[seg] < travelled { acc += segLen[seg]; seg += 1 }
                let u = segLen[seg] > 0 ? (travelled - acc) / segLen[seg] : 0
                let p = CGPoint(x: pts[seg].x + (pts[seg + 1].x - pts[seg].x) * u,
                                y: pts[seg].y + (pts[seg + 1].y - pts[seg].y) * u)
                let v = hypot(p.x - last.x, p.y - last.y) / CGFloat(max(0.001, t - lastT))
                smoothed = smoothed == 0 ? v : smoothed + alpha * (v - smoothed)
                history.append((t, smoothed))
                last = p; lastT = t
                let nx = p.x / canvas.width, ny = p.y / canvas.height
                let pan = Float(max(-1, min(1, nx * 2 - 1)))
                tl.commands.append((t, .rate(k.speed(smoothed))))
                tl.commands.append((t, .pan(pan)))
                // Jumps matter only into a sound that is still going (the hold).
                let sounding = active
                if firstSample, sounding, let lp = lastPan, abs(lp - pan) > 0.2 { tl.marks.append((t, "pan-jump")) }
                lastPan = pan
                if spatial {
                    let c = k.pitch(ny)
                    tl.commands.append((t, .cents(c)))
                    if firstSample, sounding, let lc = lastCents, abs(lc - c) > 300 { tl.marks.append((t, "pitch-jump")) }
                    lastCents = c
                }
                if !active {
                    tl.commands.append((t, .open(file, fadeIn: 0)))
                    tl.marks.append((t, t < stopEndsAt ? "restart-in-fade" : "open"))
                    active = true
                }
                stallAt = t + k.stall; holdAt = nil
                firstSample = false
            }
            // Lift: B17 settles the held rate to the pre-flick velocity.
            if let lastSample = history.last {
                let v = history.last(where: { $0.t <= lastSample.t - 0.1 })?.v ?? history[0].v
                tl.commands.append((t, .rate(k.speed(v))))
            }
            if active { holdAt = t + k.hold; stallAt = nil }
            t += stroke.gapAfter
        }
        fire(upTo: t + 10)
        tl.duration = max(t, stopEndsAt) + 0.3
        return tl
    }

    struct Case { let name: String; let arm: String; let files: [String]; let timeline: LoopXTimeline }

    /// S1-S4 for both arms; the phoneme arm over every study phoneme, the
    /// spatial arm over the carrier.
    static func catalogue(phonemes: [String], carrier: String, k: LoopXConstants) -> [Case] {
        var out: [Case] = []
        func both(_ name: String, _ strokes: (String) -> [LoopXStroke], letterFile: String? = nil) {
            for f in letterFile.map({ [$0] }) ?? phonemes {
                out.append(Case(name: name, arm: "phoneme", files: [f], timeline: pen(strokes(f), file: f, spatial: false, k: k)))
            }
            out.append(Case(name: name, arm: "spatial", files: [carrier], timeline: pen(strokes(carrier), file: carrier, spatial: true, k: k)))
        }
        for (rate, speed) in [("0.5", CGFloat(50)), ("0.7", CGFloat(150))] {
            both("S1 slow r\(rate) 8s") { _ in [longStroke(speed: speed, seconds: 8)] }
        }
        both("S2 pauses .2/.35/.6") { _ in [longStroke(speed: 150, seconds: 7, pauses: [(0.2, 0.2), (0.45, 0.35), (0.7, 0.6)])] }
        for letter in ["A", "F", "L"] {
            for gap in [0.2, 0.6, 1.0, 1.3] {
                both("S3 \(letter) gap \(gap)", { _ in self.letter(letter, speed: 150, gap: gap) },
                     letterFile: phonemes.first { $0.hasPrefix(letter) })
            }
        }
        // S4: a letter change while the sound is held (a load of a different
        // file closes the voice: `loadAudioFile`), then the new letter's
        // observe sound (fade-in 0.12 s) 0.4 s later; and a change during the
        // stop fade, the observe sound opening 0.1 s later, while it still sounds.
        for (label, delay) in [("in hold", 0.3), ("in stop fade", k.hold + 0.1)] {
            for (from, to) in [(phonemes.first { $0.hasPrefix("A") }!, phonemes.first { $0.hasPrefix("M") }!), (carrier, carrier)] {
                var tl = pen(letter("A", speed: 150, gap: 0.2).prefix(1).map { $0 }, file: from, spatial: from == carrier, k: k)
                let lift = tl.marks.last { $0.label == "hold-stop" }!.t - k.hold
                tl.commands.removeAll { $0.t > lift }; tl.marks.removeAll { $0.t > lift }
                let change = lift + delay
                if delay > k.hold {
                    tl.commands.append((lift + k.hold, .close(fade: k.fade))); tl.marks.append((lift + k.hold, "hold-stop"))
                }
                tl.commands.append((change, .close(fade: 0))); tl.marks.append((change, "letter-change"))
                let openAt = change + (delay > k.hold ? 0.1 : 0.4)
                tl.commands.append((openAt, .open(to, fadeIn: 0.12))); tl.marks.append((openAt, "observe-open"))
                tl.commands.append((openAt + 2.0, .close(fade: k.fade))); tl.marks.append((openAt + 2.0, "stop"))
                tl.duration = openAt + 2.8
                out.append(Case(name: "S4 change \(label)", arm: from == carrier ? "spatial" : "phoneme",
                                files: Array(Set([from, to])).sorted(), timeline: tl))
            }
        }
        return out
    }
}
