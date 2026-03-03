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
        audio.stop()
        isPlaying = false
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
        audio.stop()
        isPlaying = false
        toast("Sound \(audioIndex + 1)/\(files.count)")
    }

    func previousAudioVariant() {
        guard !letters.isEmpty else { return }
        let files = letters[letterIndex].audioFiles
        guard !files.isEmpty else { return }
        audioIndex = (audioIndex - 1 + files.count) % files.count
        audio.loadAudioFile(named: files[audioIndex])
        audio.stop()
        isPlaying = false
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

        let normalized = CGPoint(x: p.x / max(canvasSize.width, 1), y: p.y / max(canvasSize.height, 1))
        strokeTracker.update(normalizedPoint: normalized)
        progress = strokeTracker.overallProgress

        let speed = mapVelocityToSpeed(velocity)
        let hBias = Float(max(-1.0, min(1.0, dx / 20.0)))
        audio.setAdaptivePlayback(speed: speed, horizontalBias: hBias)

        let shouldPlay = strokeEnforced ? strokeTracker.soundEnabled : true
        if shouldPlay {
            audio.play()
            isPlaying = true
        } else {
            audio.stop()
            isPlaying = false
        }

        if strokeTracker.isComplete, !didCompleteCurrentLetter {
            didCompleteCurrentLetter = true
            showCompletionHUD()
            toast("Great! Completed")
            audio.stop()
            isPlaying = false
        }

        self.lastPoint = p
        self.lastTimestamp = t
    }

    func endTouch() {
        lastPoint = nil
        lastTimestamp = nil
        activePath.removeAll(keepingCapacity: true)
        audio.stop()
        isPlaying = false
    }

    private func load(letter: LetterAsset) {
        currentLetterName = letter.name
        strokeTracker.load(letter.strokes)
        progress = 0
        audioIndex = 0
        didCompleteCurrentLetter = false
        completionMessage = nil
        activePath.removeAll(keepingCapacity: true)
        if let firstAudio = letter.audioFiles.first {
            audio.loadAudioFile(named: firstAudio)
            audio.stop()
            isPlaying = false
        }
    }

    private func randomAudioVariant() {
        let files = letters[letterIndex].audioFiles
        guard !files.isEmpty else { return }
        audioIndex = Int.random(in: 0..<files.count)
        audio.loadAudioFile(named: files[audioIndex])
        audio.stop()
        isPlaying = false
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

    private func mapVelocityToSpeed(_ v: CGFloat) -> Float {
        let low: CGFloat = 120
        let high: CGFloat = 1300
        if v <= low { return 2.0 }
        if v >= high { return 0.5 }
        let t = (v - low) / (high - low)
        return Float(2.0 - (1.5 * t))
    }

    private func toast(_ text: String) {
        toastMessage = text
        Task {
            try? await Task.sleep(for: .seconds(1.3))
            if toastMessage == text { toastMessage = nil }
        }
    }
}
