import CoreHaptics
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Protocol

/// Provides haptic feedback for stroke lifecycle events.
/// Conforming types are responsible for determining device capability.
@MainActor
protocol HapticEngineProviding {
    /// Prepare the engine for use (call once, idempotent).
    func prepare()
    /// Fire feedback for a stroke lifecycle event.
    func fire(_ event: HapticEvent)
}

// MARK: - Event type

enum HapticEvent: Equatable {
    /// User placed finger on canvas to start a stroke.
    case strokeBegan
    /// Touch point hit the next checkpoint (on-path confirmation).
    case checkpointHit
    /// All checkpoints in a stroke were completed.
    case strokeCompleted
    /// All strokes completed — letter is done.
    case letterCompleted
    /// Touch was off-path (no checkpoint hit for a sustained gesture).
    case offPath
}

// MARK: - Null engine (tests / unsupported devices)

/// No-op implementation used in unit tests and on devices without haptic support.
final class NullHapticEngine: HapticEngineProviding {
    private(set) var prepareCallCount = 0
    private(set) var firedEvents: [HapticEvent] = []

    func prepare() { prepareCallCount += 1 }
    func fire(_ event: HapticEvent) { firedEvents.append(event) }
    func reset() { firedEvents.removeAll() }
}

// MARK: - UIKit fallback engine

/// Uses UIImpactFeedbackGenerator for devices with Taptic Engine but without
/// CoreHaptics (or when CoreHaptics setup fails).
final class UIKitHapticEngine: HapticEngineProviding {

    private let light  = UIImpactFeedbackGenerator(style: .light)
    private let medium = UIImpactFeedbackGenerator(style: .medium)
    private let heavy  = UIImpactFeedbackGenerator(style: .heavy)
    private let notification = UINotificationFeedbackGenerator()

    func prepare() {
        light.prepare()
        medium.prepare()
        heavy.prepare()
        notification.prepare()
    }

    func fire(_ event: HapticEvent) {
        switch event {
        case .strokeBegan:
            light.impactOccurred()
        case .checkpointHit:
            medium.impactOccurred(intensity: 0.6)
        case .strokeCompleted:
            heavy.impactOccurred()
        case .letterCompleted:
            notification.notificationOccurred(.success)
        case .offPath:
            light.impactOccurred(intensity: 0.3)
        }
    }
}

// MARK: - CoreHaptics engine

/// Production implementation using CoreHaptics for richer, customisable patterns.
/// Falls back gracefully to `UIKitHapticEngine` when CHHapticEngine is unavailable.
@available(iOS 13.0, *)
public final class CoreHapticsEngine: HapticEngineProviding {

    private var engine: CHHapticEngine?
    private let fallback: HapticEngineProviding

    @MainActor public init(fallback: HapticEngineProviding = UIKitHapticEngine()) {
        self.fallback = fallback
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        engine = try? CHHapticEngine()
        engine?.isAutoShutdownEnabled = true
    }

    func prepare() {
        guard let engine else { fallback.prepare(); return }
        try? engine.start()
        fallback.prepare()
    }

    func fire(_ event: HapticEvent) {
        guard let engine, CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            fallback.fire(event)
            return
        }
        guard let pattern = hapticPattern(for: event),
              let player = try? engine.makePlayer(with: pattern) else {
            fallback.fire(event)
            return
        }
        try? engine.start()
        try? player.start(atTime: CHHapticTimeImmediate)
    }

    // MARK: - Pattern definitions

    private func hapticPattern(for event: HapticEvent) -> CHHapticPattern? {
        let events: [CHHapticEvent]
        switch event {
        case .strokeBegan:
            events = [makeTransient(intensity: 0.4, sharpness: 0.3)]
        case .checkpointHit:
            events = [makeTransient(intensity: 0.6, sharpness: 0.7)]
        case .strokeCompleted:
            events = [
                makeTransient(intensity: 0.8, sharpness: 0.5),
                makeTransient(intensity: 0.5, sharpness: 0.3, relativeTime: 0.1)
            ]
        case .letterCompleted:
            events = [
                makeTransient(intensity: 1.0, sharpness: 0.8),
                makeTransient(intensity: 0.8, sharpness: 0.5, relativeTime: 0.12),
                makeTransient(intensity: 0.6, sharpness: 0.3, relativeTime: 0.24)
            ]
        case .offPath:
            events = [makeTransient(intensity: 0.2, sharpness: 0.1)]
        }
        do { return try CHHapticPattern(events: events, parameters: []) } catch { return nil }
    }

    private func makeTransient(
        intensity: Float,
        sharpness: Float,
        relativeTime: TimeInterval = 0
    ) -> CHHapticEvent {
        CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)
            ],
            relativeTime: relativeTime
        )
    }
}
