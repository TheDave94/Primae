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

// MARK: - Shared VM factory
// Always injects stubs to avoid AVAudioEngine and CHHapticEngine in headless CI.
@MainActor
func makeTestVM(
    cooldown: CFTimeInterval = 0,
    audio: AudioControlling? = nil,
    haptics: HapticEngineProviding? = nil
) -> TracingViewModel {
    TracingViewModel(
        singleTouchCooldownAfterNavigation: cooldown,
        audio: audio ?? StubAudio(),
        haptics: haptics ?? StubHaptics()
    )
}
