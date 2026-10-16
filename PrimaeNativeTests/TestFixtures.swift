import Foundation
import CoreGraphics
import UserNotifications
@testable import PrimaeNative

// MARK: - Shared no-op stubs for unit tests

final class StubAudio: AudioControlling {
    var initializationError: String? { nil }
    func loadAudioFile(named: String, autoplay: Bool) {}
    func setAdaptivePlayback(speed: Float, horizontalBias: Float) {}
    func play() {}
    func stop() {}
    func restart() {}
    func suspendForLifecycle() {}
    func resumeAfterLifecycle() {}
    func cancelPendingLifecycleWork() {}
}

/// A recording engine double that MODELS the parts of `AudioEngine` a
/// carry-over defect lives in (2026-10-13). Promoted from
/// `ProtocolMatrixTests` (where it was the file-private `RecordingAudio`;
/// that suite still names it so through a typealias), not a new double.
///
/// What it models, each from the engine's own code:
///   - `loadAudioFile` stops the player and plays only on autoplay
///     (`AudioEngine.loadAudioFile` opens with `player.stop()`);
///   - `stop()` stops AND drops the file (`finishStop` sets
///     `currentFile = nil`);
///   - `play()` without a loaded file is a no-op in the engine
///     (`play(fadeInSeconds:)` guards `currentFile != nil`) — recorded in
///     `plays` with a nil `file`, so a test can tell it from an audible
///     play. (`isPlaying` keeps the meaning it had in ProtocolMatrixTests:
///     the last call was a play or an autoplay load.)
///   - rate, pan and pitch are engine STATE: set by `setAdaptivePlayback`
///     / `setSpatialPitch`, start neutral (1.0 / 0 / 0 cents, the values
///     `AudioEngine.init` sets), and are changed by nothing else — not by
///     a load, not by a stop. `plays` snapshots them at every play.
@MainActor
final class EngineModelAudio: AudioControlling {
    enum Event: Equatable { case load(String), play(fade: TimeInterval), stop }
    /// The engine's state at one `play` call.
    struct PlaySnapshot: Equatable {
        let file: String?
        let rate: Float
        let pan: Float
        let pitchCents: Float
    }
    var initializationError: String? { nil }
    private(set) var events: [Event] = []
    private(set) var setAdaptiveCalls: [(speed: Float, bias: Float)] = []
    private(set) var spatialPitches: [Float] = []
    /// Mirrors the engine: a load stops the player and plays only on
    /// autoplay; `stop()` stops.
    private(set) var isPlaying = false
    /// Phase the view model was in at each `stop()`, read through
    /// `phaseAtCall` — so a stop that ends observe early can be told from
    /// the one that ends it with the phase.
    var phaseAtCall: @MainActor () -> LearningPhase? = { nil }
    private(set) var stopsDuringObserve = 0

    // The modelled engine state.
    private(set) var loadedFile: String?
    private(set) var rate: Float = 1.0
    private(set) var pan: Float = 0
    private(set) var pitchCents: Float = 0
    private(set) var plays: [PlaySnapshot] = []

    func loadAudioFile(named: String, autoplay: Bool) {
        events.append(.load(named)); isPlaying = autoplay
        loadedFile = named
        if autoplay { snapshotPlay() }
    }
    func setAdaptivePlayback(speed: Float, horizontalBias: Float) {
        setAdaptiveCalls.append((speed, horizontalBias))
        rate = speed; pan = horizontalBias
    }
    func setSpatialPitch(cents: Float) { spatialPitches.append(cents); pitchCents = cents }
    func play() { events.append(.play(fade: 0)); isPlaying = true; snapshotPlay() }
    func play(fadeInSeconds: TimeInterval) { events.append(.play(fade: fadeInSeconds)); isPlaying = true; snapshotPlay() }
    func stop() {
        events.append(.stop); isPlaying = false
        loadedFile = nil
        if phaseAtCall() == .observe { stopsDuringObserve += 1 }
    }
    func restart() {}
    /// Probe closing-window labels, in order — `emitAudioSignalSummary` is
    /// a protocol requirement (`AudioControlling`), so the call reaches here.
    private(set) var summaryLabels: [String] = []
    func emitAudioSignalSummary(label: String) { summaryLabels.append(label) }
    func suspendForLifecycle() { isPlaying = false }
    func resumeAfterLifecycle() {}
    func cancelPendingLifecycleWork() {}

    private func snapshotPlay() {
        plays.append(PlaySnapshot(file: loadedFile, rate: rate, pan: pan, pitchCents: pitchCents))
    }

    var playCount: Int { events.filter { if case .play = $0 { return true } else { return false } }.count }
    var anyActivity: Bool { !events.isEmpty || !setAdaptiveCalls.isEmpty || !spatialPitches.isEmpty }
}

final class StubHaptics: HapticEngineProviding {
    func prepare() {}
    func fire(_ event: HapticEvent) {}
}

// MARK: - No-op resource provider (avoids FileManager bundle scan hang in CI)
final class StubResourceProvider: LetterResourceProviding {
    var bundle: Bundle = .main
    var searchBundles: [Bundle] { [bundle] }

    /// Temporary directory containing a test letter whose stroke checkpoints
    /// align with the standard test drag helpers (from (0.25,0.5) → (0.5,0.5)
    /// in normalised coordinates on a 400×400 canvas).
    private static let testLetterDir: URL = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StubLetterResources", isDirectory: true)
        let letterDir = dir.appendingPathComponent("Letters/Regular/A", isDirectory: true)
        try? FileManager.default.createDirectory(at: letterDir, withIntermediateDirectories: true)

        // Single horizontal stroke matching the test drag path
        let strokes: [String: Any] = [
            "letter": "A",
            "checkpointRadius": 0.5,
            "strokes": [
                [
                    "id": 1,
                    "checkpoints": [["x": 0.00, "y": 0.50], ["x": 0.02, "y": 0.50], ["x": 0.04, "y": 0.50], ["x": 0.06, "y": 0.50], ["x": 0.08, "y": 0.50], ["x": 0.10, "y": 0.50], ["x": 0.12, "y": 0.50], ["x": 0.14, "y": 0.50], ["x": 0.16, "y": 0.50], ["x": 0.18, "y": 0.50], ["x": 0.20, "y": 0.50], ["x": 0.22, "y": 0.50], ["x": 0.24, "y": 0.50], ["x": 0.26, "y": 0.50], ["x": 0.28, "y": 0.50], ["x": 0.30, "y": 0.50], ["x": 0.32, "y": 0.50], ["x": 0.34, "y": 0.50], ["x": 0.36, "y": 0.50], ["x": 0.38, "y": 0.50], ["x": 0.40, "y": 0.50], ["x": 0.42, "y": 0.50], ["x": 0.44, "y": 0.50], ["x": 0.46, "y": 0.50], ["x": 0.48, "y": 0.50], ["x": 0.50, "y": 0.50], ["x": 0.52, "y": 0.50], ["x": 0.54, "y": 0.50], ["x": 0.56, "y": 0.50], ["x": 0.58, "y": 0.50], ["x": 0.60, "y": 0.50], ["x": 0.62, "y": 0.50], ["x": 0.64, "y": 0.50], ["x": 0.66, "y": 0.50], ["x": 0.68, "y": 0.50], ["x": 0.70, "y": 0.50], ["x": 0.72, "y": 0.50], ["x": 0.74, "y": 0.50], ["x": 0.76, "y": 0.50], ["x": 0.78, "y": 0.50], ["x": 0.80, "y": 0.50], ["x": 0.82, "y": 0.50], ["x": 0.84, "y": 0.50], ["x": 0.86, "y": 0.50], ["x": 0.88, "y": 0.50], ["x": 0.90, "y": 0.50], ["x": 0.92, "y": 0.50], ["x": 0.94, "y": 0.50], ["x": 0.96, "y": 0.50], ["x": 0.98, "y": 0.50]]
                ]
            ]
        ]
        let data = try! JSONSerialization.data(withJSONObject: strokes, options: .prettyPrinted)
        try? data.write(to: letterDir.appendingPathComponent("strokes.json"))

        // Dummy audio files (zero bytes — StubAudio ignores them). The
        // phoneme take is REQUIRED since 2026-09-04: a phoneme-arm study
        // VM refuses to trace a study letter without one
        // (`studyPreconditionFailure`), and the fixture letter A is a
        // study letter. Tests that mean to exercise the refusal build a
        // phoneme-less asset themselves.
        try? Data().write(to: letterDir.appendingPathComponent("A.mp3"))
        try? Data().write(to: letterDir.appendingPathComponent("A_phoneme1.mp3"))

        return dir
    }()

    func allResourceURLs() -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: Self.testLetterDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    func resourceURL(for relativePath: String) -> URL? {
        let url = Self.testLetterDir.appendingPathComponent(relativePath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

// MARK: - No-op progress store (avoids FileManager.applicationSupportDirectory hang in CI)
final class StubProgressStore: ProgressStoring {
    func progress(for letter: String) -> LetterProgress { LetterProgress() }
    func recordCompletion(for letter: String, accuracy: Double,
                          phaseScores: [String: Double]?, speed: Double?,
                          recognitionResult: RecognitionResult?, formAccuracy: Double?) {}
    // These four are plain protocol requirements with no extension
    // default, so omitting one is a BUILD error rather than a runtime
    // trap. Opt in to no-op behaviour explicitly, per channel.
    func recordPaperTransferScore(for letter: String, score: Double) {}
    func recordVariantUsed(for letter: String, variantID: String?) {}
    func recordFreeformCompletion(letter: String, result: RecognitionResult) {}
    func recordRecognitionSample(letter: String, result: RecognitionResult) {}
    func resetAll() {}
    var allProgress: [String: LetterProgress] { [:] }
    var totalCompletions: Int { 0 }
}

// MARK: - No-op streak store
final class StubStreakStore: StreakStoring {
    var currentStreak: Int { 0 }
    var longestStreak: Int { 0 }
    var totalCompletions: Int { 0 }
    var completedLetters: Set<String> { [] }
    @discardableResult
    func recordSession(date: Date, lettersCompleted: [String], accuracy: Double) -> [RewardEvent] { [] }
    func reset() {}
}

// MARK: - No-op dashboard store
final class StubDashboardStore: ParentDashboardStoring {
    var snapshot: DashboardSnapshot { DashboardSnapshot() }
    func recordSession(letter: String, accuracy: Double,
                       durationSeconds: TimeInterval,
                       wallClockSeconds: TimeInterval?,
                       date: Date, condition: ThesisCondition,
                       inputDevice: String?) {}
    func recordPhaseSession(letter: String, phase: String, completed: Bool, score: Double, schedulerPriority: Double, condition: ThesisCondition, audioCondition: PilotAudioCondition, assessment: WritingAssessment?, recognition: RecognitionSample?, inputDevice: String?, rawTraceID: UUID?, trainedSubset: String?, phaseDurationSeconds: Double?, frechetDistance: Double?, checkpointCoverage: Double?, spatialDeviation: Double?, strokeCount: Int?, strokeOrder: String?, reversedStrokeCount: Int?, studyMode: Bool?, probe: String?, comparisonConfiguration: String?) {}
    func reset() {}
}

// MARK: - In-memory raw-trace store (records appends + reset for assertions)
final class StubRawTraceStore: RawTraceStoring {
    private(set) var traces: [RawTrace] = []
    private(set) var resetCount = 0
    /// Counts lifecycle drains — the protocol default `flush()` is a no-op,
    /// so without this override a missing drain is indistinguishable from a
    /// performed one. See RawTracePersistenceTests.
    private(set) var flushCount = 0
    func append(_ trace: RawTrace) { traces.append(trace) }
    func reset() { traces.removeAll(); resetCount += 1 }
    func flush() async { flushCount += 1 }
}

// MARK: - In-memory participant archive (records seals for assertions)
final class StubParticipantArchive: ParticipantArchiving {
    private(set) var archivedParticipants: [ArchivedParticipant] = []
    /// Counts lifecycle drains, for the same reason as
    /// `StubRawTraceStore.flushCount`: the protocol default is a no-op.
    private(set) var flushCount = 0
    /// Append-only, like the real store (R-047).
    func archive(_ record: ArchivedParticipant) {
        archivedParticipants.append(record)
    }
    func flush() async { flushCount += 1 }
}

final class StubEnrolmentLog: EnrolmentLogging {
    private(set) var enrolments: [EnrolmentRecord] = []
    /// Counts lifecycle drains (the protocol default is a no-op).
    private(set) var flushCount = 0
    func flush() async { flushCount += 1 }
    func append(_ record: EnrolmentRecord) {
        enrolments.removeAll { $0.participantId == record.participantId }
        enrolments.append(record)
    }
}

final class StubSetCompletionLedger: SetCompletionRecording {
    private(set) var completed: Set<UUID> = []
    func isSetComplete(for participantId: UUID) -> Bool { completed.contains(participantId) }
    func markSetComplete(for participantId: UUID) { completed.insert(participantId) }
}

// MARK: - No-op onboarding store
final class StubOnboardingStore: OnboardingStoring {
    var hasCompletedOnboarding: Bool { false }
    var savedStep: OnboardingStep? { nil }
    var variantUsed: OnboardingVariant? { nil }
    func markComplete(variant: OnboardingVariant) {}
    func saveProgress(step: OnboardingStep) {}
    func reset() {}
}

// MARK: - No-op notification center (avoids UNUserNotificationCenter.current() in CI)
// The scheduler is compiled out of a study build (R-065).
#if !STUDY_BUILD
final class StubNotificationCenter: UserNotificationCenterProtocol {
    func requestAuthorization(options: UNAuthorizationOptions,
                               completionHandler: @escaping @Sendable (Bool, Error?) -> Void) {
        completionHandler(false, nil)
    }
    func add(_ request: UNNotificationRequest,
             withCompletionHandler completionHandler: (@Sendable (Error?) -> Void)?) {}
    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {}
    func removeAllPendingNotificationRequests() {}
}
#endif

// MARK: - Null letter cache (throws on load — forces fresh parse, prevents cross-test pollution)
struct NullLetterCache: LetterCacheStoring {
    func save(_ letters: [LetterAsset]) throws(LetterRepositoryError) {}
    func load() throws(LetterRepositoryError) -> [LetterAsset] {
        throw LetterRepositoryError.cacheReadFailed(path: "")
    }
    func clear() {}
}

// MARK: - Fixed delivery environment (batch D)
/// The device/audio state a fixture reports: a settable value, so a test
/// can change "the device" between two samples without touching it.
@MainActor
final class FixedDeliveryEnvironment: DeliveryEnvironmentProviding {
    static let defaultStamp = EnvironmentStamp(
        outputRoute: "Headphones", outputVolume: 0.5, outputLatency: 0.005,
        otherAudioPlaying: false, secondaryAudioHint: false,
        guidedAccess: true, idleTimerDisabled: true, lowPowerMode: false,
        thermalState: "nominal", batteryLevel: 0.8)
    static let build = BuildStamp(
        launchId: "00000000-0000-0000-0000-00000000D0D0", previousRunAbnormal: false,
        appVersion: "1.0 (1)", buildConfiguration: "test", buildUUID: "TEST-BUILD",
        osVersion: "test-os", deviceModel: "test-device")
    var stamp: EnvironmentStamp
    private(set) var sampleCount = 0
    init(_ stamp: EnvironmentStamp? = nil) { self.stamp = stamp ?? Self.defaultStamp }
    func sample() -> EnvironmentStamp { sampleCount += 1; return stamp }
}

// MARK: - Shared VM factory
@MainActor
func makeTestVM(
    audio: AudioControlling? = nil,
    haptics: HapticEngineProviding? = nil
) -> TracingViewModel {
    var deps = TracingDependencies.stub
    if let audio    { deps = deps.with(audio: audio) }
    if let haptics  { deps = deps.with(haptics: haptics) }
    return TracingViewModel(deps)
}

// MARK: - TracingDependencies test builder
extension TracingDependencies {
    /// Fully-stubbed configuration safe for headless CI.
    /// No FileManager, no AVAudioEngine, no UNUserNotificationCenter.
    @MainActor
    static var stub: TracingDependencies {
        let progressStore = StubProgressStore()
        let streakStore   = StubStreakStore()
        let deps = TracingDependencies(
            audio:                StubAudio(),
            progressStore:        progressStore,
            haptics:              StubHaptics(),
            repo:                 LetterRepository(resources: StubResourceProvider(),
                                                   cache: NullLetterCache()),
            streakStore:          streakStore,
            dashboardStore:       StubDashboardStore(),
            rawTraceStore:        StubRawTraceStore(),
            participantArchive:   StubParticipantArchive(),
            // In memory: a test that enrols a child must never append to
            // the simulator's real `Enrolments/` directory.
            enrolmentLog:         StubEnrolmentLog(),
            // In memory, per fixture: the live ledger is a global
            // UserDefaults key, and a hold written by one test must never
            // park another test's VM.
            setCompletion:        StubSetCompletionLedger(),
            onboardingStore:      StubOnboardingStore(),
            thesisCondition:      .guidedOnly,
            // Pin the audio arm too so tests don't depend on global
            // ParticipantStore enrolment state (mirrors thesisCondition).
            audioCondition:       .phoneme,
            // Pin the trained subset for the same reason (the default
            // reads ParticipantStore). "AFI" = allSubsets[0].
            trainedSubset:        TrainedLetterSubset.allSubsets[0],
            // Pin studyMode for the same reason as the three axes above,
            // plus one specific to it: since B2 the default resolves ON in
            // a study build, so an unpinned fixture makes every VM-building
            // test behave differently depending on which binary compiled
            // it — which is how three haptic tests started failing in the
            // study build only. Tests that mean to exercise studyMode say
            // so at the call site with `.with(studyMode:)`, in whichever
            // direction they are asserting.
            studyMode:            false,
            participantEnrolled:  true,   // the precondition reads THIS, not the device
            // Pin the arm-cycle comparison switch OFF, for the same reason
            // as studyMode above and one sharper: `StudyComparisonSwitches
            // Tests.resetRestoresDefaults` WRITES `cycleAllConditions = true`
            // (no `defer`) before clearing it, and suites run in PARALLEL —
            // so a fixture that read the global would hand whichever VM was
            // constructed inside that window a cycling session. Tests that
            // mean to exercise the cycle say so at the call site
            // (`deps.cycleAllConditions = true`).
            cycleAllConditions:   false,
            // Pin both trigger-boundary switches for the same reason, and
            // a sharper one: their DEFAULT ARGUMENTS read a UserDefaults
            // key, so an unpinned fixture would evaluate those reads at
            // every `TracingDependencies(stub…)` construction in the
            // parallel run — i.e. every VM-building test would sample
            // whatever the trigger-boundary suite had written at that
            // instant. Pinning makes the read never happen. Tests that
            // mean to exercise these say so at the call site
            // (`deps.soundGateRadiusFactor = …`).
            soundGateRadiusFactor: StudyComparisonSettings.soundGateRadiusFactorDefault,
            soundGateVelocityFloor: StudyComparisonSettings.soundGateVelocityFloorDefault,
            // Same reason (2026-10-05): the observe start adds this, and
            // `StudyComparisonSwitchesTests` writes the global to 4–5 s.
            presentationSpacingSeconds: StudyComparisonSettings.presentationSpacingSecondsDefault,
            // Pin the once-per-condition demonstration switch, same reason
            // as `cycleAllConditions` above: a suite that writes the
            // global key would otherwise hand whichever VM was
            // constructed inside that window a session with a suppressed
            // demonstration. Tests that mean to exercise it say so at the
            // call site (`deps.oncePerCondition = true`).
            oncePerCondition:     false,
            // Pin the observe pass count, same reason as the switches above —
            // and this is the one that proved the rule (2026-10-16): a fixture
            // built while `StudyComparisonSwitchesTests` held the global at 2
            // needed two passes, so `AuditThirdPassTests`' *"one full pass must
            // end observe"* failed in a run where neither test was about the
            // other. Tests that mean to exercise it say so at the call site
            // (`deps.observePasses = 2`).
            observePasses:        StudyComparisonSettings.observePassesDefault,
            letterRecognizer:     StubLetterRecognizer(),
            speech:               NullSpeechSynthesizer(),
            // Batch D: a fixed environment, no sentinel file and a fixed
            // build stamp — a fixture must never read the device or write
            // the app container's launch marker.
            deliveryEnvironment:  FixedDeliveryEnvironment(),
            launchSentinel:       NullLaunchSentinel(),
            buildStamp:           FixedDeliveryEnvironment.build,
            // Real AVAudioPlayer.play() in PromptPlayer adds enough
            // simulator overhead per call to push the rapid-tap test
            // past its 100 ms wall-clock playIntent debounce.
            makePromptPlayer:     { _ in NullPromptPlayer() }
        )
        #if STUDY_BUILD
        return deps
        #else
        var casual = deps
        casual.notificationScheduler = LocalNotificationScheduler(center: StubNotificationCenter())
        return casual
        #endif
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
    func with(streakStore: StreakStoring) -> TracingDependencies {
        var copy = self; copy.streakStore = streakStore; return copy
    }
    func with(dashboardStore: ParentDashboardStoring) -> TracingDependencies {
        var copy = self; copy.dashboardStore = dashboardStore; return copy
    }
    func with(rawTraceStore: RawTraceStoring) -> TracingDependencies {
        var copy = self; copy.rawTraceStore = rawTraceStore; return copy
    }
    func with(participantArchive: ParticipantArchiving) -> TracingDependencies {
        var copy = self; copy.participantArchive = participantArchive; return copy
    }
    func with(onboardingStore: OnboardingStoring) -> TracingDependencies {
        var copy = self; copy.onboardingStore = onboardingStore; return copy
    }
    func with(thesisCondition: ThesisCondition) -> TracingDependencies {
        var copy = self; copy.thesisCondition = thesisCondition; return copy
    }
    func with(audioCondition: PilotAudioCondition) -> TracingDependencies {
        var copy = self; copy.audioCondition = audioCondition; return copy
    }
    func with(studyMode: Bool) -> TracingDependencies {
        var copy = self; copy.studyMode = studyMode; return copy
    }
    /// A device with NO participant enrolled — the state a study iPad is
    /// in between the moment it is first launched and the moment the
    /// proctor enrols child #1. `stub` pins `participantEnrolled: true`,
    /// so before this existed the entire cold-start path had no fixture
    /// and no test: every VM-building test started already enrolled, and
    /// a defect that made enrolling at runtime unable to clear the
    /// start-gate was invisible to the whole suite. Found on the physical
    /// iPad 2026-10-02, not by a test.
    func with(participantEnrolled: Bool) -> TracingDependencies {
        var copy = self; copy.participantEnrolled = participantEnrolled; return copy
    }
    func with(trainedSubset: TrainedLetterSubset) -> TracingDependencies {
        var copy = self; copy.trainedSubset = trainedSubset; return copy
    }
    func with(oncePerCondition: Bool) -> TracingDependencies {
        var copy = self; copy.oncePerCondition = oncePerCondition; return copy
    }
    func with(cycleAllConditions: Bool) -> TracingDependencies {
        var copy = self; copy.cycleAllConditions = cycleAllConditions; return copy
    }
}
