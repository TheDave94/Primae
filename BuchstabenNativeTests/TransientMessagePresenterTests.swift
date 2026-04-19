// TransientMessagePresenterTests.swift
// BuchstabenNativeTests

import Foundation
import Testing
@testable import BuchstabenNative

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
        let p = TransientMessagePresenter()
        p.show(toast: "Kurz")
        // toastDuration is 1.3 s — allow generous margin for CI slowdown.
        try? await Task.sleep(for: .milliseconds(1600))
        #expect(p.toastMessage == nil,
                "Toast should auto-clear after ~1.3 s; got \(p.toastMessage ?? "nil")")
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
        let p = TransientMessagePresenter()
        p.show(completion: "🎉")
        try? await Task.sleep(for: .milliseconds(2100))  // completionDuration=1.8s
        #expect(p.completionMessage == nil)
    }
}
