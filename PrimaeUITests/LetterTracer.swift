// LetterTracer.swift
// PrimaeUITests
//
// Traces the CURRENT letter the way a child does: each stroke in order,
// in its own direction, through every checkpoint, finger down at the
// stroke's start and up at its end, at a slow, steady speed. Shared by
// every suite that draws (2026-10-21, lane H: "make sure that in testing
// when you draw the letter you actually draw it properly").
//
// WHERE THE GEOMETRY COMES FROM. Not from strokes.json, and not from any
// arithmetic in this file: the app publishes its active tracker's
// checkpoints already mapped to window points through the DEBUG-only
// `tracing-geometry-hook` (PrimaeNative/Features/Tracing/
// TracingGeometryTestHook.swift; armed by `-tracingGeometryHook`). So the
// path drawn is the path the app will score, in the weight and glyph rect
// the app itself loaded.
//
// HOW THE TOUCH IS MADE. XCUICoordinate's public API offers one straight
// segment per touch (`press(forDuration:thenDragTo:)`); chaining them lifts
// the finger at every vertex, which is a different input (a freeWrite
// "stroke" per segment, and a lift is the freeWrite done-signal). A letter
// stroke is a polyline under ONE continuous contact, and the only XCTest
// facility that can express that is the event-synthesis layer the public
// API is built on: `XCPointerEventPath` (touch down, moves at time
// offsets, lift) inside an `XCSynthesizedEventRecord`. Both classes ship in
// XCUIAutomation.framework but are not in its public headers, so they are
// reached through the Objective-C runtime here, in the TEST bundle only —
// nothing private touches the app. If a future Xcode drops a selector,
// `synthesize` fails the test loudly with the missing selector's name.
//
// COORDINATE SPACE — MEASURED on the physical iPad (2026-10-21, landscape):
// the hook's points are interface-oriented app points (its canvas frame
// equals XCUITest's frame for the canvas element, 80,64,1270,874), and a
// public `press(thenDragTo:)` along them completes I's guided phase. The
// synthesized path, though, takes the device's NATIVE (portrait) screen
// space: fed interface points it hit nothing under any orientation value.
// So every sample goes through `screenTransform`, the affine map XCUITest
// itself reports via the public `XCUICoordinate.screenPoint` — no
// orientation arithmetic of our own — with orientation 1 (native).

import XCTest
import Foundation
import ObjectiveC

// MARK: - The app's published state

/// One decoded `tracing-geometry-hook` reading.
struct TracingHookSnapshot: Decodable {
    struct CompletedLetter: Decodable {
        let letter: String
        let probe: String?
        let scores: [String: Double]
        let form: Double?
        let rec: String?
        let conf: Double?
    }

    let letter: String
    let phase: String
    let parked: Bool
    let blocked: Bool
    let probe: String
    /// [x, y, width, height] of the tracing canvas, window points.
    let canvas: [Double]
    let radiusPt: Double
    /// strokes[i][j] = [x, y] window points of checkpoint j of stroke i.
    let strokes: [[[Double]]]
    /// progress[i] = [nextCheckpoint, complete(0/1)] for stroke i.
    let progress: [[Int]]
    let trackerComplete: Bool
    let scores: [String: Double]
    let completed: [CompletedLetter]

    var checkpointsHit: Int {
        zip(strokes, progress).reduce(0) { acc, pair in
            acc + (pair.1[1] == 1 ? pair.0.count : pair.1[0])
        }
    }
    var checkpointsTotal: Int { strokes.reduce(0) { $0 + $1.count } }
    var canvasFrame: CGRect { CGRect(x: canvas[0], y: canvas[1], width: canvas[2], height: canvas[3]) }

    /// Compact, human-readable state for a failure message.
    var summary: String {
        "letter=\(letter) phase=\(phase) probe=\(probe) parked=\(parked) blocked=\(blocked) "
        + "hit=\(checkpointsHit)/\(checkpointsTotal) progress=\(progress) "
        + "trackerComplete=\(trackerComplete) scores=\(scores)"
    }
}

// MARK: - Tracer

enum LetterTracer {

    /// The launch argument that arms the app-side hook.
    static let launchArgument = "-tracingGeometryHook"

    /// Finger speed along the path, points per second. About 4 cm/s on a
    /// 13-inch iPad (≈ 52 pt per cm): a slow, deliberate trace of the kind
    /// a 5–6-year-old makes on a guided letter, well below a swipe.
    static let childSpeed: Double = 200

    /// Touch sample rate of the synthesized path (the digitizer's 60 Hz
    /// finger rate; the dispatcher keeps samples ≥ 1.5 pt apart).
    static let sampleRate: Double = 60

    static func snapshot(_ app: XCUIApplication) -> TracingHookSnapshot? {
        let element = app.descendants(matching: .any)["tracing-geometry-hook"]
        guard element.exists, let data = element.label.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(TracingHookSnapshot.self, from: data)
    }

    /// Poll the hook until `condition` holds or `timeout` passes. Returns
    /// the matching snapshot, or nil (the caller reports `last`).
    static func waitForSnapshot(_ app: XCUIApplication,
                                timeout: TimeInterval,
                                last: inout TracingHookSnapshot?,
                                where condition: (TracingHookSnapshot) -> Bool) -> TracingHookSnapshot? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let s = snapshot(app) {
                last = s
                if condition(s) { return s }
            }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return nil
    }

    /// Trace the letter described by `snapshot` — every stroke, in order,
    /// in direction, through every checkpoint — one continuous touch per
    /// stroke with a short pause between strokes (the child moving the
    /// finger to the next start).
    static func traceLetter(_ snapshot: TracingHookSnapshot,
                            in app: XCUIApplication,
                            file: StaticString = #filePath, line: UInt = #line) {
        let toScreen = screenTransform(app)
        for (index, stroke) in snapshot.strokes.enumerated() {
            let points = stroke.map { CGPoint(x: $0[0], y: $0[1]) }
            guard points.count >= 2 else { continue }
            let samples = densified(points).map { (point: $0.point.applying(toScreen), offset: $0.offset) }
            synthesize(path: samples, name: "trace \(snapshot.letter) stroke \(index + 1)", file: file, line: line)
            Thread.sleep(forTimeInterval: 0.4)
        }
    }

    /// Time-stamped samples along the polyline at `childSpeed`, sampled at
    /// `sampleRate`, with every checkpoint itself included as a sample, a
    /// brief dwell at touch-down and a brief hold before the lift.
    static func densified(_ points: [CGPoint]) -> [(point: CGPoint, offset: TimeInterval)] {
        let step = childSpeed / sampleRate
        let dwell: TimeInterval = 0.08
        var out: [(CGPoint, TimeInterval)] = [(points[0], 0), (points[0], dwell)]
        var t = dwell
        for (a, b) in zip(points, points.dropFirst()) {
            let length = hypot(b.x - a.x, b.y - a.y)
            let n = max(1, Int((length / step).rounded(.up)))
            for i in 1...n {
                let f = CGFloat(i) / CGFloat(n)
                t += Double(length) / Double(n) / childSpeed
                out.append((CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f), t))
            }
        }
        out.append((points[points.count - 1], t + 0.05))
        return out
    }

    // MARK: Event synthesis (XCUIAutomation, via the ObjC runtime)

    /// `samples` in native screen points (see `screenTransform`).
    private static func synthesize(path samples: [(point: CGPoint, offset: TimeInterval)],
                                   name: String, file: StaticString, line: UInt) {
        guard let pathClass = NSClassFromString("XCPointerEventPath"),
              let recordClass = NSClassFromString("XCSynthesizedEventRecord") else {
            XCTFail("XCPointerEventPath / XCSynthesizedEventRecord not found in this XCTest", file: file, line: line)
            return
        }
        for (cls, selectors): (AnyClass, [String]) in [(pathClass, ["initForTouchAtPoint:offset:", "moveToPoint:atOffset:", "liftUpAtOffset:"]),
                                 (recordClass, ["initWithName:interfaceOrientation:", "addPointerEventPath:", "synthesizeWithError:"])] {
            for sel in selectors where !class_respondsToSelector(cls, NSSelectorFromString(sel)) {
                XCTFail("\(cls) no longer responds to \(sel) — the touch synthesis shim needs updating",
                        file: file, line: line)
                return
            }
        }
        class_addProtocol(pathClass, PointerEventPathShim.self)
        class_addProtocol(recordClass, SynthesizedEventRecordShim.self)
        guard let pathType = pathClass as? PointerEventPathShim.Type,
              let recordType = recordClass as? SynthesizedEventRecordShim.Type else {
            XCTFail("could not bind the touch synthesis shims", file: file, line: line)
            return
        }
        let path = pathType.init(touchAt: samples[0].point, offset: samples[0].offset)
        for sample in samples.dropFirst() {
            path.move(to: sample.point, atOffset: sample.offset)
        }
        path.liftUp(atOffset: (samples.last?.offset ?? 0) + 0.02)
        let record = recordType.init(name: name, interfaceOrientation: 1)  // native screen space
        record.add(path)
        do {
            try record.synthesize()
        } catch {
            XCTFail("synthesizing '\(name)' failed: \(error)", file: file, line: line)
        }
    }

    /// Interface-oriented app points -> the device's native screen space,
    /// derived from XCUITest's own public `screenPoint` (three reference
    /// coordinates fix the affine map), never from orientation arithmetic.
    static func screenTransform(_ app: XCUIApplication) -> CGAffineTransform {
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let o = origin.screenPoint
        let x = origin.withOffset(CGVector(dx: 100, dy: 0)).screenPoint
        let y = origin.withOffset(CGVector(dx: 0, dy: 100)).screenPoint
        return CGAffineTransform(a: (x.x - o.x) / 100, b: (x.y - o.y) / 100,
                                 c: (y.x - o.x) / 100, d: (y.y - o.y) / 100,
                                 tx: o.x, ty: o.y)
    }
}

// Selector shims for the two runtime-bound classes. The selectors are the
// classes' own (checked with `class_respondsToSelector` before use).
@objc private protocol PointerEventPathShim: NSObjectProtocol {
    @objc(initForTouchAtPoint:offset:) init(touchAt point: CGPoint, offset: TimeInterval)
    @objc(moveToPoint:atOffset:) func move(to point: CGPoint, atOffset offset: TimeInterval)
    @objc(liftUpAtOffset:) func liftUp(atOffset offset: TimeInterval)
}

@objc private protocol SynthesizedEventRecordShim: NSObjectProtocol {
    @objc(initWithName:interfaceOrientation:) init(name: String, interfaceOrientation: Int)
    @objc(addPointerEventPath:) func add(_ path: PointerEventPathShim)
    @objc(synthesizeWithError:) func synthesize() throws
}

// MARK: - Recognition assertions shared by the suites

extension LetterTracer {

    /// The freeWrite star threshold (`LearningPhaseController
    /// .starThreshold(for: .freeWrite)`), restated: a test cannot import
    /// the app module. A drawing "passes" at or above it.
    static let freeWritePassingScore: Double = 0.4

    /// The hook's canvas frame must be the frame XCUITest sees for the
    /// canvas element, or the published points are in a different space
    /// from the one the synthesized touch lands in.
    static func assertHookMatchesCanvas(_ snapshot: TracingHookSnapshot, in app: XCUIApplication,
                                        file: StaticString = #filePath, line: UInt = #line) {
        let canvas = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Schreibfläche")).firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 5), "the tracing canvas element must exist", file: file, line: line)
        let seen = canvas.frame
        let published = snapshot.canvasFrame
        let delta = max(abs(seen.minX - published.minX), abs(seen.minY - published.minY),
                        abs(seen.width - published.width), abs(seen.height - published.height))
        XCTAssertLessThanOrEqual(delta, 2.0,
            "hook canvas \(published) disagrees with XCUI canvas \(seen) — the published points would miss",
            file: file, line: line)
    }

    /// Cold probe (pretest/post-test/delayed): lands directly in freeWrite.
    /// Traces the letter and asserts it was recognised: every checkpoint
    /// of the letter hit in order by the trace, and the scored freeWrite
    /// production at or above the passing score.
    @discardableResult
    static func traceColdProbeAndAssertRecognised(_ app: XCUIApplication, letter: String, probe: String,
                                                  file: StaticString = #filePath,
                                                  line: UInt = #line) -> TracingHookSnapshot.CompletedLetter? {
        var last: TracingHookSnapshot?
        guard let ready = waitForSnapshot(app, timeout: 15, last: &last, where: {
            $0.letter == letter && $0.phase == "freeWrite" && $0.probe == probe && !$0.strokes.isEmpty && !$0.blocked
        }) else {
            XCTFail("the \(probe) probe for \(letter) never reached a traceable freeWrite: \(last?.summary ?? "no hook")",
                    file: file, line: line)
            return nil
        }
        assertHookMatchesCanvas(ready, in: app, file: file, line: line)
        traceLetter(ready, in: app, file: file, line: line)
        if let after = snapshot(app) {
            XCTAssertEqual(after.checkpointsHit, after.checkpointsTotal,
                           "the trace must pass every checkpoint of \(letter) in order: \(after.summary)",
                           file: file, line: line)
        }
        return waitForCompletion(app, letter: letter, probe: probe, file: file, line: line)
    }

    /// Wait for the completed-letter record and assert its freeWrite score.
    static func waitForCompletion(_ app: XCUIApplication, letter: String, probe: String?,
                                  timeout: TimeInterval = 15,
                                  file: StaticString = #filePath,
                                  line: UInt = #line) -> TracingHookSnapshot.CompletedLetter? {
        var last: TracingHookSnapshot?
        let match: (TracingHookSnapshot.CompletedLetter) -> Bool = { $0.letter == letter && $0.probe == probe }
        guard let done = waitForSnapshot(app, timeout: timeout, last: &last, where: { $0.completed.contains(where: match) }),
              let entry = done.completed.last(where: match) else {
            XCTFail("no completed session recorded for \(letter) (probe \(probe ?? "none")): \(last?.summary ?? "no hook")",
                    file: file, line: line)
            return nil
        }
        let score = entry.scores["freeWrite"] ?? -1
        XCTAssertGreaterThanOrEqual(score, freeWritePassingScore,
            "the freeWrite production of \(letter) must score in the passing range: scores=\(entry.scores) "
            + "form=\(entry.form.map { String($0) } ?? "nil") recognised=\(entry.rec ?? "nil")",
            file: file, line: line)
        return entry
    }
}

extension XCUIApplication {
    /// The app as every UI test launches it. Protocol r14 stops a sound-arm
    /// session without headphones, and automated runs have none, so the
    /// requirement is waived by the launch argument the app reads
    /// (`HeadphoneRequirement.testWaiverArgument`; the literal is repeated
    /// here because this target does not import the app module).
    static func primaeUnderTest() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-allowNonHeadphoneRoute"]
        return app
    }
}
