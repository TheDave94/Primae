// RecognizerWarmUpTests.swift
// R-034 (audit 2026-10-13, F1-07 / F1-09): the recognizer model was loaded
// on the first child's first free-writing lift — a cold CoreML load that
// took 32–60 s on CI simulators — and a failed load was latched for the
// life of the process with nothing shown. Now: a study session warms the
// model at launch and at every enrolment, retries ONCE after a failure,
// shows its status to the proctor, and every row records whether the
// model was available.
//
// UNVERIFIED on hardware: the cold-load time on the study iPad (M8).

import Testing
import Foundation
@testable import PrimaeNative

@Suite @MainActor struct RecognizerWarmUpTests {

    @Test("R-034: the load policy attempts once, retries once after a failure, then stops")
    func loadPolicyRetriesOnce() {
        #expect(RecognizerLoadPolicy.shouldAttemptLoad(attempts: 0, modelLoaded: false))
        #expect(RecognizerLoadPolicy.shouldAttemptLoad(attempts: 1, modelLoaded: false), "a failed first load is retried")
        #expect(!RecognizerLoadPolicy.shouldAttemptLoad(attempts: 2, modelLoaded: false), "and only once")
        #expect(!RecognizerLoadPolicy.shouldAttemptLoad(attempts: 1, modelLoaded: true), "a loaded model is never reloaded")
    }

    private func vm(_ recognizer: LetterRecognizerProtocol, study: Bool = false) -> TracingViewModel {
        var deps = TracingDependencies.stub
        deps.studyMode = study
        deps.letterRecognizer = recognizer
        return TracingViewModel(deps)
    }

    @Test("R-034: a failed warm-up is retried exactly once")
    func warmUpRetriesOnce() async {
        let flaky = ScriptedAvailabilityRecognizer(answers: [false, true])
        let a = vm(flaky)
        await a.warmUpRecognizer()
        #expect(a.recognizerAvailable == true)
        #expect(flaky.probeCount == 2)

        let broken = ScriptedAvailabilityRecognizer(answers: [false, false, true])
        let b = vm(broken)
        await b.warmUpRecognizer()
        #expect(b.recognizerAvailable == false, "a model that failed twice is reported unavailable")
        #expect(broken.probeCount == 2, "retried more than once: \(broken.probeCount)")

        let fine = ScriptedAvailabilityRecognizer(answers: [true])
        let c = vm(fine)
        await c.warmUpRecognizer()
        #expect(c.recognizerAvailable == true && fine.probeCount == 1)
    }

    @Test("R-034: a study session warms the recognizer at launch, before any child writes")
    func studySessionWarmsAtLaunch() async {
        let recognizer = ScriptedAvailabilityRecognizer(answers: [true])
        let study = vm(recognizer, study: true)
        for _ in 0..<500 where study.recognizerAvailable == nil { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(study.recognizerAvailable == true, "no warm-up ran at launch")
        #expect(study.phaseRowContext(for: .observe, finalizedBy: .child).delivery?.recognizerAvailable == true,
                "the row does not record the recognizer's availability")
    }

    // Found by the batch D full-suite run: every study-mode view model a
    // test builds spawns a warm-up, and a warm-up that held the view model
    // across its awaits kept it alive for as long as the model took to load
    // (a cold CoreML load: tens of seconds).
    @Test("R-034: a warm-up in flight does not keep the view model alive")
    func pendingWarmUpDoesNotRetainTheViewModel() async {
        let slow = SlowAvailabilityRecognizer(delay: .seconds(5))
        weak var released: TracingViewModel?
        do {
            let study = vm(slow, study: true)
            released = study
            for _ in 0..<300 where slow.probeCount == 0 { try? await Task.sleep(for: .milliseconds(10)) }
            #expect(slow.probeCount == 1, "the warm-up never started")
        }
        #expect(released == nil, "the warm-up keeps the view model alive until the model has loaded")
    }
}
