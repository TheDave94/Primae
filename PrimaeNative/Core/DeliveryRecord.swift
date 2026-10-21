// DeliveryRecord.swift
// PrimaeNative
//
// WHAT THE CHILD WAS ACTUALLY EXPOSED TO, per row (fix batch D, audit
// 2026-10-13: R-020, R-018, R-021, R-034, R-032, R-123).
//
// Every row already said which arm the child was ASSIGNED. Nothing said
// whether that arm's sound could have reached the child: which output the
// audio left through, whether another app was playing over it, how often
// the session was interrupted or the observe phase restarted, which voice
// spoke the instructions, which binary and which launch wrote the row, and
// whether a free-writing trial ended because the child finished it or
// because the app was backgrounded or the proctor moved on. These value
// types carry those facts; the view model fills them in at the moment the
// phase runs and the row is built, never at export time.
//
// Every field is optional and decodes lossily, so every file written
// before this existed still decodes (its rows simply carry no delivery
// record), and a malformed value costs only itself.

import Foundation

// MARK: - Why a row was written

/// What closed the trial a row records (R-020 / H1, audit 2026-10-13).
/// Before this, a free-writing trial force-finalised by backgrounding or by
/// the proctor's chevron was written `completed: true`, indistinguishable
/// from a trial the child finished.
enum RowFinalization: String, Codable, CaseIterable {
    /// The session's own flow closed it: the 2.0 s quiet window after the
    /// child's lift (free-writing), or the phase flow itself.
    case child
    /// The app went to the background with the production pending.
    case background
    /// The proctor moved on (chevron, letter or probe load) while the
    /// letter was open; also every `completed: false` row.
    case navigation
}

// MARK: - Environment at one instant

/// The device and audio state read at one instant — a phase's start, or an
/// enrolment (R-020, R-018). Each field is nil when it could not be read.
struct EnvironmentStamp: Codable, Equatable {
    /// `AVAudioSession.Port` raw value of the first output ("Headphones",
    /// "Speaker", "BluetoothA2DPOutput", …).
    var outputRoute: String?
    /// `AVAudioSession.outputVolume` (0–1).
    var outputVolume: Double?
    /// `AVAudioSession.outputLatency`, seconds.
    var outputLatency: Double?
    /// `AVAudioSession.isOtherAudioPlaying` — another app is playing audio
    /// (R-018: the session mixes, so it plays through every arm, silent
    /// included).
    var otherAudioPlaying: Bool?
    /// `AVAudioSession.secondaryAudioShouldBeSilencedHint`.
    var secondaryAudioHint: Bool?
    /// `UIAccessibility.isGuidedAccessEnabled`.
    var guidedAccess: Bool?
    /// `UIApplication.isIdleTimerDisabled` (R-044 sets it while enrolled).
    var idleTimerDisabled: Bool?
    /// `ProcessInfo.isLowPowerModeEnabled`.
    var lowPowerMode: Bool?
    /// `ProcessInfo.thermalState`: nominal / fair / serious / critical.
    var thermalState: String?
    /// `UIDevice.batteryLevel` (0–1); nil when unknown.
    var batteryLevel: Double?

    init(outputRoute: String? = nil, outputVolume: Double? = nil, outputLatency: Double? = nil,
         otherAudioPlaying: Bool? = nil, secondaryAudioHint: Bool? = nil,
         guidedAccess: Bool? = nil, idleTimerDisabled: Bool? = nil,
         lowPowerMode: Bool? = nil, thermalState: String? = nil, batteryLevel: Double? = nil) {
        self.outputRoute = outputRoute
        self.outputVolume = DeliveryCoding.finite(outputVolume)
        self.outputLatency = DeliveryCoding.finite(outputLatency)
        self.otherAudioPlaying = otherAudioPlaying
        self.secondaryAudioHint = secondaryAudioHint
        self.guidedAccess = guidedAccess
        self.idleTimerDisabled = idleTimerDisabled
        self.lowPowerMode = lowPowerMode
        self.thermalState = thermalState
        self.batteryLevel = DeliveryCoding.finite(batteryLevel)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        outputRoute        = try? c.decode(String.self, forKey: .outputRoute)
        outputVolume       = try? c.decode(Double.self, forKey: .outputVolume)
        outputLatency      = try? c.decode(Double.self, forKey: .outputLatency)
        otherAudioPlaying  = try? c.decode(Bool.self, forKey: .otherAudioPlaying)
        secondaryAudioHint = try? c.decode(Bool.self, forKey: .secondaryAudioHint)
        guidedAccess       = try? c.decode(Bool.self, forKey: .guidedAccess)
        idleTimerDisabled  = try? c.decode(Bool.self, forKey: .idleTimerDisabled)
        lowPowerMode       = try? c.decode(Bool.self, forKey: .lowPowerMode)
        thermalState       = try? c.decode(String.self, forKey: .thermalState)
        batteryLevel       = try? c.decode(Double.self, forKey: .batteryLevel)
    }
}

// MARK: - Which binary, which launch

/// The binary and the process launch that wrote a row (R-020). The app's
/// version string is the constant "1.0"/"1" in every configuration, so the
/// build is identified by the executable's Mach-O UUID, which the linker
/// makes unique per build.
struct BuildStamp: Codable, Equatable {
    /// One UUID per process launch (`LaunchSentinel`).
    var launchId: String?
    /// The PREVIOUS launch ended while the app was in the foreground — a
    /// crash, a watchdog kill or a jetsam — rather than after a clean
    /// move to the background (`LaunchSentinel`).
    var previousRunAbnormal: Bool?
    /// `CFBundleShortVersionString (CFBundleVersion)`.
    var appVersion: String?
    /// "debug" (`#if DEBUG` surfaces compiled in — Debug-Study) or
    /// "release" (the pilot artefact).
    var buildConfiguration: String?
    /// LC_UUID of the image that holds this code.
    var buildUUID: String?
    /// `ProcessInfo.operatingSystemVersionString`.
    var osVersion: String?
    /// `hw.machine`, e.g. "iPad13,8".
    var deviceModel: String?

    init(launchId: String? = nil, previousRunAbnormal: Bool? = nil, appVersion: String? = nil,
         buildConfiguration: String? = nil, buildUUID: String? = nil,
         osVersion: String? = nil, deviceModel: String? = nil) {
        self.launchId = launchId
        self.previousRunAbnormal = previousRunAbnormal
        self.appVersion = appVersion
        self.buildConfiguration = buildConfiguration
        self.buildUUID = buildUUID
        self.osVersion = osVersion
        self.deviceModel = deviceModel
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        launchId            = try? c.decode(String.self, forKey: .launchId)
        previousRunAbnormal = try? c.decode(Bool.self, forKey: .previousRunAbnormal)
        appVersion          = try? c.decode(String.self, forKey: .appVersion)
        buildConfiguration  = try? c.decode(String.self, forKey: .buildConfiguration)
        buildUUID           = try? c.decode(String.self, forKey: .buildUUID)
        osVersion           = try? c.decode(String.self, forKey: .osVersion)
        deviceModel         = try? c.decode(String.self, forKey: .deviceModel)
    }
}

// MARK: - One phase's delivery

/// What one PHASE of a letter delivered (R-020). The counters are the
/// phase's own share of the letter's `LifecycleCounters` (fix batch C,
/// which kept them in memory only).
struct PhaseDelivery: Codable, Equatable {
    /// Observe restarted from the cue after an interruption (R-006).
    var observeRestarts: Int?
    /// Touches the system cancelled (R-024).
    var strokesCancelled: Int?
    /// Audio output DEVICE changes (headphones in/out, Bluetooth, route
    /// override) — filtered by reason, so the engine's own category changes
    /// are not counted (`RouteChangeFilter`).
    var routeChanges: Int?
    /// Times the session was suspended (an inactive scene, the parent
    /// area) during the phase (R-005, R-026).
    var interruptions: Int?
    /// The environment when the phase started.
    var atStart: EnvironmentStamp?
    /// The audio output when the phase ended (or when the row was written,
    /// for the phase still open then).
    var outputRouteAtEnd: String?
    /// Identifier of the voice the session's speech used for the row
    /// (R-021); nil when the session speaks with no voice.
    var voiceId: String?
    /// Whether the recognizer model was available when the row was written
    /// (R-034); nil when not known yet.
    var recognizerAvailable: Bool?
    /// Which binary and launch wrote the row.
    var build: BuildStamp?
    /// Protocol r11, RECORD-ONLY, observe rows only (nil on every other
    /// phase's row and on rows written before r11). Outputs lost while the
    /// arm's dot-tracked observe sound played (its rest cut, not replayed)
    /// and while none played (the cue, the gap before the presentation, a
    /// held observe; the whole phase in an arm with no observe sound).
    /// Silent arm: `observeLossesDuringSound` and both seconds are 0.
    var observeLossesDuringSound: Int?
    var observeLossesWithoutSound: Int?
    /// Seconds the observe sound ran (play call to stop), and of those the
    /// seconds before a lost output — so delivered ÷ ran is the share of
    /// the observe sound the child could hear. 0 where no sound ran.
    var observeSoundSeconds: Double?
    var observeSoundDeliveredSeconds: Double?

    init(observeRestarts: Int? = nil, strokesCancelled: Int? = nil, routeChanges: Int? = nil,
         interruptions: Int? = nil, atStart: EnvironmentStamp? = nil, outputRouteAtEnd: String? = nil,
         voiceId: String? = nil, recognizerAvailable: Bool? = nil, build: BuildStamp? = nil,
         observeLossesDuringSound: Int? = nil, observeLossesWithoutSound: Int? = nil,
         observeSoundSeconds: Double? = nil, observeSoundDeliveredSeconds: Double? = nil) {
        self.observeRestarts = observeRestarts
        self.strokesCancelled = strokesCancelled
        self.routeChanges = routeChanges
        self.interruptions = interruptions
        self.atStart = atStart
        self.outputRouteAtEnd = outputRouteAtEnd
        self.voiceId = voiceId
        self.recognizerAvailable = recognizerAvailable
        self.build = build
        self.observeLossesDuringSound = observeLossesDuringSound
        self.observeLossesWithoutSound = observeLossesWithoutSound
        self.observeSoundSeconds = DeliveryCoding.finite(observeSoundSeconds)
        self.observeSoundDeliveredSeconds = DeliveryCoding.finite(observeSoundDeliveredSeconds)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        observeRestarts     = try? c.decode(Int.self, forKey: .observeRestarts)
        strokesCancelled    = try? c.decode(Int.self, forKey: .strokesCancelled)
        routeChanges        = try? c.decode(Int.self, forKey: .routeChanges)
        interruptions       = try? c.decode(Int.self, forKey: .interruptions)
        atStart             = try? c.decode(EnvironmentStamp.self, forKey: .atStart)
        outputRouteAtEnd    = try? c.decode(String.self, forKey: .outputRouteAtEnd)
        voiceId             = try? c.decode(String.self, forKey: .voiceId)
        recognizerAvailable = try? c.decode(Bool.self, forKey: .recognizerAvailable)
        build               = try? c.decode(BuildStamp.self, forKey: .build)
        observeLossesDuringSound     = try? c.decode(Int.self, forKey: .observeLossesDuringSound)
        observeLossesWithoutSound    = try? c.decode(Int.self, forKey: .observeLossesWithoutSound)
        observeSoundSeconds          = try? c.decode(Double.self, forKey: .observeSoundSeconds)
        observeSoundDeliveredSeconds = try? c.decode(Double.self, forKey: .observeSoundDeliveredSeconds)
    }
}

/// Everything a row writer adds to a phase row beyond the measurement
/// fields (batch D). One value, so the store's row-building requirement
/// gains one parameter rather than a dozen.
struct PhaseRowContext: Equatable {
    var finalizedBy: RowFinalization?
    /// The n-th row of this cold probe kind for this letter and this
    /// participant (R-032); nil for a training row.
    var probeAttempt: Int?
    var delivery: PhaseDelivery?

    init(finalizedBy: RowFinalization? = nil, probeAttempt: Int? = nil, delivery: PhaseDelivery? = nil) {
        self.finalizedBy = finalizedBy
        self.probeAttempt = probeAttempt
        self.delivery = delivery
    }
}

// MARK: - Route-change filter

/// Which `AVAudioSession.RouteChangeReason` raw values count as an audio
/// OUTPUT DEVICE change for the export (batch D; batch C counted every
/// notification). The engine reconfigures its own session per touch, and
/// each of those posts `.categoryChange`; counting them made the column
/// count the app's own activity, not what reached the child's ears.
/// Counted: new device available (1), old device unavailable (2),
/// override (4), no suitable route for the category (7). Not counted:
/// unknown (0), category change (3), wake from sleep (6), route
/// configuration change (8). Raw values, so this stays a pure Core rule.
enum RouteChangeFilter {
    static let countedReasonRawValues: Set<UInt> = [1, 2, 4, 7]

    static func countsAsDeviceChange(reasonRawValue: UInt?) -> Bool {
        guard let reasonRawValue else { return false }
        return countedReasonRawValues.contains(reasonRawValue)
    }
}

// MARK: - Coding helpers

enum DeliveryCoding {
    static func finite(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }
}
