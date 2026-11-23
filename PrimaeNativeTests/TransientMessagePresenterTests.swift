import Foundation
import Testing
@testable import PrimaeNative

@MainActor
@Suite struct TransientMessagePresenterTests {

    @Test func initialState_bothNil() {
        let p = TransientMessagePresenter()
        #expect(p.toastMessage == nil)
        #expect(p.completionMessage == nil)
    }

    @Test func showToast_setsMessage() {
        let p = TransientMessagePresenter()
        p.show(toast: "Hallo")
        #expect(p.toastMessage == "Hallo")
    }

    @Test func showToast_autoClearsAfterDuration() async {
        // Inject an instant sleep so the auto-clear fires deterministically — no wall clock.
        let p = TransientMessagePresenter(sleep: { _ in })
        p.show(toast: "Kurz")
        await p.toastTask?.value
        #expect(p.toastMessage == nil,
                "Toast should auto-clear after its sleeper resumes; got \(p.toastMessage ?? "nil")")
    }

    // MEASURED 2026-11-17, full suite on the physical iPad: this test passed
    // after 644.9 s. Every hop needs a main-actor turn, and in the full suite
    // it queues behind the whole suite's main-actor work, so a 1-minute limit
    // fired and restarted the runner (CI, 2026-11-16: eight jobs). The limit
    // only catches a real deadlock.
    @Test(.timeLimit(.minutes(30)))
    func showToast_replacing_doesNotClobberFirstDuringReplacementSleep() async {
        // The guards inside the presenter keep the first toast's delayed clear
        // from nuking a later message scheduled during its sleep. The sleeps
        // are held by a gate (not a wall clock), released oldest-first, and
        // the gate ignores cancellation so the FIRST task really does resume
        // and reach the guards while "Second" is on screen.
        //
        // The sleeper is explicitly `@MainActor`, so a toast task's sleep
        // never hops to the cooperative pool and back (R-106: in the full
        // suite that hop was the suspect for a hang). The test waits for the
        // gate's own PARK event, resumed by the sleeper that parks: no
        // poll, no deadline, so a busy main actor delays it but cannot fail
        // it. A poll costs a main-actor turn per tick and a deadline measures
        // the scheduler, which is what failed here.
        let gate = PresenterSleepGate()
        let p = TransientMessagePresenter(sleep: { @MainActor _ in await gate.sleep() })
        p.show(toast: "First")
        let first = p.toastTask
        await gate.parked(atLeast: 1)
        p.show(toast: "Second")
        await gate.parked(atLeast: 2)

        gate.releaseOldest()          // First's timer elapses; Second's has not
        await first?.value
        #expect(p.toastMessage == "Second",
                "Second toast must survive until its own timer elapses")

        gate.releaseOldest()          // Second's own timer elapses
        await p.toastTask?.value
        #expect(p.toastMessage == nil, "Second toast clears when its own timer elapses")
    }

    @Test func showCompletion_setsMessage() {
        let p = TransientMessagePresenter()
        p.show(completion: "🎉 Geschafft")
        #expect(p.completionMessage == "🎉 Geschafft")
    }

    @Test func dismissCompletion_clearsImmediately() {
        let p = TransientMessagePresenter()
        p.show(completion: "🎉 Geschafft")
        p.dismissCompletion()
        #expect(p.completionMessage == nil)
    }

    @Test func clearCompletionState_clearsImmediately() {
        let p = TransientMessagePresenter()
        p.show(completion: "🎉")
        p.clearCompletionState()
        #expect(p.completionMessage == nil)
    }

    @Test func showCompletion_autoClearsAfterDuration() async {
        let p = TransientMessagePresenter(sleep: { _ in })
        p.show(completion: "🎉")
        await p.completionTask?.value
        #expect(p.completionMessage == nil)
    }
}

/// Sleeps that end only when the test releases them, oldest first. Unlike
/// `Task.sleep` it does not throw on cancellation, so a cancelled task
/// resumes only when released, which is what lets the test observe the
/// presenter's guards.
@MainActor
private final class PresenterSleepGate {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    /// Tests waiting for a number of sleepers to park, resumed by the park.
    private var parkWatchers: [(count: Int, done: CheckedContinuation<Void, Never>)] = []
    private var parkedTotal = 0
    func sleep() async {
        await withCheckedContinuation {
            waiting.append($0)
            parkedTotal += 1
            let due = parkWatchers.filter { $0.count <= parkedTotal }
            parkWatchers.removeAll { $0.count <= parkedTotal }
            due.forEach { $0.done.resume() }
        }
    }
    /// Returns once `n` sleepers have parked in total (released ones count).
    func parked(atLeast n: Int) async {
        guard parkedTotal < n else { return }
        await withCheckedContinuation { parkWatchers.append((n, $0)) }
    }
    func releaseOldest() {
        guard !waiting.isEmpty else { return }
        waiting.removeFirst().resume()
    }
}
