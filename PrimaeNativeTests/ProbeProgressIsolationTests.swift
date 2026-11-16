// ProbeProgressIsolationTests.swift
// R-030: a cold probe's completion and recognition sample must not reach
// ProgressStore (learning progress). Injected doubles only, no globals.

import Testing
import Foundation
@testable import PrimaeNative

private final class RecordingProgressStore: ProgressStoring {
    var completions = 0
    var samples = 0
    func progress(for letter: String) -> LetterProgress { LetterProgress() }
    func recordCompletion(for letter: String, accuracy: Double,
                          phaseScores: [String: Double]?, speed: Double?,
                          recognitionResult: RecognitionResult?, formAccuracy: Double?) { completions += 1 }
    func recordPaperTransferScore(for letter: String, score: Double) {}
    func recordVariantUsed(for letter: String, variantID: String?) {}
    func recordFreeformCompletion(letter: String, result: RecognitionResult) {}
    func recordRecognitionSample(letter: String, result: RecognitionResult) { samples += 1 }
    func resetAll() {}
    var allProgress: [String: LetterProgress] { [:] }
    var totalCompletions: Int { 0 }
}

@Suite(.serialized) @MainActor struct ProbeProgressIsolationTests {

    private func makeAsset(_ name: String) -> LetterAsset {
        LetterAsset(id: name, name: name, baseLetter: name, letterCase: .upper, audioFiles: [],
                    strokes: LetterStrokes(letter: name, checkpointRadius: 0.1, strokes: []),
                    phonemeAudioFiles: ["\(name)_phoneme1.mp3"])
    }

    private func makeVM(store: RecordingProgressStore) -> TracingViewModel {
        var deps = TracingDependencies.stub
        deps.studyMode = true
        deps.thesisCondition = .threePhase
        deps.progressStore = store
        deps.letterRecognizer = StubLetterRecognizer.alwaysReturn(predicted: "A", confidence: 0.9)
        let vm = TracingViewModel(deps)
        vm.letters = TrainedLetterSubset.studyLetters.map(makeAsset)
        return vm
    }

    private func waitForRecognition(_ vm: TracingViewModel) async {
        for _ in 0..<200 where vm.isRecognizing || vm.lastRecognitionResult == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("R-030: a probe completion writes no learning progress")
    func probeCompletionSkipsProgress() {
        let store = RecordingProgressStore()
        let vm = makeVM(store: store)
        #expect(vm.startColdProbe(letter: "A", kind: .pretest) == nil)
        #expect(vm.currentProbe != nil)
        vm.phaseTransitions.commitCompletion(letter: "A", accuracy: 0.8, duration: 5)
        #expect(store.completions == 0, "a probe completion reached recordCompletion")
    }

    @Test("R-030 control: a non-probe completion still records")
    func nonProbeCompletionRecords() {
        let store = RecordingProgressStore()
        let vm = makeVM(store: store)
        vm.loadLetter(name: "A")
        #expect(vm.currentProbe == nil)
        vm.phaseTransitions.commitCompletion(letter: "A", accuracy: 0.8, duration: 5)
        #expect(store.completions == 1)
    }

    @Test("R-030: a probe's recognition sample is not recorded")
    func probeRecognitionSkipsProgress() async {
        let store = RecordingProgressStore()
        let vm = makeVM(store: store)
        #expect(vm.startColdProbe(letter: "A", kind: .pretest) == nil)
        vm.runRecognizerForFreeWrite(score: 0.8)
        await waitForRecognition(vm)
        #expect(vm.lastRecognitionResult != nil, "recognizer never returned")
        #expect(store.samples == 0, "a probe recognition reached recordRecognitionSample")
    }

    @Test("R-030 control: a non-probe recognition sample is recorded")
    func nonProbeRecognitionRecords() async {
        let store = RecordingProgressStore()
        let vm = makeVM(store: store)
        vm.loadLetter(name: "A")
        vm.runRecognizerForFreeWrite(score: 0.8)
        await waitForRecognition(vm)
        #expect(vm.lastRecognitionResult != nil, "recognizer never returned")
        #expect(store.samples == 1)
    }
}
