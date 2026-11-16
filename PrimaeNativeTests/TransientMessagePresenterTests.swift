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

    @Test(.timeLimit(.minutes(1)))
    func showToast_replacing_doesNotClobberFirstDuringReplacementSleep() async {
        // The guards inside the presenter keep the first toast's delayed clear
        // from nuking a later message scheduled during its sleep. The sleeps
        // are held by a gate (not a wall clock), released oldest-first, and
        // the gate ignores cancellation so the FIRST task really does resume
        // and reach the guards while "Second" is on screen.
        let gate = PresenterSleepGate()
        let p = TransientMessagePresenter(sleep: { _ in await gate.sleep() })
        p.show(toast: "First")
        let first = p.toastTask
        while gate.parked < 1 { await Task.yield() }
        p.show(toast: "Second")
        while gate.parked < 2 { await Task.yield() }

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
    var parked: Int { waiting.count }
    func sleep() async {
        await withCheckedContinuation { waiting.append($0) }
    }
    func releaseOldest() {
        guard !waiting.isEmpty else { return }
        waiting.removeFirst().resume()
    }
}
