import Combine
import CoreGraphics
import Foundation

@MainActor
final class TracingViewModel: ObservableObject {
    @Published var showGhost = false
    @Published var strokeEnforced = true
    @Published var showDebug = false
    @Published var toastMessage: String?
    @Published var currentLetterName = "A"
    @Published var progress: CGFloat = 0
    @Published var isPlaying = false
    @Published var activePath: [CGPoint] = []
    @Published var completionMessage: String?

    private let repo = LetterRepository()
    private let strokeTracker = StrokeTracker()
    private let audio = AudioEngine()

    private var letters: [LetterAsset] = []
    private var letterIndex = 0
    private var audioIndex = 0
    private var lastPoint: CGPoint?
    private var lastTimestamp: CFTimeInterval?
    private var isMultiTouchNavigationActive = false
    private var didCompleteCurrentLetter = false

    private enum AdaptivePlaybackState { case idle, active }
    private var adaptivePlaybackState: AdaptivePlaybackState = .idle
    private var pendingPlaybackStateWorkItem: DispatchWorkItem?
    private var smoothedVelocity: CGFloat = 0
    private let velocitySmoothingAlpha: CGFloat = 0.22
    private let activeDebounceSeconds: TimeInterval = 0.03
    private let idleDebounceSeconds: TimeInterval = 0.12
    private let playbackActivationVelocityThreshold: CGFloat = 22

    init() {
        letters = repo.loadLetters()
        guard let first = letters.first else { return }
        load(letter: first)
        toast("Ready")
    }

    func toggleGhost() { showGhost.toggle(); toast(showGhost ? "Ghost ON" : "Ghost OFF") }
    func toggleStrokeEnforcement() { strokeEnforced.toggle(); resetLetter(); toast(strokeEnforced ? "Order ON" : "Order OFF") }
    func toggleDebug() { showDebug.toggle(); toast(showDebug ? "Debug ON" : "Debug OFF") }

    func resetLetter() {
        strokeTracker.reset()
        progress = 0
        activePath.removeAll(keepingCapacity: true)
        smoothedVelocity = 0
        setPlaybackState(.idle, immediate: true)
        didCompleteCurrentLetter = false
        completionMessage = nil
        toast("Reset")
    }

    func nextLetter() {
        guard !letters.isEmpty else { return }
        letterIndex = (letterIndex + 1) % letters.count
        load(letter: letters[letterIndex])
        toast("Letter: \(currentLetterName)")
    }

    func previousLetter() {
        guard !letters.isEmpty else { return }
        letterIndex = (letterIndex - 1 + letters.count) % letters.count
        load(letter: letters[letterIndex])
        toast("Letter: \(currentLetterName)")
    }

    func randomLetter() {
        guard !letters.isEmpty else { return }
        letterIndex = Int.random(in: 0..<letters.count)
        load(letter: letters[letterIndex])
        randomAudioVariant()
        toast("Random: \(currentLetterName)")
    }

    func nextAudioVariant() {
        guard !letters.isEmpty else { return }
        let files = letters[letterIndex].audioFiles
        guard !files.isEmpty else { return }
        audioIndex = (audioIndex + 1) % files.count
        audio.loadAudioFile(named: files[audioIndex])
        setPlaybackState(.idle, immediate: true)
        toast("Sound \(audioIndex + 1)/\(files.count)")
    }

    func previousAudioVariant() {
        guard !letters.isEmpty else { return }
        let files = letters[letterIndex].audioFiles
        guard !files.isEmpty else { return }
        audioIndex = (audioIndex - 1 + files.count) % files.count
        audio.loadAudioFile(named: files[audioIndex])
        setPlaybackState(.idle, immediate: true)
        toast("Sound \(audioIndex + 1)/\(files.count)")
    }

    func beginMultiTouchNavigation() {
        isMultiTouchNavigationActive = true
        endTouch()
    }

    func endMultiTouchNavigation() {
        isMultiTouchNavigationActive = false
    }

    func beginTouch(at p: CGPoint, t: CFTimeInterval) {
        guard !isMultiTouchNavigationActive else { return }
        lastPoint = p
        lastTimestamp = t
        activePath = [p]
    }

    func updateTouch(at p: CGPoint, t: CFTimeInterval, canvasSize: CGSize) {
        guard !isMultiTouchNavigationActive else { return }
        activePath.append(p)

        guard let lastPoint, let lastTimestamp else { return }
        let dt = max(0.001, t - lastTimestamp)
        let dx = p.x - lastPoint.x
        let dy = p.y - lastPoint.y
        let velocity = hypot(dx, dy) / dt

        if smoothedVelocity == 0 {
            smoothedVelocity = velocity
        } else {
            smoothedVelocity = smoothedVelocity + (velocitySmoothingAlpha * (velocity - smoothedVelocity))
        }

        let normalized = CGPoint(x: p.x / max(canvasSize.width, 1), y: p.y / max(canvasSize.height, 1))
        strokeTracker.update(normalizedPoint: normalized)
        progress = strokeTracker.overallProgress

        let speed = Self.mapVelocityToSpeed(smoothedVelocity)
        let hBias = Float(max(-1.0, min(1.0, dx / 20.0)))
        audio.setAdaptivePlayback(speed: speed, horizontalBias: hBias)

        let shouldPlayForStroke = strokeEnforced ? strokeTracker.soundEnabled : true
        let shouldBeActive = shouldPlayForStroke && smoothedVelocity >= playbackActivationVelocityThreshold
        setPlaybackState(shouldBeActive ? .active : .idle, immediate: false)

        if strokeTracker.isComplete, !didCompleteCurrentLetter {
            didCompleteCurrentLetter = true
            showCompletionHUD()
            toast("Great! Completed")
            setPlaybackState(.idle, immediate: true)
        }

        self.lastPoint = p
        self.lastTimestamp = t
    }


    func appDidEnterBackground() {
        endTouch()
        setPlaybackState(.idle, immediate: true)
        audio.suspendForLifecycle()
    }

    func appDidBecomeActive() {
        audio.resumeAfterLifecycle()
    }

    func endTouch() {
        lastPoint = nil
        lastTimestamp = nil
        activePath.removeAll(keepingCapacity: true)
        smoothedVelocity = 0
        setPlaybackState(.idle, immediate: true)
    }

    private func load(letter: LetterAsset) {
        currentLetterName = letter.name
        strokeTracker.load(letter.strokes)
        progress = 0
        audioIndex = 0
        didCompleteCurrentLetter = false
        completionMessage = nil
        activePath.removeAll(keepingCapacity: true)
        smoothedVelocity = 0
        if let firstAudio = letter.audioFiles.first {
            audio.loadAudioFile(named: firstAudio)
            setPlaybackState(.idle, immediate: true)
        }
    }

    private func randomAudioVariant() {
        let files = letters[letterIndex].audioFiles
        guard !files.isEmpty else { return }
        audioIndex = Int.random(in: 0..<files.count)
        audio.loadAudioFile(named: files[audioIndex])
        setPlaybackState(.idle, immediate: true)
    }


    func dismissCompletionHUD() {
        completionMessage = nil
    }

    private func showCompletionHUD() {
        let letter = currentLetterName
        completionMessage = "🎉 \(letter) geschafft!"
        Task {
            try? await Task.sleep(for: .seconds(1.8))
            if completionMessage == "🎉 \(letter) geschafft!" {
                completionMessage = nil
            }
        }
    }

    static func mapVelocityToSpeed(_ v: CGFloat) -> Float {
        let low: CGFloat = 120
        let high: CGFloat = 1300
        if v <= low { return 2.0 }
        if v >= high { return 0.5 }
        let t = (v - low) / (high - low)
        return Float(2.0 - (1.5 * t))
    }

    private func setPlaybackState(_ target: AdaptivePlaybackState, immediate: Bool) {
        pendingPlaybackStateWorkItem?.cancel()
        pendingPlaybackStateWorkItem = nil

        if immediate {
            applyPlaybackState(target)
            return
        }

        guard target != adaptivePlaybackState else { return }

        let delay = target == .active ? activeDebounceSeconds : idleDebounceSeconds
        let work = DispatchWorkItem { [weak self] in
            self?.applyPlaybackState(target)
        }
        pendingPlaybackStateWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func applyPlaybackState(_ target: AdaptivePlaybackState) {
        guard adaptivePlaybackState != target else { return }
        adaptivePlaybackState = target
        switch target {
        case .active:
            audio.play()
            isPlaying = true
        case .idle:
            audio.stop()
            isPlaying = false
        }
    }

    private func toast(_ text: String) {
        toastMessage = text
        Task {
            try? await Task.sleep(for: .seconds(1.3))
            if toastMessage == text { toastMessage = nil }
        }
    }
}
