// PopCaptureUITests.swift
// PrimaeUITests
//
// POPCAP (2026-11-04): a LONG slow writing period on one study letter in one
// sound arm, drawn along the letter's real strokes (`LetterTracer`'s app-side
// geometry hook), while the app records its own output (`PopCapture`,
// launched with `-popCapture`; DEBUG only). One launch per (arm, letter), so
// each run is one capture directory in the app container
// (Documents/popcap/<variant>_<arm>_<letter>-<time>/).
//
// The script is deterministic (a seeded generator per arm+letter), so the
// r16 reference build and every later build get the SAME writing:
//   - observe plays by itself (its sound is part of the capture)
//   - guided: every stroke is traced in several passes (45 %..100 % of its
//     length, lifts between), enough for ~25 s of pen time, without completing early
//   - freeWrite: whole-letter passes, lifts always under the ~2 s quiet
//     window, until at least `minWritingSeconds` of pen time (guided +
//     freeWrite) or the letter ends by itself
//   - speed 50-150 pt/s re-drawn every 0.5-1.2 s; a stall (pen still, 0.2-0.6 s;
//     0.3 s is the idle debounce) about every 1.5 s; lifts of 0.2-1.3 s between
//     strokes (0.8 s is the lift hold)
// `variant` names the build under test; it is edited per build clone.
//
// Physical iPad only (not in CI), like the rest of PrimaeUITests.

import XCTest
import Foundation

final class PopCaptureUITests: XCTestCase {

    static let variant = "VARIANT"
    static let minWritingSeconds = 40.0
    static var speeds = false
    static var fixedSpeed: Double? = nil

    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testPhonemeI() { run(arm: "phoneme", letter: "I") }
    @MainActor func testPhonemeF() { run(arm: "phoneme", letter: "F") }
    @MainActor func testPhonemeA() { run(arm: "phoneme", letter: "A") }
    @MainActor func testPhonemeL() { run(arm: "phoneme", letter: "L") }
    @MainActor func testPhonemeM() { run(arm: "phoneme", letter: "M") }
    @MainActor func testSpatialI() { run(arm: "spatial", letter: "I") }
    @MainActor func testSpatialF() { run(arm: "spatial", letter: "F") }
    @MainActor func testSpatialA() { run(arm: "spatial", letter: "A") }
    @MainActor func testSpatialL() { run(arm: "spatial", letter: "L") }
    @MainActor func testSpatialM() { run(arm: "spatial", letter: "M") }
    // Steady-speed captures (R17D, kept R17E): each stroke at a constant 50 pt/s, then at 150 pt/s, 1.5 s lifts (outside the 0.8 s hold).
    @MainActor func testSpeedsPhonemeA() { Self.speeds = true; run(arm: "phoneme", letter: "A") }
    @MainActor func testSpeedsPhonemeF() { Self.speeds = true; run(arm: "phoneme", letter: "F") }
    @MainActor func testSpeedsPhonemeI() { Self.speeds = true; run(arm: "phoneme", letter: "I") }
    @MainActor func testSpeedsPhonemeL() { Self.speeds = true; run(arm: "phoneme", letter: "L") }
    @MainActor func testSpeedsPhonemeM() { Self.speeds = true; run(arm: "phoneme", letter: "M") }

    // MARK: Scenario

    private struct RNG {
        var s: UInt64
        mutating func next() -> Double {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return Double(s >> 11) / Double(1 << 53)
        }
        mutating func range(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * next() }
    }

    @MainActor
    private func run(arm: String, letter target: String) {
        let app = XCUIApplication.primaeUnderTest()
        app.launchArguments += [
            LetterTracer.launchArgument,
            "-popCapture", "-popCaptureTag", "\(Self.variant)\(Self.speeds ? "speed" : "")_\(arm)_\(target)",
            "-de.flamingistan.primae.audioConditionOverride", arm,
            "-de.flamingistan.primae.trainedSubsetOverride", "AFILM",
        ]
        app.launch()
        XCTAssertTrue(app.enrolNextChildViaRail(), "the child must be enrolled")
        var last: TracingHookSnapshot?
        if let s = LetterTracer.waitForSnapshot(app, timeout: 10, last: &last, where: { _ in true }), s.parked {
            let observe = app.descendants(matching: .any)["Beobachtungsphase"]
            if observe.waitForExistence(timeout: 5) { observe.tap() }
        }
        // Reach the target letter through the study chevron.
        let chevron = app.descendants(matching: .any)["Nächster Buchstabe"]
        for _ in 0..<6 {
            if LetterTracer.snapshot(app)?.letter == target { break }
            XCTAssertTrue(chevron.waitUntilHittable(timeout: 30), "the chevron must be hittable")
            chevron.tap()
            Thread.sleep(forTimeInterval: 1.0)
        }
        guard let guided = LetterTracer.waitForSnapshot(app, timeout: 90, last: &last, where: {
            $0.letter == target && $0.phase == "guided" && !$0.strokes.isEmpty && !$0.blocked
        }) else { return XCTFail("[\(arm) \(target)] never reached guided: \(last?.summary ?? "no hook")") }
        // Every run must draw A in the NEW direction (stroke 0 from the bottom, larger y, up to the apex).
        if target == "A", let first = guided.strokes.first, first.count > 2 {
            XCTAssertGreaterThan(first[0][1], first[first.count - 1][1],
                                 "[\(arm) A] stroke 0 must start at the bottom and end at the apex (first y=\(first[0][1]) last y=\(first[first.count - 1][1]))")
        }
        Thread.sleep(forTimeInterval: 1.0)

        // A stable seed (String.hashValue is per-process randomised): FNV-1a of arm+letter.
        var rng = RNG(s: (arm + target).unicodeScalars.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1.value)) &* 1099511628211 })
        let toScreen = LetterTracer.screenTransform(app)
        var penSeconds = 0.0

        // Guided: several passes per stroke (the last one whole), enough that the
        // guided phase alone carries ~25 s of pen time whatever the letter's length.
        let letterLength = guided.strokes.reduce(0.0) { acc, st in
            acc + zip(st, st.dropFirst()).reduce(0.0) { $0 + hypot($1.1[0] - $1.0[0], $1.1[1] - $1.0[1]) }
        }
        if Self.speeds {
            for stroke in guided.strokes {
                let pts = stroke.map { CGPoint(x: $0[0], y: $0[1]) }
                guard pts.count >= 2 else { continue }
                for v in [50.0, 150.0] {
                    Self.fixedSpeed = v
                    _ = touch(pts, toScreen, &rng, name: "speed \(Int(v)) \(target)")
                    Thread.sleep(forTimeInterval: 1.5)
                }
            }
            Self.fixedSpeed = nil
            Thread.sleep(forTimeInterval: 3.0)
            return
        }
        let passesPerStroke = max(2, Int((3200 / max(letterLength, 1)).rounded(.up)))
        let fractions = (1...passesPerStroke).map { 0.45 + 0.55 * Double($0) / Double(passesPerStroke) }
        for stroke in guided.strokes {
            let pts = stroke.map { CGPoint(x: $0[0], y: $0[1]) }
            guard pts.count >= 2 else { continue }
            for fraction in fractions {
                penSeconds += touch(Self.truncate(pts, fraction), toScreen, &rng, name: "guided \(target)")
                let lift = rng.range(0.2, 1.3); Thread.sleep(forTimeInterval: lift); penSeconds += lift
            }
        }
        // Whole-letter passes in freeWrite.
        var passes = 0
        while passes < 10 {
            guard let s = LetterTracer.waitForSnapshot(app, timeout: 8, last: &last, where: { $0.letter == target && $0.phase == "freeWrite" && !$0.strokes.isEmpty }) else { break }
            if passes > 0, s.checkpointsHit == 0 && penSeconds >= Self.minWritingSeconds { break }
            for stroke in s.strokes {
                let pts = stroke.map { CGPoint(x: $0[0], y: $0[1]) }
                guard pts.count >= 2 else { continue }
                penSeconds += touch(pts, toScreen, &rng, name: "freeWrite \(target)")
                let lift = rng.range(0.2, 1.3); Thread.sleep(forTimeInterval: lift); penSeconds += lift
            }
            passes += 1
            if penSeconds >= Self.minWritingSeconds { break }
        }
        XCTContext.runActivity(named: "[\(arm) \(target)] pen time \(Int(penSeconds)) s, freeWrite passes \(passes), end: \(LetterTracer.snapshot(app)?.summary ?? "no hook")") { _ in }
        Thread.sleep(forTimeInterval: 3.0)   // let the stop fade and the 50 ms drain finish
        XCTAssertGreaterThanOrEqual(penSeconds, 25, "[\(arm) \(target)] the writing period must be long (>= 25 s of pen time)")
    }

    // MARK: Script

    private static func truncate(_ p: [CGPoint], _ f: Double) -> [CGPoint] {
        guard f < 1 else { return p }
        let total = zip(p, p.dropFirst()).reduce(0.0) { $0 + Double(hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y)) }
        var left = total * f, out = [p[0]]
        for (a, b) in zip(p, p.dropFirst()) {
            let l = Double(hypot(b.x - a.x, b.y - a.y))
            if l >= left { let t = CGFloat(l > 0 ? left / l : 0); out.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)); break }
            out.append(b); left -= l
        }
        return out
    }

    /// One continuous contact along `pts` with the scripted speed changes and stalls; returns its duration.
    @MainActor
    private func touch(_ pts: [CGPoint], _ toScreen: CGAffineTransform, _ rng: inout RNG, name: String) -> Double {
        let dt = 1.0 / LetterTracer.sampleRate
        var t = 0.0, speed = rng.range(50, 150), speedUntil = rng.range(0.5, 1.2), nextStall = rng.range(0.8, 2.2)
        var out: [(point: CGPoint, offset: TimeInterval)] = [(pts[0].applying(toScreen), 0), (pts[0].applying(toScreen), 0.08)]
        t = 0.08
        for (a, b) in zip(pts, pts.dropFirst()) {
            let len = Double(hypot(b.x - a.x, b.y - a.y))
            var walked = 0.0
            while walked < len {
                t += dt
                if let f = Self.fixedSpeed { speed = f } else if t > speedUntil { speed = rng.range(50, 150); speedUntil = t + rng.range(0.5, 1.2) }
                if Self.fixedSpeed == nil, t > nextStall { t += rng.range(0.2, 0.6); nextStall = t + rng.range(0.8, 2.2) }
                walked = min(len, walked + speed * dt)
                let f = CGFloat(len > 0 ? walked / len : 1)
                out.append((CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f).applying(toScreen), t))
            }
        }
        t += 0.05
        out.append((out[out.count - 1].point, t))
        LetterTracer.synthesize(paths: [out], name: name)
        return t
    }
}
