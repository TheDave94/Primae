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

    @Test func showToast_replacing_doesNotClobberFirstDuringReplacementSleep() async {
        // The equality-guard inside the presenter prevents the first toast's
        // delayed clear from nuking a later message scheduled during its sleep.
        let p = TransientMessagePresenter()
        p.show(toast: "First")
        try? await Task.sleep(for: .milliseconds(400))
        p.show(toast: "Second")
        try? await Task.sleep(for: .milliseconds(300))
        #expect(p.toastMessage == "Second",
                "Second toast must survive until its own timer elapses")
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
