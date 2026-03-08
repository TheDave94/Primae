import AVFoundation
import Foundation

// MARK: - AudioControlling (unchanged interface)

protocol AudioControlling {
func loadAudioFile(named fileName: String, autoplay: Bool)
func setAdaptivePlayback(speed: Float, horizontalBias: Float)
func play()
func stop()
func restart()
func suspendForLifecycle()
func resumeAfterLifecycle()
func cancelPendingLifecycleWork()
}

// MARK: - SpeechSynthesizing

/// Abstracts AVSpeechSynthesizer for testability. Methods are main-actor because
/// AVSpeechSynthesizer must be driven from the main thread on iOS.
@MainActor
protocol SpeechSynthesizing: AnyObject {
/// Speaks the bare letter name (e.g. "A") in the configured locale.
func speakLetter(_ letter: String)
/// Speaks a full example phrase, e.g. "A wie Apfel", as an audio fallback.
func speakExampleWord(for letter: String)
/// Stops any in-progress utterance immediately.
func stopSpeaking()
}

// MARK: - AVSpeechEngine

@MainActor
final class AVSpeechEngine: SpeechSynthesizing {

private let synthesizer = AVSpeechSynthesizer()
private let voice = AVSpeechSynthesisVoice(language: "de-DE")

// MARK: German example-word dictionary

/// Internal so tests can call `examplePhrase(for:)` directly.
func examplePhrase(for letter: String) -> String {
Self.phrases[letter.uppercased()] ?? letter
}

private static let phrases: [String: String] = [
"A": "A wie Apfel",
"B": "B wie Ball",
"C": "C wie Computer",
"D": "D wie Delfin",
"E": "E wie Elefant",
"F": "F wie Fisch",
"G": "G wie Giraffe",
"H": "H wie Haus",
"I": "I wie Igel",
"J": "J wie Jaguar",
"K": "K wie Katze",
"L": "L wie Löwe",
"M": "M wie Maus",
"N": "N wie Nase",
"O": "O wie Orange",
"P": "P wie Pinguin",
"Q": "Q wie Qualle",
"R": "R wie Rakete",
"S": "S wie Sonne",
"T": "T wie Tiger",
"U": "U wie Uhu",
"V": "V wie Vogel",
"W": "W wie Wolf",
"X": "X wie Xylophon",
"Y": "Y wie Yak",
"Z": "Z wie Zebra",
]

// MARK: SpeechSynthesizing

func speakLetter(_ letter: String) {
stopSpeaking()
let u = utterance(for: letter, rate: AVSpeechUtteranceDefaultSpeechRate * 0.85)
u.pitchMultiplier = 1.10
u.postUtteranceDelay = 0.15
synthesizer.speak(u)
}

func speakExampleWord(for letter: String) {
// Don't stop — we want the letter name and example word to chain naturally
// if speakLetter was just called synchronously before this.
let phrase = examplePhrase(for: letter)
let u = utterance(for: phrase, rate: AVSpeechUtteranceDefaultSpeechRate * 0.78)
u.postUtteranceDelay = 0.10
synthesizer.speak(u)
}

func stopSpeaking() {
guard synthesizer.isSpeaking else { return }
synthesizer.stopSpeaking(at: .immediate)
}

// MARK: Private

private func utterance(for text: String, rate: Float) -> AVSpeechUtterance {
let u = AVSpeechUtterance(string: text)
u.voice = voice
u.rate = rate
u.volume = 1.0
return u
}
}

// MARK: - AudioEngine

final class AudioEngine: AudioControlling {
private let engine = AVAudioEngine()
private let player = AVAudioPlayerNode()
private let timePitch = AVAudioUnitTimePitch()
private var currentFile: AVAudioFile?
private var interruptionObserver: NSObjectProtocol?
private var routeChangeObserver: NSObjectProtocol?

private var shouldResumePlayback = false
private var appIsForeground = true
private var interrupted = false
private var interruptionShouldResume = true
private var interruptionResumeGateRequired = false
private var pendingLifecyclePauseTask: Task<Void, Error>?

private(set) var isPlaying = false

#if DEBUG
var debugInterrupted: Bool { interrupted }
var debugInterruptionShouldResume: Bool { interruptionShouldResume }
var debugIsEngineRunning: Bool { engine.isRunning }
var debugShouldResumePlayback: Bool { shouldResumePlayback }
var debugAppIsForeground: Bool { appIsForeground }
var debugInterruptionResumeGateRequired: Bool { interruptionResumeGateRequired }
#endif

init() {
engine.attach(player)
engine.attach(timePitch)
engine.connect(player, to: timePitch, format: nil)
engine.connect(timePitch, to: engine.mainMixerNode, format: nil)
installObservers()
startIfNeeded()
}

deinit {
if let o = interruptionObserver { NotificationCenter.default.removeObserver(o) }
if let o = routeChangeObserver { NotificationCenter.default.removeObserver(o) }
stopAndReset()
}

func loadAudioFile(named fileName: String, autoplay: Bool = false) {
guard let url = resourceURL(for: fileName) else {
print("Missing audio file: \(fileName)"); return
}
do {
currentFile = try AVAudioFile(forReading: url)
shouldResumePlayback = autoplay
prepareCurrentTrack()
if autoplay { attemptResumePlayback() }
} catch { print("Audio load error: \(error)") }
}

func setAdaptivePlayback(speed: Float, horizontalBias: Float) {
timePitch.rate = max(0.5, min(2.0, speed)) * 100.0
player.pan = max(-1.0, min(1.0, horizontalBias))
}

func play() {
shouldResumePlayback = true
interruptionResumeGateRequired = false
interruptionShouldResume = true
attemptResumePlayback()
}

func stop() {
shouldResumePlayback = false
cancelPendingLifecycleWork()
player.pause()
isPlaying = false
}

func restart() {
shouldResumePlayback = true
interruptionResumeGateRequired = false
interruptionShouldResume = true
prepareCurrentTrack()
attemptResumePlayback()
}

func suspendForLifecycle() {
appIsForeground = false
cancelPendingLifecycleWork()
player.pause()
isPlaying = false
pendingSafeEnginePause()
}

func resumeAfterLifecycle() {
appIsForeground = true
cancelPendingLifecycleWork()
startIfNeeded()
if shouldResumePlayback
&& !interruptionResumeGateRequired
&& !interrupted {
attemptResumePlayback()
}
}

func cancelPendingLifecycleWork() {
pendingLifecyclePauseTask?.cancel()
pendingLifecyclePauseTask = nil
}

// MARK: Private

private func resourceURL(for fileName: String) -> URL? {
Bundle.main.url(forResource: fileName, withExtension: nil)
}

private func startIfNeeded() {
guard !engine.isRunning else { return }
do { try engine.start() } catch { print("Engine start error: \(error)") }
}

private func stopAndReset() {
player.stop()
engine.stop()
isPlaying = false
}

private func prepareCurrentTrack() {
guard let file = currentFile else { return }
player.stop()
player.scheduleFile(file, at: nil, completionHandler: nil)
}

private func attemptResumePlayback() {
startIfNeeded()
guard engine.isRunning else { return }
player.play()
isPlaying = true
}

private func pendingSafeEnginePause() {
pendingLifecyclePauseTask = Task { [weak self] in
try await Task.sleep(for: .seconds(0.5))
guard let self, !Task.isCancelled else { return }
if !self.appIsForeground { self.engine.pause() }
}
}

private func installObservers() {
interruptionObserver = NotificationCenter.default.addObserver(
forName: AVAudioSession.interruptionNotification,
object: nil, queue: .main) { [weak self] n in
self?.handleInterruption(n)
}
routeChangeObserver = NotificationCenter.default.addObserver(
forName: AVAudioSession.routeChangeNotification,
object: nil, queue: .main) { [weak self] n in
self?.handleRouteChange(n)
}
}

private func handleInterruption(_ n: Notification) {
guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
switch type {
case .began:
interrupted = true
interruptionShouldResume = shouldResumePlayback
player.pause(); isPlaying = false
case .ended:
interrupted = false
let optRaw = n.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
let opt = optRaw.map { AVAudioSession.InterruptionOptions(rawValue: $0) }
interruptionResumeGateRequired = !(opt?.contains(.shouldResume) ?? false)
if interruptionShouldResume && !interruptionResumeGateRequired {
startIfNeeded(); attemptResumePlayback()
}
@unknown default: break
}
}

private func handleRouteChange(_ n: Notification) {
guard let raw = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
if reason == .oldDeviceUnavailable { player.pause(); isPlaying = false }
}
}
