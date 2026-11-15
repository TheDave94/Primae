// FreeWriteAttemptCheckTests.swift
// PrimaeNativeTests
//
// Protocol r25 (David's ruling 2026-11-15): the free-writing attempt
// check. Pins (1) the pure geometry over the five bundled study glyphs —
// real letters, wobbly, slanted, squeezed, small, one continuous stroke
// and with a stray mark pass; empty, scribble, line, circle and a clearly
// wrong letter fail — and (2) the study flow: a rejected training attempt
// is its own row and the child retries, at most twice; cold probes and
// proctor-closed productions never retry; the attempt number resets.
// Calibration evidence: wt-primae-audit-notes/attempt-check-2026-11-15.

import Testing
import Foundation
import CoreGraphics
@testable import PrimaeNative

@MainActor
fileprivate final class AttemptPromptSpy: PromptPlaying {
    private(set) var keys: [PromptPlayer.PromptKey] = []
    func play(_ key: PromptPlayer.PromptKey, fallbackText: String) { keys.append(key) }
    func count(_ key: PromptPlayer.PromptKey) -> Int { keys.filter { $0 == key }.count }
    func stop() {}
    func playSuccessChime() {}
    func playTapChime() {}
    func playWrongTapChime() {}
    func playStrokeTick() {}
}

fileprivate struct AttemptSubsetProvider: LetterResourceProviding {
    private let base = BundleLetterResourceProvider()
    private let letters: Set<String>
    init(letters: Set<String>) { self.letters = letters }
    var bundle: Bundle { base.bundle }
    var searchBundles: [Bundle] { base.searchBundles }
    func allResourceURLs() -> [URL] {
        base.allResourceURLs().filter { url in letters.contains { url.path.contains("/" + $0 + "/") } }
    }
    func resourceURL(for relativePath: String) -> URL? { base.resourceURL(for: relativePath) }
}

/// Drawings in canvas points, one array per stroke.
fileprivate typealias Drawing = [[CGPoint]]

@Suite(.serialized) @MainActor struct FreeWriteAttemptCheckTests {

    /// The study iPad's free-writing canvas.
    private let canvas = CGSize(width: 1270, height: 874)

    private func makeRepo(_ letters: Set<String>) -> LetterRepository {
        LetterRepository(resources: AttemptSubsetProvider(letters: letters), cache: NullLetterCache(),
                         userDefaults: UserDefaults(suiteName: "attempt-check-\(UUID().uuidString)") ?? .standard,
                         weight: .regular)
    }

    /// The five study letters as the TRACKER holds them on the study
    /// canvas after layout — canvas fractions and the mapped checkpoint
    /// radius, the reference the app's check sees and the export writes
    /// as `referenceStrokes`. Under test `normalizedGlyphRect` returns nil
    /// (`isRunningTests`), so the VM's tracker keeps the bundle's
    /// glyph-box-relative strokes; this applies the mapping the app
    /// applies after layout (`reloadStrokeCheckpoints`) through the
    /// guard-free rect. Without it every geometry test here ran against
    /// a distorted I (radius 0.1, a long slant; device, 2026-11-15).
    private func glyphs() -> [String: LetterStrokes] {
        var deps = TracingDependencies.stub
        deps.repo = makeRepo(Set(TrainedLetterSubset.studyLetters))
        let vm = TracingViewModel(deps)
        vm.canvasSize = canvas
        var out: [String: LetterStrokes] = [:]
        for name in TrainedLetterSubset.studyLetters {
            vm.loadLetter(name: name)
            guard let source = vm.strokeTracker.definition, source.letter == name,
                  let rect = PrimaeLetterRenderer.computeNormalizedGlyphRect(for: name, canvasSize: canvas)
            else { continue }
            out[name] = StrokeTracker.cellDefinition(from: source, glyphRect: rect)
        }
        return out
    }

    @Test("the fixture's references are the canvas-mapped ones the app exports")
    func fixtureMatchesExportedReferences() throws {
        let refs = glyphs()
        #expect(refs.count == TrainedLetterSubset.studyLetters.count)
        // Every study-iPad export since r16 carries checkpointRadius
        // 0.047762962962962965 for these letters on the 1270 x 874 canvas,
        // and I's first checkpoint at (0.5105, 0.2376) (audit-2026-11-10
        // design-round export, rawtraces.json, canvas 1270 x 874).
        for (name, ref) in refs {
            #expect(abs(ref.checkpointRadius - 0.047763) < 0.0005, "\(name): radius \(ref.checkpointRadius)")
        }
        let iFirst = try #require(refs["I"]?.strokes.first?.checkpoints.first)
        #expect(abs(iFirst.x - 0.5105) < 0.001 && abs(iFirst.y - 0.2376) < 0.001, "I starts at \(iFirst)")
    }

    // MARK: drawing helpers

    private func densify(_ s: [CGPoint], step: CGFloat = 4) -> [CGPoint] {
        guard let first = s.first else { return [] }
        var out = [first]
        for i in s.indices.dropFirst() {
            let a = s[i - 1], b = s[i]
            let n = max(1, Int(hypot(b.x - a.x, b.y - a.y) / step))
            for j in 1...n {
                let t = CGFloat(j) / CGFloat(n)
                out.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        return out
    }

    private func letter(_ ref: LetterStrokes) -> Drawing {
        ref.strokes.map { densify($0.checkpoints.map { CGPoint(x: $0.x * canvas.width, y: $0.y * canvas.height) }) }
    }

    private func bounds(_ d: Drawing) -> CGRect {
        let p = d.flatMap { $0 }
        let xs = p.map(\.x), ys = p.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    private func map(_ d: Drawing, _ f: (CGPoint) -> CGPoint) -> Drawing { d.map { $0.map(f) } }

    /// Sideways wobble of `amplitude` x the glyph height, `cycles` per stroke.
    private func wobble(_ d: Drawing, amplitude: CGFloat, cycles: CGFloat = 2.5) -> Drawing {
        let h = bounds(d).height
        return d.map { s in
            s.indices.map { i in
                let a = s[max(i - 3, 0)], b = s[min(i + 3, s.count - 1)]
                let dx = b.x - a.x, dy = b.y - a.y, n = max(hypot(dx, dy), 1e-9)
                let off = amplitude * h * sin(cycles * 2 * .pi * CGFloat(i) / CGFloat(max(s.count - 1, 1)))
                return CGPoint(x: s[i].x - dy / n * off, y: s[i].y + dx / n * off)
            }
        }
    }

    private func check(_ d: Drawing, _ ref: LetterStrokes) -> FreeWriteAttemptCheck.Result {
        var points: [CGPoint] = []
        var starts: [Int] = []
        for s in d where !s.isEmpty { starts.append(points.count); points += s }
        return FreeWriteAttemptCheck.evaluate(points: points, strokeStartIndices: starts, reference: ref,
                                              frame: CGRect(origin: .zero, size: canvas))
    }

    /// A seeded back-and-forth scribble over the glyph's box.
    private func scribble(over box: CGRect, steps: Int = 300, seed: UInt64 = 7) -> Drawing {
        var state = seed
        func rnd() -> CGFloat {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat(Double(state >> 11) / Double(1 << 53))
        }
        let w = max(box.width, box.height * 0.6)
        let area = CGRect(x: box.midX - w / 2, y: box.minY, width: w, height: box.height)
        var p = CGPoint(x: area.midX, y: area.midY)
        var s: [CGPoint] = []
        for _ in 0..<steps {
            p.x = min(max(p.x + (rnd() - 0.5) * 60, area.minX), area.maxX)
            p.y = min(max(p.y + (rnd() - 0.5) * 60, area.minY), area.maxY)
            s.append(p)
        }
        return [densify(s)]
    }

    // MARK: - 1. The geometry

    @Test("real letters pass: exact, wobbly, slanted, squeezed, small and moved, one stroke, stray mark")
    func realLettersPass() throws {
        let refs = glyphs()
        #expect(refs.count == 5, "bundle letters: \(refs.keys.sorted())")
        for (name, ref) in refs {
            let r = letter(ref)
            let b = bounds(r), c = CGPoint(x: b.midX, y: b.midY)
            let t: CGFloat = 12 * .pi / 180
            let variants: [(String, Drawing)] = [
                ("exact", r),
                ("wobble 10%", wobble(r, amplitude: 0.10)),
                ("slant 12 deg", map(r) { CGPoint(x: c.x + cos(t) * ($0.x - c.x) - sin(t) * ($0.y - c.y),
                                                  y: c.y + sin(t) * ($0.x - c.x) + cos(t) * ($0.y - c.y)) }),
                ("squeezed 0.6", map(r) { CGPoint(x: c.x + 0.6 * ($0.x - c.x), y: $0.y) }),
                ("stretched 1.5", map(r) { CGPoint(x: c.x + 1.5 * ($0.x - c.x), y: $0.y) }),
                ("small and moved", map(r) { CGPoint(x: 150 + 0.4 * ($0.x - c.x), y: 650 + 0.4 * ($0.y - c.y)) }),
                ("one continuous stroke", [r.flatMap { $0 }]),
                ("stray mark", r + [densify([CGPoint(x: 80, y: 800), CGPoint(x: 120, y: 790)])]),
            ]
            for (label, d) in variants {
                let result = check(d, ref)
                #expect(result.passed, "\(name) \(label) rejected: \(result)")
            }
        }
    }

    @Test("non-attempts fail: empty, a tap, scribble, horizontal line, circle")
    func nonAttemptsFail() throws {
        for (name, ref) in glyphs() {
            let b = bounds(letter(ref)), c = CGPoint(x: b.midX, y: b.midY), h = b.height
            #expect(!check([], ref).passed, "\(name): empty canvas passed")
            #expect(!check([[c, CGPoint(x: c.x + 3, y: c.y + 2)]], ref).passed, "\(name): a tap passed")
            #expect(!check(scribble(over: b), ref).passed, "\(name): scribble passed: \(check(scribble(over: b), ref))")
            let line = [densify([CGPoint(x: c.x - 0.4 * h, y: c.y), CGPoint(x: c.x + 0.4 * h, y: c.y)])]
            #expect(!check(line, ref).passed, "\(name): horizontal line passed: \(check(line, ref))")
            let circle = [(0...120).map { i -> CGPoint in
                let a = CGFloat(i) / 120 * 2 * .pi
                return CGPoint(x: c.x + 0.4 * h * cos(a), y: c.y + 0.5 * h * sin(a))
            }]
            #expect(!check(circle, ref).passed, "\(name): circle passed: \(check(circle, ref))")
        }
    }

    @Test("a clearly wrong letter fails (measured pairs); a letter containing the target is the known leniency")
    func wrongLetters() throws {
        let refs = glyphs()
        for (target, drawn) in [("L", "A"), ("L", "M"), ("F", "I"), ("M", "I"), ("M", "L"), ("I", "M")] {
            let result = check(letter(try #require(refs[drawn])), try #require(refs[target]))
            #expect(!result.passed, "\(drawn) drawn for \(target) passed: \(result)")
        }
        // L for I, the known leniency: a wrong letter that CONTAINS the
        // target passes (0.8516 on the study iPad, 2026-11-15; the Mac
        // calibration's 0.852). Pinned so a change to it is a decision.
        let lForI = check(letter(try #require(refs["L"])), try #require(refs["I"]))
        #expect(lForI.passed, "L drawn for I: \(lForI)")
    }

    // MARK: - 2. The study flow
    // Under test the VM's tracker holds the bundle's unmapped reference
    // (no glyph rect, `isRunningTests`), and the app's check reads that
    // same definition, so these tests draw and check in one frame: they
    // pin the gate and the rows, the geometry is pinned in section 1.

    private func withStudyVM(_ body: (TracingViewModel, JSONParentDashboardStore, AttemptPromptSpy) throws -> Void) rethrows {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("attempt-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = JSONParentDashboardStore(fileURL: url)
        let prompts = AttemptPromptSpy()
        var deps = TracingDependencies.stub
        deps.studyMode = true
        deps.spokenFeedbackInStudy = true
        deps.makePromptPlayer = { _ in prompts }
        deps.dashboardStore = store
        deps.letterRecognizer = StubLetterRecognizer(result: nil)
        deps.repo = makeRepo(["A", "F", "I"])
        let vm = TracingViewModel(deps)
        vm.canvasSize = canvas
        vm.loadLetter(name: "A")
        vm.phaseController.resume(at: .freeWrite)
        try body(vm, store, prompts)
    }

    private func draw(_ d: Drawing, into vm: TracingViewModel) {
        vm.freeWriteRecorder.startSession(now: 100)
        var t: CFTimeInterval = 100
        for (i, s) in d.enumerated() {
            if i > 0 { vm.freeWriteRecorder.beginStroke() }
            for p in s {
                t += 0.01
                vm.freeWriteRecorder.record(point: p, timestamp: t, force: 0, canvasSize: vm.canvasSize)
            }
        }
    }

    private func freeWriteRows(_ store: JSONParentDashboardStore) -> [PhaseSessionRecord] {
        store.snapshot.phaseSessionRecords.filter { $0.phase == LearningPhase.freeWrite.rawName }
    }

    private func scribbleFor(_ vm: TracingViewModel) throws -> Drawing {
        let ref = try #require(vm.strokeTracker.definition)
        return scribble(over: bounds(letter(ref)))
    }

    @Test("training: a scribble is recorded as its own rejected row and the child retries")
    func scribbleIsRejectedAndRecorded() throws {
        try withStudyVM { vm, store, prompts in
            draw(try scribbleFor(vm), into: vm)
            vm.phaseTransitions.completePostFreeWriteRecognition(score: 0.1, result: nil)

            let rows = freeWriteRows(store)
            #expect(rows.count == 1)
            let row = try #require(rows.first)
            #expect(row.completed == false)
            #expect(row.finalizedBy == RowFinalization.attemptRejected.rawValue)
            #expect(row.freeWriteAttempt == 1)
            #expect(row.attemptCheckPassed == false)
            #expect(row.rawTraceID != nil, "the rejected attempt's ink must be kept")
            #expect(prompts.count(.retryCue) == 1)
            #expect(vm.overlayQueue.currentOverlay == nil, "a study retry shows no overlay")
            #expect(!vm.phaseController.isLetterSessionComplete)
            #expect(vm.freeWriteAttempt == 2)
            #expect(vm.freeWriteRecorder.points.isEmpty, "the canvas clears for the retry")
        }
    }

    @Test("training: the real letter passes first time, attempt 1, no retry cue")
    func realLetterAcceptedFirstTime() throws {
        try withStudyVM { vm, store, prompts in
            draw(letter(try #require(vm.strokeTracker.definition)), into: vm)
            vm.phaseTransitions.completePostFreeWriteRecognition(score: 0.9, result: nil)
            let row = try #require(freeWriteRows(store).only)
            #expect(row.completed && row.freeWriteAttempt == 1 && row.attemptCheckPassed == true)
            #expect(prompts.count(.retryCue) == 0)
            #expect(vm.phaseController.isLetterSessionComplete)
        }
    }

    @Test("training: at most two retries, the third attempt is accepted whatever it is")
    func retriesAreCapped() throws {
        try withStudyVM { vm, store, prompts in
            for _ in 1...(FreeWriteAttemptCheck.maxRetries + 1) {
                draw(try scribbleFor(vm), into: vm)
                vm.phaseTransitions.completePostFreeWriteRecognition(score: 0.1, result: nil)
            }
            let rows = freeWriteRows(store)
            #expect(rows.map(\.freeWriteAttempt) == [1, 2, 3])
            #expect(rows.map(\.completed) == [false, false, true])
            #expect(rows.last?.attemptCheckPassed == false, "the capped attempt records that it failed the check")
            #expect(prompts.count(.retryCue) == FreeWriteAttemptCheck.maxRetries)
            #expect(vm.phaseController.isLetterSessionComplete)
        }
    }

    @Test("a cold probe never retries, and records the check passively")
    func coldProbeNeverRetries() throws {
        try withStudyVM { vm, store, prompts in
            #expect(vm.startColdProbe(letter: "A", kind: .pretest) == nil)
            vm.phaseController.resume(at: .freeWrite)
            draw(try scribbleFor(vm), into: vm)
            vm.phaseTransitions.completePostFreeWriteRecognition(score: 0.1, result: nil)
            let row = try #require(freeWriteRows(store).only)
            #expect(row.completed && row.probe == StudyProbe.pretest.rawValue)
            #expect(row.attemptCheckPassed == false && row.freeWriteAttempt == 1)
            #expect(prompts.count(.retryCue) == 0)
        }
    }

    @Test("a production the proctor closes is never retried")
    func proctorClosedNeverRetries() throws {
        try withStudyVM { vm, store, prompts in
            draw(try scribbleFor(vm), into: vm)
            vm.phaseTransitions.completePostFreeWriteRecognition(score: 0.1, result: nil, finalizedBy: .navigation)
            let row = try #require(freeWriteRows(store).only)
            #expect(row.completed && row.finalizedBy == RowFinalization.navigation.rawValue)
            #expect(prompts.count(.retryCue) == 0)
        }
    }

    @Test("the attempt number resets with the letter")
    func attemptResetsOnLoad() throws {
        try withStudyVM { vm, _, _ in
            draw(try scribbleFor(vm), into: vm)
            vm.phaseTransitions.completePostFreeWriteRecognition(score: 0.1, result: nil)
            #expect(vm.freeWriteAttempt == 2)
            vm.loadLetter(name: "F")
            #expect(vm.freeWriteAttempt == 1)
        }
    }

    @Test("a rejected attempt is not a session: the completion rate ignores it")
    func completionRateIgnoresRejectedAttempts() throws {
        try withStudyVM { vm, store, _ in
            draw(try scribbleFor(vm), into: vm)
            vm.phaseTransitions.completePostFreeWriteRecognition(score: 0.1, result: nil)
            draw(letter(try #require(vm.strokeTracker.definition)), into: vm)
            vm.phaseTransitions.completePostFreeWriteRecognition(score: 0.9, result: nil)
            #expect(freeWriteRows(store).map(\.completed) == [false, true])
            #expect(store.snapshot.phaseCompletionRates[LearningPhase.freeWrite.rawName] == 1.0)
        }
    }

    // MARK: - 3. The export

    @Test("the attempt columns are appended last and carry the row's values")
    func exportColumns() {
        #expect(Array(ParentDashboardExporter.phaseRowAppendedColumns.suffix(5)) == ParentDashboardExporter.attemptColumns)
        let check = FreeWriteAttemptCheck.Result(passed: false, shapeScore: 0.4125, lengthRatio: 7.5, extraReversals: 30)
        let rec = PhaseSessionRecord(letter: "A", phase: "freeWrite", completed: false, score: 0.1, schedulerPriority: 0,
                                     context: PhaseRowContext(finalizedBy: .attemptRejected, freeWriteAttempt: 2, attemptCheck: check))
        let f = ParentDashboardExporter.phaseRowAppendedFields(rec, participantId: UUID())
        #expect(Array(f.suffix(5)) == ["2", "false", "0.412", "7.500", "30"])
        #expect(f.count == ParentDashboardExporter.phaseRowAppendedColumns.count)
        let empty = ParentDashboardExporter.phaseRowAppendedFields(
            PhaseSessionRecord(letter: "A", phase: "guided", completed: true, score: 1, schedulerPriority: 0), participantId: UUID())
        #expect(Array(empty.suffix(5)) == ["", "", "", "", ""])
    }
}

private extension Array {
    /// The single element, or nil when there are zero or several.
    var only: Element? { count == 1 ? first : nil }
}
