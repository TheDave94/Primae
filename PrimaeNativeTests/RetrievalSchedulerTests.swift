// Unit coverage for the retrieval-practice cadence. Pins the contract on
// every Nth letter selection firing a prompt, the minimum-prior-completions
// guard skipping never-seen letters, the counter resetting on fire, and the
// persisted-counter shape surviving a re-init.

import Testing
import Foundation
@testable import PrimaeNative

@Suite @MainActor struct RetrievalSchedulerTests {

    // Each test uses a fresh UserDefaults state by passing `initialCounter`
    // explicitly. That sidesteps cross-test contamination from the
    // global-singleton UserDefaults the production scheduler reads.
    private func newScheduler(interval: Int = 3, minimumPrior: Int = 1,
                              counter: Int = 0) -> RetrievalScheduler {
        let s = RetrievalScheduler(initialCounter: counter)
        s.interval = interval
        s.minimumPriorCompletions = minimumPrior
        return s
    }

    private func progress(completionCount: Int) -> LetterProgress {
        LetterProgress(completionCount: completionCount, bestAccuracy: 0.5)
    }

    @Test("Cadence: every Nth selection fires a prompt")
    func cadenceFiresEveryNthSelection() {
        let s = newScheduler(interval: 3, minimumPrior: 1, counter: 0)
        let p = progress(completionCount: 5)
        // Calls 1 and 2 should not fire; call 3 should.
        #expect(s.shouldPrompt(for: "A", progress: p) == false)
        #expect(s.shouldPrompt(for: "A", progress: p) == false)
        #expect(s.shouldPrompt(for: "A", progress: p) == true)
        // Counter resets on fire — next 3 calls follow the same cadence.
        #expect(s.shouldPrompt(for: "A", progress: p) == false)
        #expect(s.shouldPrompt(for: "A", progress: p) == false)
        #expect(s.shouldPrompt(for: "A", progress: p) == true)
    }

    @Test("Minimum-prior-completions guard skips never-seen letters")
    func minimumPriorCompletionsGuard() {
        let s = newScheduler(interval: 1, minimumPrior: 1, counter: 0)
        let unseen = progress(completionCount: 0)
        let seen = progress(completionCount: 1)
        // Even with interval=1 (every selection), an unseen letter never
        // fires — testing on guessing isn't measurement.
        #expect(s.shouldPrompt(for: "A", progress: unseen) == false)
        #expect(s.shouldPrompt(for: "A", progress: unseen) == false)
        // Seen letter fires immediately because interval=1.
        #expect(s.shouldPrompt(for: "A", progress: seen) == true)
    }

    @Test("interval == 0 disables prompts entirely")
    func intervalZeroDisables() {
        let s = newScheduler(interval: 0, minimumPrior: 1, counter: 0)
        let p = progress(completionCount: 5)
        for _ in 0..<10 {
            #expect(s.shouldPrompt(for: "A", progress: p) == false)
        }
    }

    @Test("Reset zeros the counter")
    func resetZerosCounter() {
        let s = newScheduler(interval: 3, minimumPrior: 1, counter: 0)
        let p = progress(completionCount: 5)
        _ = s.shouldPrompt(for: "A", progress: p)
        _ = s.shouldPrompt(for: "A", progress: p)
        s.reset()
        // After reset, two more calls don't fire (we're back at 0).
        #expect(s.shouldPrompt(for: "A", progress: p) == false)
        #expect(s.shouldPrompt(for: "A", progress: p) == false)
        #expect(s.shouldPrompt(for: "A", progress: p) == true)
    }

    @Test("initialCounter argument seeds the cadence")
    func initialCounterSeedsCadence() {
        let s = newScheduler(interval: 3, minimumPrior: 1, counter: 2)
        let p = progress(completionCount: 5)
        // Already at 2; one more call should hit interval=3 and fire.
        #expect(s.shouldPrompt(for: "A", progress: p) == true)
        // Counter reset on fire; next two are non-firing.
        #expect(s.shouldPrompt(for: "A", progress: p) == false)
        #expect(s.shouldPrompt(for: "A", progress: p) == false)
        #expect(s.shouldPrompt(for: "A", progress: p) == true)
    }
}
