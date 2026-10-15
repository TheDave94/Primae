// SpeechSynthesizer.swift
// PrimaeNative
//
// German voice playback for child-facing verbal feedback. Built on
// AVSpeechSynthesizer for on-device German voices (Anna/Petra/Markus
// when installed) — no network calls, no API keys.
//
// PromptPlayer is the canonical path for the static recorded phrases;
// this synthesizer owns the dynamic templated phrases (recognition
// outcomes, retrieval correction) and acts as the fallback for
// PromptPlayer when an MP3 is missing.

import AVFoundation
import Foundation
import Synchronization

// MARK: - Protocol seam

/// Async-free TTS API for child-facing verbal feedback. Tests use
/// `NullSpeechSynthesizer` which records spoken lines.
@MainActor
protocol SpeechSynthesizing {
    /// Speak `text` in German. Utterances queue natively — call
    /// `stop()` first to interrupt.
    func speak(_ text: String)
    /// Halt any in-flight or queued utterance.
    func stop()
    /// Parent-tunable rate; `nil` restores the default.
    func setRate(_ rate: Float?)
    /// The voice this synthesiser speaks with, resolved once at init;
    /// `nil` when it speaks with none (null/spy implementations, or a
    /// device with no German voice). Read-only, for the research
    /// dashboard — see `SpeechVoiceInfo`.
    var resolvedVoice: SpeechVoiceInfo? { get }
    /// Why this synthesiser has no usable German voice — the pinned voice
    /// is missing, or no German voice is installed (R-021, batch D) — or
    /// nil when it speaks with its pinned voice. A study session refuses to
    /// start while this is set (`studyPreconditionFailure`).
    var voiceFault: String? { get }
    /// Proctor recovery from a voice fault (R-021 follow-up): forget the
    /// stored pin and choose again by the first-pin rule (first enhanced
    /// German voice, else first German voice) from the voices installed
    /// NOW, then re-evaluate `resolvedVoice` / `voiceFault`. Stubs and
    /// spies have nothing to re-pin.
    func repinVoice()
    /// Called (main actor) when an utterance ENDS — finished, or cancelled
    /// by `stop()` — with the utterance's text. One handler at a time;
    /// `nil` removes it. Used by the study observe phase to start its
    /// presentation after the spoken cue has actually ended (2026-10-05).
    func setUtteranceEndHandler(_ handler: (@MainActor (_ text: String, _ cancelled: Bool) -> Void)?)
    /// A RECORDED phrase (`PromptPlayer`) ended — finished or cut — and
    /// reports it through the same handler an utterance would (r9), so the
    /// observe cue ends the same way whether it is spoken or played. Stubs
    /// and spies that never report ignore it.
    func reportRecordedUtteranceEnd(text: String, cancelled: Bool)
}

extension SpeechSynthesizing {
    func setRate(_ rate: Float?) {}
    var resolvedVoice: SpeechVoiceInfo? { nil }
    var voiceFault: String? { nil }
    func repinVoice() {}
    /// Null default: stubs and spies never report an end, so a caller
    /// waiting for one must have a fallback.
    func setUtteranceEndHandler(_ handler: (@MainActor (_ text: String, _ cancelled: Bool) -> Void)?) {}
    func reportRecordedUtteranceEnd(text: String, cancelled: Bool) {}
}

// MARK: - Rate

/// The TTS rate a session speaks at, and the one place that decides it.
///
/// STUDY BUILD: always `standard` (0.42). The rate is part of every
/// spoken prompt the child hears, identical in all three arms (P3), so it
/// is a property of the instrument, not a parent preference — and a value
/// left stored on the device from earlier testing (the old "Langsam"
/// 0.36) must not reach a study session. The "Sprache" picker that wrote
/// it is compiled out of `SettingsView` in study builds; this ignores
/// whatever it stored before. Ruled by the supervisor 2026-10-05.
///
/// Casual build: the stored picker value, or `standard` when none.
enum SpeechRate {
    static let standard: Float = 0.42
    static let defaultsKey = "de.flamingistan.primae.speechRate"

    /// `defaults` is a seam so a test can store a value without touching
    /// `UserDefaults.standard` (suites run in parallel).
    static func effective(storedIn defaults: UserDefaults = .standard) -> Float {
        #if STUDY_BUILD
        return standard
        #else
        let stored = defaults.float(forKey: defaultsKey)
        return stored > 0 ? stored : standard
        #endif
    }
}

// MARK: - Resolved voice

/// The German voice a synthesiser resolved, as the proctor reads it off
/// the research dashboard and records it at session start. Which voice
/// `AVSpeechSpeechSynthesizer.init` picks depends on what is installed on
/// the device, so it is a property of the one study iPad: displayed, not
/// pinned (a hard identifier pin fails or falls back on a device without
/// that voice) and not exported.
struct SpeechVoiceInfo: Equatable {
    let identifier: String
    let name: String
    let quality: String

    init(identifier: String, name: String, quality: String) {
        self.identifier = identifier
        self.name = name
        self.quality = quality
    }

    init(_ voice: AVSpeechSynthesisVoice) {
        self.init(identifier: voice.identifier,
                  name: voice.name,
                  quality: Self.qualityName(voice.quality))
    }

    static func qualityName(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .default:  return "Standard"
        case .enhanced: return "Erweitert"
        case .premium:  return "Premium"
        @unknown default: return "unbekannt (\(quality.rawValue))"
        }
    }

    /// The exact text the research dashboard shows for `voice`.
    static func dashboardText(_ voice: SpeechVoiceInfo?) -> String {
        guard let voice else { return "Keine deutsche Stimme aufgelöst" }
        return "\(voice.name) · \(voice.quality) · \(voice.identifier)"
    }
}

// MARK: - Voice choice and pin (R-021, batch D)

/// One installed voice, as the chooser sees it — a value, so the choice is
/// testable without the device's voice list.
struct VoiceCandidate: Equatable {
    let identifier: String
    let name: String
    let language: String
    /// `AVSpeechSynthesisVoiceQuality.rawValue` (1 default, 2 enhanced,
    /// 3 premium).
    let quality: Int

    init(identifier: String, name: String, language: String, quality: Int) {
        self.identifier = identifier
        self.name = name
        self.language = language
        self.quality = quality
    }

    init(_ voice: AVSpeechSynthesisVoice) {
        self.init(identifier: voice.identifier, name: voice.name,
                  language: voice.language, quality: voice.quality.rawValue)
    }
}

enum VoiceResolution: Equatable {
    /// Speak with this voice. `newlyPinned`: no pin existed and this one
    /// was pinned now.
    case voice(VoiceCandidate, newlyPinned: Bool)
    /// A voice was pinned and is no longer installed. Never silently
    /// replaced — the session refuses instead.
    case pinnedVoiceMissing(String)
    /// No German voice is installed at all.
    case noGermanVoice
}

/// The deterministic German-voice choice (R-021, audit 2026-10-13; D6
/// default "pin the currently resolved identifier, refuse if missing").
///
/// Before: the first ENHANCED German voice, else the first German voice,
/// in the order `speechVoices()` happened to return — Premium ignored, the
/// order unspecified, and the choice free to change after a voice download
/// or an iOS update between two children, unrecorded.
enum GermanVoiceChooser {
    static func resolve(_ candidates: [VoiceCandidate], pinned: String?) -> VoiceResolution {
        // A pin is honoured or the session refuses — never replaced.
        if let pinned {
            guard let voice = candidates.first(where: { $0.identifier == pinned }) else {
                return .pinnedVoiceMissing(pinned)
            }
            return .voice(voice, newlyPinned: false)
        }
        // No pin yet: TODAY'S rule, deliberately — the first pin must be
        // the voice this device already speaks with, or installing this
        // build would change the voice mid-pilot. Premium / a stable order
        // is D6's choice, not this one's.
        let german = candidates.filter { $0.language.hasPrefix("de") }
        let enhanced = german.first(where: { $0.quality == 2 })
        guard let first = enhanced ?? german.first else { return .noGermanVoice }
        return .voice(first, newlyPinned: true)
    }

    /// Proctor-facing German text for a resolution that cannot speak.
    static func faultText(_ resolution: VoiceResolution) -> String? {
        switch resolution {
        case .voice:
            return nil
        case .pinnedVoiceMissing(let id):
            return "Die festgelegte deutsche Stimme (\(id)) ist auf diesem Gerät nicht mehr installiert. Die Sitzung wird nicht gestartet — eine andere Stimme würde die Anweisungen anders sprechen als bei den bisherigen Kindern. Die Stimme wieder installieren (Einstellungen → Bedienungshilfen → Gesprochene Inhalte → Stimmen → Deutsch)."
        case .noGermanVoice:
            return "Auf diesem Gerät ist keine deutsche Stimme installiert. Die Sitzung wird nicht gestartet — die gesprochenen Anweisungen könnten nicht deutsch gesprochen werden."
        }
    }
}

/// Where the pinned voice identifier lives.
@MainActor
protocol SpeechVoicePinning: AnyObject {
    var pinnedIdentifier: String? { get set }
}

/// Production pin: one `UserDefaults` key. Survives relaunches and app
/// updates; an uninstall clears it, and the next launch pins afresh.
@MainActor
final class UserDefaultsSpeechVoicePin: SpeechVoicePinning {
    static let key = "de.flamingistan.primae.pinnedSpeechVoice"
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    var pinnedIdentifier: String? {
        get { defaults.string(forKey: Self.key) }
        set { defaults.set(newValue, forKey: Self.key) }
    }
}

/// A pin held in memory — tests.
@MainActor
final class InMemorySpeechVoicePin: SpeechVoicePinning {
    var pinnedIdentifier: String?
    init(_ pinned: String? = nil) { pinnedIdentifier = pinned }
}

// MARK: - Production implementation

/// AVSpeechSynthesizer-backed TTS. Picks the best installed German
/// voice at instantiation. If no German voice is present the
/// synthesizer silently no-ops.
@MainActor
final class AVSpeechSpeechSynthesizer: SpeechSynthesizing {

    private let synthesizer: AVSpeechSynthesizer
    private var germanVoice: AVSpeechSynthesisVoice?
    /// Relays `AVSpeechSynthesizerDelegate`'s start/finish/cancel, by
    /// utterance identity, to `utteranceStarted` / `utteranceEnded`.
    private let relay = UtteranceEventRelay()
    private var endHandler: (@MainActor (_ text: String, _ cancelled: Bool) -> Void)?

    func setUtteranceEndHandler(_ handler: (@MainActor (_ text: String, _ cancelled: Bool) -> Void)?) {
        endHandler = handler
    }

    /// A recorded phrase's end, delivered through the registered handler:
    /// the same one an utterance's end reaches, so the view model hears one
    /// kind of report (r9).
    func reportRecordedUtteranceEnd(text: String, cancelled: Bool) {
        endHandler?(text, cancelled)
    }

    // MARK: Queue (review of batch C, items 2 and 3)
    //
    // MEASURED on the study iPad (reviewer probes P6/P6b): a
    // `stopSpeaking(at: .immediate)` issued before the system has STARTED
    // an utterance is ignored — two cues queued and stopped in the same
    // turn both played to their end — and a cut utterance reports BOTH
    // cancelled and finished. So the system gets ONE utterance at a time
    // and the rest wait here, where a stop can simply drop them; the one
    // handed over is stopped again the moment the system reports it
    // started; and each utterance gets exactly one end report, matched by
    // identity — a stopped utterance always reports `cancelled`, and a
    // second or stale report is dropped.

    /// The utterance the system holds (queued or speaking), if any.
    private var inFlight: (utterance: AVSpeechUtterance, text: String, stopped: Bool)?
    /// Lines waiting for the system, in order.
    private var waiting: [String] = []
    /// A hand-over is queued for the next main-actor turn.
    private var handOverScheduled = false
    /// Lines a stop dropped while a line was in flight. They report
    /// right AFTER that line, so end reports always arrive in the order
    /// the lines were spoken (delta review of batch C, item 3).
    private var droppedBehindInFlight: [String] = []
    /// Releases an in-flight utterance the system never reports on. Armed
    /// when the line is handed over (its `lineBudget`), shortened to
    /// `stopWatchdogSeconds` by the first stop, cancelled by the end
    /// report — so a missing callback cannot hold every later line, with
    /// or without a stop (delta review of batch C, item 2).
    private var stopWatchdog: Task<Void, Never>?
    /// How long a stopped utterance may stay unreported before it is
    /// released anyway, so a missing callback cannot silence every later
    /// line. A full cue takes ~2.4 s; the measured stop lands well inside.
    private let stopWatchdogSeconds: TimeInterval = 4.0
    /// How long a line handed to the system may go unreported before it
    /// is released (delta review of batch C, item 2).
    private let lineBudget: (String) -> TimeInterval
    /// The watchdog's wait; a seam so a test can decide when it ends.
    /// Main-actor typed on purpose: a non-isolated closure adds hops between
    /// the wake and the watchdog's check, so a test could not make the wake
    /// run ahead of an end report the system has already made.
    private let watchdogSleep: @MainActor (TimeInterval) async -> Void

    /// A generous upper bound on a line's spoken length: measured at the
    /// study rate, "Schau genau hin." takes ~2.4 s and "Jetzt du." ~1.9 s
    /// (about 0.15 s per character plus a second); this allows 4 s plus
    /// 0.25 s per character.
    nonisolated static func defaultLineBudget(_ text: String) -> TimeInterval {
        4.0 + 0.25 * Double(text.count)
    }

    /// Lines go to the system one main-actor turn after `speak`, so a
    /// stop in the same turn drops them here before the system has
    /// started them — measured on the device (reviewer P7), the system
    /// starts a line 2-8 ms after `speak`, i.e. an audible fragment before
    /// any re-stop could land (delta review of batch C, item 4).
    private func scheduleHandOver() {
        guard !handOverScheduled else { return }
        handOverScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.handOverScheduled = false
            self.handOverNext()
        }
    }

    private func handOverNext() {
        guard inFlight == nil, !waiting.isEmpty else { return }
        let text = waiting.removeFirst()
        let utterance = makeUtterance(text)
        inFlight = (utterance, text, false)
        armWatchdog(for: utterance, seconds: lineBudget(text))
        synthesizer.speak(utterance)
    }

    private func armWatchdog(for utterance: AVSpeechUtterance, seconds: TimeInterval) {
        stopWatchdog?.cancel()
        let id = ObjectIdentifier(utterance)
        let sleep = watchdogSleep
        stopWatchdog = Task { @MainActor [weak self] in
            await sleep(seconds)
            guard !Task.isCancelled, let self,
                  let still = self.inFlight, ObjectIdentifier(still.utterance) == id,
                  // The system HAS reported; the report is only queued
                  // behind this wake (a stalled main actor) and decides.
                  !self.relay.hasReported(id) else { return }
            self.stopWatchdog = nil
            // Let the system go of it too; a late report for it is
            // dropped by identity.
            self.synthesizer.stopSpeaking(at: .immediate)
            self.finish(still, cancelled: true)
        }
    }

    fileprivate func utteranceStarted(_ id: ObjectIdentifier) {
        guard let current = inFlight, ObjectIdentifier(current.utterance) == id,
              current.stopped else { return }
        // The first moment a stop takes effect on the device.
        synthesizer.stopSpeaking(at: .immediate)
    }

    fileprivate func utteranceEnded(_ id: ObjectIdentifier, cancelled: Bool) {
        relay.forget(id)
        guard let current = inFlight, ObjectIdentifier(current.utterance) == id else { return }
        finish(current, cancelled: cancelled)
    }

    private func finish(_ current: (utterance: AVSpeechUtterance, text: String, stopped: Bool), cancelled: Bool) {
        inFlight = nil
        stopWatchdog?.cancel()
        stopWatchdog = nil
        endHandler?(current.text, cancelled || current.stopped)
        let dropped = droppedBehindInFlight
        droppedBehindInFlight.removeAll()
        for text in dropped { endHandler?(text, true) }
        scheduleHandOver()
    }

    /// Default 0.5 reads too fast for a 5-year-old; 0.42 is comfortably
    /// slow without sounding artificially dragged.
    var rate: Float = SpeechRate.standard

    func setRate(_ rate: Float?) {
        self.rate = rate ?? SpeechRate.standard
    }

    var resolvedVoice: SpeechVoiceInfo? { germanVoice.map(SpeechVoiceInfo.init) }
    /// Slight upward shift to match the warm child-friendly tone the
    /// recorded letter audio uses.
    var pitchMultiplier: Float = 1.05

    /// Set when no voice could be used (R-021) — see `voiceFault`.
    private(set) var voiceFault: String?
    private let voiceSource: () -> [AVSpeechSynthesisVoice]
    private let voicePin: SpeechVoicePinning

    /// `synthesizer` is a seam (batch C, R-071) so a test can see what
    /// `stop()` asks of the system synthesiser; production passes none.
    /// `voices` and `voicePin` are seams for the voice choice (batch D,
    /// R-021): production reads the installed voices and the stored pin.
    /// `voices` is a provider, not a list, so a proctor re-pin
    /// (`repinVoice`) sees the voices installed NOW.
    init(synthesizer: AVSpeechSynthesizer = AVSpeechSynthesizer(),
         voices: @escaping () -> [AVSpeechSynthesisVoice] = { AVSpeechSynthesisVoice.speechVoices() },
         voicePin: SpeechVoicePinning = UserDefaultsSpeechVoicePin(),
         lineBudget: @escaping (String) -> TimeInterval = AVSpeechSpeechSynthesizer.defaultLineBudget,
         watchdogSleep: @escaping @MainActor (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }) {
        self.synthesizer = synthesizer
        self.lineBudget = lineBudget
        self.watchdogSleep = watchdogSleep
        self.voiceSource = voices
        self.voicePin = voicePin
        synthesizer.delegate = relay
        resolveVoice()
        // Default `usesApplicationAudioSession = true` shares the
        // AudioEngine's `.playback` session. Disabling it would put
        // the synth on a private session incompatible with the letter-
        // sound pipeline.
        relay.owner = self
    }

    /// Choose the voice from the installed voices and the stored pin.
    private func resolveVoice() {
        let voices = voiceSource()
        let resolution = GermanVoiceChooser.resolve(voices.map(VoiceCandidate.init),
                                                    pinned: voicePin.pinnedIdentifier)
        switch resolution {
        case .voice(let chosen, let newlyPinned):
            germanVoice = voices.first { $0.identifier == chosen.identifier }
            if newlyPinned { voicePin.pinnedIdentifier = chosen.identifier }
        case .pinnedVoiceMissing, .noGermanVoice:
            germanVoice = nil
        }
        voiceFault = GermanVoiceChooser.faultText(resolution)
    }

    /// Forget the stored pin and choose again from the voices installed
    /// now (first enhanced German, else first German). With no German
    /// voice the pin stays cleared and `voiceFault` says so.
    func repinVoice() {
        voicePin.pinnedIdentifier = nil
        resolveVoice()
    }

    func speak(_ text: String) {
        guard !text.isEmpty else { return }
        waiting.append(text)
        scheduleHandOver()
    }

    /// Internal so a test can read the voice and rate an utterance
    /// actually carries, rather than the properties that feed it.
    func makeUtterance(_ text: String) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = germanVoice
        utterance.rate = rate
        utterance.pitchMultiplier = pitchMultiplier
        // 0.9 keeps the spoken feedback slightly under the AudioEngine's
        // letter sound so the child hears both layered.
        utterance.volume = 0.9
        return utterance
    }

    /// Halts the line in flight and drops every waiting one (R-071 and
    /// review of batch C, item 2). Waiting lines never reach the system
    /// and report `cancelled`: right after the line in flight reports, or
    /// on the next main-actor turn when nothing is in flight — so reports
    /// keep the spoken order (delta review, item 3). The line in flight is stopped now if the system has
    /// started it, else when it reports the start (`utteranceStarted`) —
    /// a stop before the start is ignored on the device.
    func stop() {
        let dropped = waiting
        waiting.removeAll()
        guard let current = inFlight else {
            if !dropped.isEmpty {
                Task { @MainActor [weak self] in
                    for text in dropped { self?.endHandler?(text, true) }
                }
            }
            return
        }
        droppedBehindInFlight += dropped
        let firstStop = !current.stopped
        inFlight = (current.utterance, current.text, true)
        synthesizer.stopSpeaking(at: .immediate)
        if firstStop {
            armWatchdog(for: current.utterance, seconds: stopWatchdogSeconds)
        }
    }
}

/// The synthesiser's delegate. AVFoundation calls it off the main actor's
/// static knowledge, so the methods are nonisolated, take the utterance's
/// IDENTITY (not the non-Sendable utterance), and hop to the main actor.
final class UtteranceEventRelay: NSObject, AVSpeechSynthesizerDelegate {
    /// Set once by the owner's `init` and read only inside the `@MainActor`
    /// hops below, so it is main-actor isolated (R-101): the relay is
    /// `Sendable` (it is a delegate called from AVFoundation's thread) and a
    /// plain mutable stored property would not be.
    @MainActor weak var owner: AVSpeechSpeechSynthesizer?
    /// Utterances the system has reported ended whose report has not yet
    /// reached the main actor. Written on the delegate's thread, so the
    /// watchdog can tell "never reported" from "reported, still queued".
    private let reported = Mutex<Set<ObjectIdentifier>>([])

    nonisolated func hasReported(_ id: ObjectIdentifier) -> Bool {
        reported.withLock { $0.contains(id) }
    }

    nonisolated func forget(_ id: ObjectIdentifier) {
        reported.withLock { _ = $0.remove(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didStart utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.owner?.utteranceStarted(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        reported.withLock { _ = $0.insert(id) }
        Task { @MainActor [weak self] in self?.owner?.utteranceEnded(id, cancelled: false) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        reported.withLock { _ = $0.insert(id) }
        Task { @MainActor [weak self] in self?.owner?.utteranceEnded(id, cancelled: true) }
    }
}

// MARK: - Null implementation (tests, previews)

/// Records every spoken line for test assertions; drives no audio.
@MainActor
final class NullSpeechSynthesizer: SpeechSynthesizing {
    private(set) var spokenLines: [String] = []
    private(set) var stopCount: Int = 0

    func speak(_ text: String) { spokenLines.append(text) }
    func stop() { stopCount += 1 }
    func clear() { spokenLines.removeAll(); stopCount = 0 }
}

// MARK: - Phrase library

/// Centralised German feedback phrases — co-locating every phrase the
/// child hears keeps view layout free of hardcoded strings.
enum ChildSpeechLibrary {

    /// Phase entry prompts. Imperative + short so the utterance
    /// finishes before the child plausibly touches the canvas
    /// (AudioEngine's per-touch session reconfiguration cuts TTS short).
    ///
    /// REWORDED 2026-10-02 at the proctor's direction, from a device run
    /// through the three-letter sequence: "Pass jetzt gut auf!" -> "Schau
    /// genau hin.", "Fahr die Linie nach." -> "Jetzt du.", "Und jetzt ohne
    /// Hilfe." -> "Und jetzt ganz allein." The old guided line described
    /// the ACTION ("trace the line") where the new one hands the TURN to
    /// the child, which is what the phase is for; the freeWrite line now
    /// says the same thing in the words the child has heard all session.
    ///
    /// `.direct` is unreachable in a study build (the phase is cut, D5)
    /// but is retained for the casual path. Note these are SILENT under
    /// the `.silent` audio arm — `applyArmAuthority` swaps in
    /// `NullSpeechSynthesizer`, which is the arm's whole condition.
    static func phaseEntry(_ phase: LearningPhase) -> String {
        switch phase {
        case .observe:    return "Schau genau hin."
        case .direct:     return "Tipp die Punkte der Reihe nach an."
        case .guided:     return "Jetzt du."
        case .freeWrite:  return "Und jetzt ganz allein."
        }
    }

    /// Praise spoken on guided / freeWrite stroke completion. 0-star
    /// stays warm — "probier nochmal" without judgement.
    static func praise(starsEarned: Int) -> String {
        switch starsEarned {
        case 4: return "Wow, das war perfekt! Super gemacht."
        case 3: return "Toll gemacht!"
        case 2: return "Gut gemacht!"
        case 1: return "Schon gut! Probier's nochmal."
        default: return "Probier's gleich nochmal."
        }
    }

    /// Recognition badge announcement. Corrections use imperative
    /// phrasing ("schreib nochmal ein A") — a 5-year-old needs a
    /// concrete next action.
    static func recognition(_ result: RecognitionResult, expected: String) -> String {
        if result.isCorrect {
            if result.confidence > 0.7 {
                return "Du hast ein \(expected) geschrieben! Super!"
            } else {
                return "Das sieht aus wie ein \(expected). Gut gemacht!"
            }
        }
        if result.confidence > 0.7 {
            return "Das sieht eher nach \(result.predictedLetter) aus. Schreib nochmal ein \(expected)."
        }
        // Low-confidence misses stay silent at the badge level. Caller
        // is expected to gate on confidence before speaking.
        return ""
    }

    /// Paper-transfer prompts spoken alongside the matching screen.
    static let paperTransferShow = "Schau dir den Buchstaben gut an."
    static let paperTransferWrite = "Jetzt schreibst du den Buchstaben auf Papier."
    static let paperTransferAssess = "Wie ist dein Buchstabe geworden?"

    /// Spaced-retrieval modal headline — spoken on appear.
    static let retrievalQuestion = "Welchen Buchstaben hörst du?"

    /// Spoken after every letter completes. The on-screen star row
    /// carries the gradation; audio is always a warm "Super gemacht!".
    static let celebration = "Super gemacht!"

    // MARK: - PromptPlayer mapping

    /// Map a learning phase to the PromptKey for its bundled MP3.
    static func phaseEntryPromptKey(_ phase: LearningPhase) -> PromptPlayer.PromptKey {
        switch phase {
        case .observe:   return .phaseObserve
        case .direct:    return .phaseDirect
        case .guided:    return .phaseGuided
        case .freeWrite: return .phaseFreeWrite
        }
    }

}
