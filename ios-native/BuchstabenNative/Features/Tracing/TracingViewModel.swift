import Combine
import CoreGraphics
import QuartzCore
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

    private let repo: LetterRepository
    private let strokeTracker = StrokeTracker()
    private let audio: TracingAudioControlling
    private let now: () -> CFTimeInterval
    private let randomIndex: (Range<Int>) -> Int

    private var letters: [LetterAsset] = []
    private var letterIndex = 0
    private var audioIndex = 0
    private var lastPoint: CGPoint?
    private var lastTimestamp: CFTimeInterval?
    private var isMultiTouchNavigationActive = false
    private var singleTouchSuppressedUntil: CFTimeInterval = 0
    private var isSingleTouchInteractionActive = false
    private var didCompleteCurrentLetter = false
    private var isLifecycleSuspended = false

    private enum AdaptivePlaybackState { case idle, active }
    private var adaptivePlaybackState: AdaptivePlaybackState = .idle
    private var pendingPlaybackStateWorkItem: DispatchWorkItem?
    private var toastTask: Task<Void, Never>?
    private var completionDismissTask: Task<Void, Never>?
    private var smoothedVelocity: CGFloat = 0
    private let velocitySmoothingAlpha: CGFloat = 0.22
    private let activeDebounceSeconds: TimeInterval
    private let idleDebounceSeconds: TimeInterval
    private let playbackActivationVelocityThreshold: CGFloat = 22
    private let singleTouchCooldownAfterNavigation: CFTimeInterval

    init(
        repo: LetterRepository = LetterRepository(),
        audio: TracingAudioControlling = AudioEngine(),
        now: @escaping () -> CFTimeInterval = CACurrentMediaTime,
        randomIndex: @escaping (Range<Int>) -> Int = { Int.random(in: $0) },
        activeDebounceSeconds: TimeInterval = 0.03,
        idleDebounceSeconds: TimeInterval = 0.12,
        singleTouchCooldownAfterNavigation: CFTimeInterval = 0.18
    ) {
        self.repo = repo
        self.audio = audio
        self.now = now
        self.randomIndex = randomIndex
        self.activeDebounceSeconds = activeDebounceSeconds
        self.idleDebounceSeconds = idleDebounceSeconds
        self.singleTouchCooldownAfterNavigation = singleTouchCooldownAfterNavigation

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
        completionDismissTask?.cancel()
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
        letterIndex = randomNonRepeatingIndex(current: letterIndex, upperBound: letters.count)
        load(letter: letters[letterIndex])
        randomAudioVariant()
        toast("Random: \(currentLetterName)")
    }

    func nextAudioVariant() {
        guard !letters.isEmpty else { return }
        let files = letters[letterIndex].audioFiles
        guard !files.isEmpty else { return }
        audioIndex = (audioIndex + 1) % files.count
        audio.loadAudioFile(named: files[audioIndex], autoplay: false)
        setPlaybackState(.idle, immediate: true)
        toast("Sound \(audioIndex + 1)/\(files.count)")
    }

    func previousAudioVariant() {
        guard !letters.isEmpty else { return }
        let files = letters[letterIndex].audioFiles
        guard !files.isEmpty else { return }
        audioIndex = (audioIndex - 1 + files.count) % files.count
        audio.loadAudioFile(named: files[audioIndex], autoplay: false)
        setPlaybackState(.idle, immediate: true)
        toast("Sound \(audioIndex + 1)/\(files.count)")
    }

    func beginMultiTouchNavigation() {
        guard !isMultiTouchNavigationActive else { return }
        isMultiTouchNavigationActive = true
        endTouch()
    }

    func endMultiTouchNavigation() {
        guard isMultiTouchNavigationActive else { return }
        isMultiTouchNavigationActive = false
        singleTouchSuppressedUntil = now() + singleTouchCooldownAfterNavigation
    }

    func beginTouch(at p: CGPoint, t: CFTimeInterval) {
        guard !isMultiTouchNavigationActive else { return }
        guard t >= singleTouchSuppressedUntil else { return }
        guard !isSingleTouchInteractionActive else { return }

        isSingleTouchInteractionActive = true
        lastPoint = p
        lastTimestamp = t
        activePath = [p]
    }

    func updateTouch(at p: CGPoint, t: CFTimeInterval, canvasSize: CGSize) {
        guard !isMultiTouchNavigationActive else { return }
        guard isSingleTouchInteractionActive else { return }
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
        guard !isLifecycleSuspended else { return }
        isLifecycleSuspended = true
        endTouch()
        setPlaybackState(.idle, immediate: true)
        audio.suspendForLifecycle()
    }

    func appDidBecomeActive() {
        guard isLifecycleSuspended else { return }
        isLifecycleSuspended = false
        audio.resumeAfterLifecycle()
    }

    func endTouch() {
        isSingleTouchInteractionActive = false
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
        completionDismissTask?.cancel()
        completionMessage = nil
        activePath.removeAll(keepingCapacity: true)
        isSingleTouchInteractionActive = false
        smoothedVelocity = 0
        if let firstAudio = letter.audioFiles.first {
            audio.loadAudioFile(named: firstAudio, autoplay: false)
            setPlaybackState(.idle, immediate: true)
        }
    }

    private func randomAudioVariant() {
        let files = letters[letterIndex].audioFiles
        guard !files.isEmpty else { return }
        audioIndex = randomNonRepeatingIndex(current: audioIndex, upperBound: files.count)
        audio.loadAudioFile(named: files[audioIndex], autoplay: false)
        setPlaybackState(.idle, immediate: true)
    }

    private func randomNonRepeatingIndex(current: Int, upperBound: Int) -> Int {
        guard upperBound > 1 else { return 0 }
        var candidate = randomIndex(0..<upperBound)
        if candidate == current {
            candidate = (candidate + 1) % upperBound
        }
        return candidate
    }


    #if DEBUG
    var debugIsMultiTouchNavigationActive: Bool { isMultiTouchNavigationActive }
    var debugActivePathCount: Int { activePath.count }
    #endif

    func dismissCompletionHUD() {
        completionDismissTask?.cancel()
        completionMessage = nil
    }

    private func showCompletionHUD() {
        completionDismissTask?.cancel()
        let letter = currentLetterName
        completionMessage = "🎉 \(letter) geschafft!"
        completionDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.8))
            guard let self else { return }
            if self.completionMessage == "🎉 \(letter) geschafft!" {
                self.completionMessage = nil
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
        if delay <= 0 {
            applyPlaybackState(target)
            return
        }

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
        toastTask?.cancel()
        toastMessage = text
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.3))
            guard let self else { return }
            if self.toastMessage == text { self.toastMessage = nil }
        }
    }
}
