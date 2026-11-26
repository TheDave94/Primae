// StrokeAnalysisMemoTests.swift
// PrimaeNativeTests
//
// T1R (2026-11-25): the free-writing stroke analysis runs OFF the main actor
// during the quiet window (`StrokeAnalysisMemo`), and the scoring at the
// window's end reads it back. Measured on the iPad (Debug-Study) it cost
// ~230 ms of main-actor time per call, twice per completion: the 553 ms hang
// at the bubble pause's start. Pinned here: the off-main result is exactly the
// on-main one, the memo returns exactly what was computed for exactly those
// inputs, and a lift prefetches exactly the inputs the scoring will use.

import Testing
import Foundation
import CoreGraphics
@testable import PrimaeNative

@Suite(.serialized) @MainActor struct StrokeAnalysisMemoTests {

    private let canvas = CGSize(width: 1270, height: 874)

    /// Real letters, drawn along their strokes on the canvas, exact and wobbled.
    private func productions() -> [(name: String, points: [CGPoint], starts: [Int], reference: LetterStrokes)] {
        let repo = LetterRepository(resources: BundleLetterResourceProvider(), cache: NullLetterCache())
        let letters = repo.loadLetters().filter { $0.strokes.strokes.contains { $0.checkpoints.count >= 2 } }
        let picked = letters.enumerated().filter { ["A", "F", "I", "L", "M"].contains($0.element.name) || $0.offset % 12 == 0 }.map(\.element)
        var out: [(String, [CGPoint], [Int], LetterStrokes)] = []
        for letter in picked {
            for wobble in [CGFloat(0), 6] {
                var points: [CGPoint] = []; var starts: [Int] = []
                for s in letter.strokes.strokes where s.checkpoints.count >= 2 {
                    starts.append(points.count)
                    let cps = s.checkpoints.map { CGPoint(x: 250 + $0.x * 520, y: 120 + $0.y * 620) }
                    for i in cps.indices.dropFirst() {
                        let a = cps[i - 1], b = cps[i]
                        let n = max(1, Int(hypot(b.x - a.x, b.y - a.y) / 4))
                        for j in 0..<n {
                            let t = CGFloat(j) / CGFloat(n)
                            points.append(CGPoint(x: a.x + (b.x - a.x) * t + wobble * sin(CGFloat(points.count) * 0.35),
                                                  y: a.y + (b.y - a.y) * t))
                        }
                    }
                }
                out.append(("\(letter.id)/w\(Int(wobble))", points, starts, letter.strokes))
            }
        }
        return out
    }

    @Test("the analysis off the main actor equals the analysis on it, exactly, on real letters")
    func offMainEqualsOnMain() async {
        let all = productions()
        #expect(all.count >= 20, "too few productions: \(all.count)")
        for p in all {
            let iso = StrokeProcessScorer.heightNormalised(points: p.points, reference: p.reference,
                                                           frame: CGRect(origin: .zero, size: canvas))
            let onMain = StrokeProcessScorer.computeAnalysis(points: iso.points, strokeStartIndices: p.starts,
                                                             reference: iso.reference)
            let offMain = await Task.detached {
                StrokeProcessScorer.computeAnalysis(points: iso.points, strokeStartIndices: p.starts,
                                                    reference: iso.reference)
            }.value
            #expect(onMain != nil, "\(p.name): nothing comparable")
            #expect(offMain == onMain, "\(p.name): off-main \(String(describing: offMain)) vs on-main \(String(describing: onMain))")
            // And through the memo-backed entry, as the scoring calls it.
            let memoised = StrokeProcessScorer.analyze(points: iso.points, strokeStartIndices: p.starts,
                                                       reference: iso.reference)
            #expect(memoised == onMain, "\(p.name): analyze differs from computeAnalysis")
        }
    }

    @Test("the memo answers exactly the inputs it holds, with exactly what was stored, and keeps the newest")
    func memoKeysOnExactInputs() throws {
        let p = try #require(productions().first)
        let memo = StrokeAnalysisMemo()
        let key = StrokeAnalysisMemo.Key(points: p.points, strokeStartIndices: p.starts, reference: p.reference,
                                         shearLimitDegrees: StrokeProcessScorer.shearLimitDegrees)
        let measures = StrokeProcessScorer.computeAnalysis(points: p.points, strokeStartIndices: p.starts,
                                                           reference: p.reference)
        #expect(memo.lookup(key) == nil)
        memo.store(key, measures)
        #expect(memo.lookup(key)?.measures == measures)
        // One point moved by the smallest step is another production.
        var moved = p.points
        moved[moved.count / 2].x = moved[moved.count / 2].x.nextUp
        let other = StrokeAnalysisMemo.Key(points: moved, strokeStartIndices: p.starts, reference: p.reference,
                                           shearLimitDegrees: StrokeProcessScorer.shearLimitDegrees)
        #expect(memo.lookup(other) == nil, "a different production was answered from the memo")
        let noShear = StrokeAnalysisMemo.Key(points: p.points, strokeStartIndices: p.starts, reference: p.reference,
                                             shearLimitDegrees: 0)
        #expect(memo.lookup(noShear) == nil, "another shear limit was answered from the memo")
        // Capacity: the oldest goes first.
        for i in 0..<StrokeAnalysisMemo.capacity {
            var pts = p.points
            pts[0].y += CGFloat(i + 1)
            memo.store(StrokeAnalysisMemo.Key(points: pts, strokeStartIndices: p.starts, reference: p.reference,
                                              shearLimitDegrees: StrokeProcessScorer.shearLimitDegrees), nil)
        }
        #expect(memo.lookup(key) == nil, "the memo grew past its capacity")
    }

    @Test("a free-writing lift prefetches the analysis of exactly the inputs the scoring will use")
    func liftPrefetchesTheScoringInputs() async throws {
        var deps = TracingDependencies.stub
        deps.studyMode = true
        deps.letterRecognizer = StubLetterRecognizer(result: nil)
        let vm = TracingViewModel(deps)
        vm.canvasSize = canvas
        vm.loadLetter(name: "A")
        vm.phaseController.resume(at: .freeWrite)
        let ref = try #require(vm.strokeTracker.definition)
        let path = ref.strokes[0].checkpoints.map { CGPoint(x: $0.x * canvas.width, y: $0.y * canvas.height) }
        #expect(vm.phaseTransitions.freeWriteAnalysisPrefetch == nil)
        var t: CFTimeInterval = 100
        vm.beginTouch(at: path[0], t: t)
        for p in path.dropFirst() {
            t += 0.02
            vm.updateTouch(at: p, t: t, canvasSize: canvas)
        }
        vm.endTouch()
        let task = try #require(vm.phaseTransitions.freeWriteAnalysisPrefetch, "the lift prefetched nothing")
        let key = await task.value
        // What `scoreFreeWrite` (single cell) and `evaluateAttemptCheck` pass to `analyze`.
        let iso = StrokeProcessScorer.heightNormalised(points: vm.freeWriteRecorder.points, reference: ref,
                                                       frame: CGRect(origin: .zero, size: canvas))
        #expect(!vm.freeWriteRecorder.points.isEmpty)
        #expect(key == StrokeAnalysisMemo.Key(points: iso.points,
                                              strokeStartIndices: vm.freeWriteRecorder.strokeStartIndices,
                                              reference: iso.reference,
                                              shearLimitDegrees: StrokeProcessScorer.shearLimitDegrees),
                "the prefetch analysed other inputs than the scoring uses")
    }
}
