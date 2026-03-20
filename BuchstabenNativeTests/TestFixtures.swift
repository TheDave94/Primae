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

// MARK: - Null letter cache (throws on load — forces fresh parse, prevents cross-test pollution)
struct NullLetterCache: LetterCacheStoring {
    func save(_ letters: [LetterAsset]) throws {}
    func load() throws -> [LetterAsset] { throw LetterRepositoryError.cacheReadFailed(path: "") }
    func clear() {}
}

// MARK: - Shared VM factory
// Injects stubs for audio, haptics, repo, and progressStore to avoid hangs in headless CI.
@MainActor
func makeTestVM(
    cooldown: CFTimeInterval = 0,
    audio: AudioControlling? = nil,
    haptics: HapticEngineProviding? = nil
) -> TracingViewModel {
    var deps = TracingDependencies.stub
    if cooldown != 0 { deps = deps.with(cooldown: cooldown) }
    if let audio { deps = deps.with(audio: audio) }
    if let haptics { deps = deps.with(haptics: haptics) }
    return TracingViewModel(deps)
}

// MARK: - TracingDependencies test builder
// Usage: TracingViewModel(.stub)
//        TracingViewModel(.stub.with(audio: myAudio))
//        TracingViewModel(.stub.with(cooldown: 0.05).with(haptics: myHaptics))
extension TracingDependencies {
    /// A fully-stubbed configuration safe for headless CI — no FileManager, no AVAudioEngine.
    @MainActor
    static var stub: TracingDependencies {
        TracingDependencies(
            singleTouchCooldownAfterNavigation: 0,
            activeDebounceSeconds: 0,
            idleDebounceSeconds: 0,
            audio: StubAudio(),
            progressStore: StubProgressStore(),
            haptics: StubHaptics(),
            repo: LetterRepository(resources: StubResourceProvider())
        )
    }

    func with(activeDebounce: TimeInterval) -> TracingDependencies {
        var copy = self; copy.activeDebounceSeconds = activeDebounce; return copy
    }
    func with(idleDebounce: TimeInterval) -> TracingDependencies {
        var copy = self; copy.idleDebounceSeconds = idleDebounce; return copy
    }
    func with(cooldown: CFTimeInterval) -> TracingDependencies {
        var copy = self; copy.singleTouchCooldownAfterNavigation = cooldown; return copy
    }
    func with(audio: AudioControlling) -> TracingDependencies {
        var copy = self; copy.audio = audio; return copy
    }
    func with(progressStore: ProgressStoring) -> TracingDependencies {
        var copy = self; copy.progressStore = progressStore; return copy
    }
    func with(haptics: HapticEngineProviding) -> TracingDependencies {
        var copy = self; copy.haptics = haptics; return copy
    }
    func with(repo: LetterRepository) -> TracingDependencies {
        var copy = self; copy.repo = repo; return copy
    }
}
