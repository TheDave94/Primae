// LifecycleTestSupport.swift
// Shared doubles for the lifecycle & interruption suites (fix batch C,
// audit 2026-10-13: R-005, R-006, R-019, R-022, R-024, R-026, R-029,
// R-044, R-051, R-071). Named apart from the file-private spies other
// suites already declare, so nothing shadows anything.

import Foundation
import CoreGraphics
@testable import PrimaeNative

/// A synthesiser double that records what is spoken and stopped, and lets
/// the test play the synthesiser's part in the end-of-utterance report.
@MainActor
final class CueSpeechSpy: SpeechSynthesizing {
    private(set) var spoken: [String] = []
    private(set) var stopCount = 0
    private var endHandler: (@MainActor (String, Bool) -> Void)?
    func speak(_ text: String) { spoken.append(text) }
    func stop() { stopCount += 1 }
    func setUtteranceEndHandler(_ handler: (@MainActor (String, Bool) -> Void)?) { endHandler = handler }
    /// Report that an utterance with `text` ended (finished, or cancelled).
    func end(_ text: String, cancelled: Bool = false) { endHandler?(text, cancelled) }
    func count(_ text: String) -> Int { spoken.filter { $0 == text }.count }
}

/// A prompt player double: records keys in order, and how often it was stopped.
@MainActor
final class PromptSpy: PromptPlaying {
    private(set) var keys: [PromptPlayer.PromptKey] = []
    private(set) var stopCount = 0
    func play(_ key: PromptPlayer.PromptKey, fallbackText: String) { keys.append(key) }
    func stop() { stopCount += 1 }
    func playSuccessChime() {}
    func playTapChime() {}
    func playWrongTapChime() {}
    func playStrokeTick() {}
    func count(_ key: PromptPlayer.PromptKey) -> Int { keys.filter { $0 == key }.count }
}

/// A dashboard store that records every phase row and session duration.
final class PhaseRowStore: ParentDashboardStoring {
    struct Row { let letter: String; let phase: String; let completed: Bool; let duration: Double? }
    var snapshot: DashboardSnapshot { DashboardSnapshot() }
    private(set) var rows: [Row] = []
    private(set) var sessionDurations: [TimeInterval] = []
    func recordSession(letter: String, accuracy: Double,
                       durationSeconds: TimeInterval,
                       wallClockSeconds: TimeInterval?,
                       date: Date, condition: ThesisCondition,
                       inputDevice: String?) {
        sessionDurations.append(durationSeconds)
    }
    func recordPhaseSession(letter: String, phase: String, completed: Bool, score: Double, schedulerPriority: Double, condition: ThesisCondition, audioCondition: PilotAudioCondition, assessment: WritingAssessment?, recognition: RecognitionSample?, inputDevice: String?, rawTraceID: UUID?, trainedSubset: String?, phaseDurationSeconds: Double?, frechetDistance: Double?, checkpointCoverage: Double?, spatialDeviation: Double?, strokeCount: Int?, strokeOrder: String?, reversedStrokeCount: Int?, studyMode: Bool?, probe: String?, comparisonConfiguration: String?) {
        rows.append(Row(letter: letter, phase: phase, completed: completed, duration: phaseDurationSeconds))
    }
    func reset() { rows.removeAll(); sessionDurations.removeAll() }
    func rows(_ phase: LearningPhase) -> [Row] { rows.filter { $0.phase == phase.rawName } }
}

/// The pieces of a study session the batch-C suites drive.
@MainActor
struct LifecycleRig {
    let vm: TracingViewModel
    let audio: EngineModelAudio
    let speech: CueSpeechSpy
    let prompts: PromptSpy
    let store: PhaseRowStore
    let canvas = CGSize(width: 400, height: 400)

    /// A study VM in `arm`, three-phase, spoken feedback on. The trained
    /// subset excludes A (the stub fixture's letter), so loading A is an
    /// ordinary un-parked load. `fallback` / `cueEnd` are the observe
    /// cue timings (production: 3.0 / 1.0 s).
    init(arm: PilotAudioCondition = .phoneme,
         fallback: TimeInterval = 3600,
         cueEnd: TimeInterval = 0.05,
         configure: (inout TracingDependencies) -> Void = { _ in }) {
        let audio = EngineModelAudio()
        let speech = CueSpeechSpy()
        let prompts = PromptSpy()
        let store = PhaseRowStore()
        var deps = TracingDependencies.stub
        deps.studyMode = true
        deps.thesisCondition = .threePhase
        deps.audioCondition = arm
        deps.trainedSubset = TrainedLetterSubset.allSubsets.first { !$0.letters.contains("A") }!
        deps.spokenFeedbackInStudy = true
        deps.observeCueFallbackSeconds = fallback
        deps.observeCueEndToPresentationSeconds = cueEnd
        deps.audio = audio
        deps.speech = speech
        deps.makePromptPlayer = { _ in prompts }
        deps.dashboardStore = store
        configure(&deps)
        let vm = TracingViewModel(deps)
        vm.canvasSize = CGSize(width: 400, height: 400)
        audio.phaseAtCall = { [weak vm] in vm?.phaseController.currentPhase }
        self.vm = vm; self.audio = audio; self.speech = speech
        self.prompts = prompts; self.store = store
    }

    /// One stroke across the fixture letter, in bounds, pen still DOWN.
    func strokeDown(from start: CGPoint = CGPoint(x: 50, y: 200), t0: CFTimeInterval = 1000) {
        var t = t0
        var p = start
        vm.beginTouch(at: p, t: t)
        for _ in 0..<15 { t += 0.01; p.x += 10; vm.updateTouch(at: p, t: t, canvasSize: canvas) }
    }

    /// Poll the main actor until `condition` holds, for up to `seconds`
    /// worth of 10 ms polls. Bounded by POLLS, not by the wall clock:
    /// measured in the full 1197-test run, a starved main actor resumed
    /// these polls only after the wall-clock deadline had passed, so the
    /// loop gave up before the main-actor job it was waiting for (queued
    /// behind it) had run — two false failures, both green alone. Counting
    /// polls guarantees that many main-actor turns.
    func waitUntil(_ seconds: Double = 30, _ condition: () -> Bool) async {
        for _ in 0..<Int(seconds * 100) {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
