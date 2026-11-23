// Contention coverage for `CoreMLLetterRecognizer`'s shared model cache.
//
// Audit finding 20's precondition. Every existing recognizer test
// injects a stub classifier (`CoreMLLetterRecognizerTests` says so in
// its own header), so `loadModelIfNeeded` — the lock, the shared
// cache, and the lazy VNCoreMLModel load behind them — was exercised
// by ZERO tests. Swapping the lock primitive under code nothing runs is
// not a refactor, it is a guess.
//
// WHAT THIS CAN AND CANNOT SEE.
//   - Deadlock: caught, as a NAMED failure, by a deadline that is
//     decided on dedicated OS threads (see "WHY OFF THE POOL" below).
//   - Torn read of the cache: caught, as disagreement between
//     concurrent probes.
//   - Double LOAD on a cold cache: NOT caught. The cache is process-wide
//     and another suite may have warmed it first, and it is private so a
//     test cannot reset it. A double load costs ~50 ms and a discarded
//     handle; it is not a correctness fault.
//
// The probes ALSO assert that the answer is `true` (2026-09-04).
// Agreement alone holds just as well when nothing loads (CI run 1633's
// retry passed in 0.001 s agreeing on "not available"), so the
// availability assertion turns that vacuous pass into the failure it is.
//
// WHY OFF THE POOL (2026-11-23). These tests used to probe through the
// async `isModelAvailable()` under `.timeLimit` (60 s, then 3 min, then
// 10 min), and every limit was eventually overrun on CI with nothing
// wrong in the cache. CI run 45232891651 (main 28136d3c), job
// 137896855428: the model's first load logged "ok after 0.30 s" at
// 18:27:17, and all three tests still hit "Time limit was exceeded:
// 600.000 seconds" at 18:37:00. In that same process, ordinary untimed
// tests reported "passed after 1105 s" (a WAV-format check, a mean of
// two numbers): with ~1800 Swift Testing tests started in parallel on a
// small hosted runner, every `await` waits minutes for a pool thread to
// resume on, and a probe through the async entry needs two pool hops
// per call. The 10-minute limit had been eroding for a week — load to
// pass took 282 s (job 133996095567), 449 s (134031528139), 382 s
// (134825012421), > 583 s (137896855428) — until r27's added tests
// tipped it over. A time limit on that path measured the scheduler.
//
// So the probes now call `CoreMLLetterRecognizer.loadModelBlocking()`
// (the synchronous body `isModelAvailable()` runs in its detached Task)
// on dedicated threads, and a watcher thread waits for them with a
// deadline. A wedged lock still fails by name; a busy pool can delay
// the test's single resumption but cannot change its verdict. There is
// deliberately no `.timeLimit`: the deadline it stood in for is now
// enforced where the scheduler cannot reach it.
//
// HISTORICAL NOTE: when first written, the model did not resolve at
// all, so the probes agreed on `nil` — a weaker statement than agreeing
// on one shared instance.

import Testing
import Foundation
@testable import PrimaeNative

@Suite struct RecognizerModelCacheTests {

    /// Three concurrent probes: enough for a torn read to show as
    /// disagreement. They run on dedicated threads, so the count no
    /// longer has to be kept small to spare the cooperative pool.
    private static let probeCount = 3

    /// How long the dedicated probe threads may take before the lock is
    /// declared wedged. A deadlock never returns, so any finite deadline
    /// catches it; this one only has to clear a slow first load, and the
    /// slowest first load in any CI log on record is 0.68 s (job
    /// 134031528139, 2026-11-17). The threads are preemptively scheduled
    /// OS threads, not pool threads, so the deadline is not shared with
    /// the 1800 other tests running in the same process.
    private static let deadlineSeconds: TimeInterval = 120

    /// Runs `body` on `threads` dedicated OS threads, released together,
    /// and decides the verdict OFF the cooperative pool: a watcher thread
    /// waits on the group with a deadline. Returns every thread's answers,
    /// or `nil` if any thread had not returned by the deadline — i.e. the
    /// lock did not come back. The only pool work left is the single
    /// resumption of the test after the verdict, which can be late but
    /// cannot change it.
    private static func runOffPool(threads: Int,
                                   _ body: @escaping @Sendable () -> [Bool]) async -> [Bool]? {
        await withCheckedContinuation { (continuation: CheckedContinuation<[Bool]?, Never>) in
            let lock = NSLock()
            var results: [Bool] = []
            let group = DispatchGroup()
            let release = DispatchSemaphore(value: 0)
            for _ in 0..<threads {
                group.enter()
                Thread {
                    release.wait()
                    let answers = body()
                    lock.lock(); results += answers; lock.unlock()
                    group.leave()
                }.start()
            }
            Thread {
                for _ in 0..<threads { release.signal() }
                let returned = group.wait(timeout: .now() + deadlineSeconds) == .success
                lock.lock(); let collected = results; lock.unlock()
                continuation.resume(returning: returned ? collected : nil)
            }.start()
        }
    }

    @Test func concurrentProbesAgreeAndTerminate() async {
        guard let answers = await Self.runOffPool(threads: Self.probeCount, {
            [CoreMLLetterRecognizer.loadModelBlocking()]
        }) else {
            Issue.record("the model-cache lock did not return within \(Self.deadlineSeconds) s on \(Self.probeCount) dedicated threads — a deadlock in loadModelIfNeeded")
            return
        }
        #expect(answers.count == Self.probeCount,
                "expected \(Self.probeCount) probes to return, got \(answers.count)")
        #expect(Set(answers).count == 1,
                "concurrent probes disagreed (\(answers)) — a torn read of the shared model cache")
        #expect(answers.allSatisfy { $0 },
                "the bundled model did not resolve (\(answers)) — agreement on 'unavailable' is not a cache test")
    }

    /// Repeated probes must agree with each other: once the cache holds a
    /// model it short-circuits, and a cache that re-decided per call would
    /// show up here as drift.
    @Test func repeatedProbesAreStable() async {
        guard let answers = await Self.runOffPool(threads: 1, {
            (0..<5).map { _ in CoreMLLetterRecognizer.loadModelBlocking() }
        }) else {
            Issue.record("the model-cache lock did not return within \(Self.deadlineSeconds) s — a deadlock in loadModelIfNeeded")
            return
        }
        #expect(answers.count == 5)
        #expect(answers.first == true, "the bundled model must resolve for stability to mean anything")
        #expect(Set(answers).count == 1,
                "repeated probes drifted (\(answers)) — the cache is not stable")
    }

    /// A second instance shares the STATIC cache, so it must agree with
    /// the first through the PUBLIC async entry. This is the property that
    /// makes the cache worth having and the one a mis-scoped lock would
    /// break. The off-pool probe first proves the lock returns, so the
    /// async calls below cannot hang the run even if it ever stopped
    /// returning; they carry no time limit because their latency is the
    /// pool's, not the cache's.
    @Test func separateInstancesShareOneCache() async {
        guard await Self.runOffPool(threads: 1, { [CoreMLLetterRecognizer.loadModelBlocking()] }) != nil else {
            Issue.record("the model-cache lock did not return within \(Self.deadlineSeconds) s — a deadlock in loadModelIfNeeded")
            return
        }
        let a = CoreMLLetterRecognizer(classifier: { _ in [] })
        let b = CoreMLLetterRecognizer(classifier: { _ in [] })
        let answerA = await a.isModelAvailable()
        let answerB = await b.isModelAvailable()
        #expect(answerA == answerB,
                "two instances disagreed (\(answerA) vs \(answerB)) — the cache is not shared")
        #expect(answerA, "the bundled model must resolve — see the file header")
    }
}
