import Foundation
import CoreGraphics
@testable import BuchstabenNative

// MARK: - Shared no-op stubs for unit tests

final class StubAudio: AudioControlling {
    func loadAudioFile(named: String, autoplay: Bool) {}
    func setAdaptivePlayback(speed: Float, horizontalBias: Float) {}
    func play() {}
    func stop() {}
    func restart() {}
    func suspendForLifecycle() {}
    func resumeAfterLifecycle() {}
    func cancelPendingLifecycleWork() {}
}

final class StubHaptics: HapticEngineProviding {
    func prepare() {}
    func fire(_ event: HapticEvent) {}
}

// MARK: - No-op resource provider (avoids FileManager bundle scan hang in CI)
final class StubResourceProvider: LetterResourceProviding {
    var bundle: Bundle = .main
    var searchBundles: [Bundle] { [bundle] }
    func allResourceURLs() -> [URL] { [] }
    func resourceURL(for relativePath: String) -> URL? { nil }
}

// MARK: - No-op progress store (avoids FileManager.applicationSupportDirectory hang in CI)
final class StubProgressStore: ProgressStoring {
    func progress(for letter: String) -> LetterProgress { LetterProgress() }
    func recordCompletion(for letter: String, accuracy: Double) {}
    func resetAll() {}
    var allProgress: [String: LetterProgress] { [:] }
    var currentStreakDays: Int { 0 }
    var totalCompletions: Int { 0 }
}

// MARK: - Shared VM factory
// Injects stubs for audio, haptics, repo, and progressStore to avoid hangs in headless CI.
@MainActor
func makeTestVM(
    cooldown: CFTimeInterval = 0,
    audio: AudioControlling? = nil,
    haptics: HapticEngineProviding? = nil
) -> TracingViewModel {
    TracingViewModel(
        singleTouchCooldownAfterNavigation: cooldown,
        audio: audio ?? StubAudio(),
        progressStore: StubProgressStore(),
        haptics: haptics ?? StubHaptics(),
        repo: LetterRepository(resources: StubResourceProvider())
    )
}
