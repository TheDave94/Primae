import CoreHaptics
import UIKit
import Foundation

// MARK: - HapticEvent

enum HapticEvent {
case strokeBegan
case checkpointHit
case strokeCompleted
case letterCompleted
}

// MARK: - HapticEngineProviding

protocol HapticEngineProviding {
func prepare()
func fire(_ event: HapticEvent, tier: DifficultyTier)
}

extension HapticEngineProviding {
/// Convenience overload that defaults to .standard when tier is not relevant.
func fire(_ event: HapticEvent) { fire(event, tier: .standard) }
}

// MARK: - Intensity / Sharpness tables

private struct HapticPattern {
let intensity: Float
let sharpness: Float
}

private extension DifficultyTier {
/// Checkpoint-hit pattern: harder tiers give crisper, lighter taps;
/// easier tiers give softer, rounder pulses.
var checkpointPattern: HapticPattern {
switch self {
case .easy: return HapticPattern(intensity: 0.40, sharpness: 0.20)
case .standard: return HapticPattern(intensity: 0.60, sharpness: 0.50)
case .precise: return HapticPattern(intensity: 0.80, sharpness: 0.90)
}
}

/// Stroke-completion pattern: a slightly longer, more pronounced pulse.
var strokeCompletedPattern: HapticPattern {
switch self {
case .easy: return HapticPattern(intensity: 0.55, sharpness: 0.25)
case .standard: return HapticPattern(intensity: 0.75, sharpness: 0.55)
case .precise: return HapticPattern(intensity: 0.95, sharpness: 0.95)
}
}
}

// MARK: - CoreHapticsEngine

final class CoreHapticsEngine: HapticEngineProviding {

private var engine: CHHapticEngine?
private var supportsHaptics: Bool { CHHapticEngine.capabilitiesForHardware().supportsHaptics }

// Fallback generators for older / non-haptic devices
private let impactLight = UIImpactFeedbackGenerator(style: .light)
private let impactMedium = UIImpactFeedbackGenerator(style: .medium)
private let impactHeavy = UIImpactFeedbackGenerator(style: .heavy)
private let notifyGen = UINotificationFeedbackGenerator()

func prepare() {
impactLight.prepare()
impactMedium.prepare()
impactHeavy.prepare()
notifyGen.prepare()
guard supportsHaptics else { return }
do {
let e = try CHHapticEngine()
e.playsHapticsOnly = true
e.stoppedHandler = { [weak self] _ in
try? self?.engine?.start()
}
e.resetHandler = { [weak self] in
try? self?.engine?.start()
}
try e.start()
engine = e
} catch {
engine = nil
}
}

func fire(_ event: HapticEvent, tier: DifficultyTier = .standard) {
switch event {
case .strokeBegan:
playOrFallback(
pattern: HapticPattern(intensity: 0.30, sharpness: 0.40),
duration: 0.06,
fallback: { self.impactLight.impactOccurred(intensity: 0.5) })

case .checkpointHit:
let p = tier.checkpointPattern
playOrFallback(
pattern: p,
duration: 0.08,
fallback: { self.impactLight.impactOccurred(intensity: CGFloat(p.intensity)) })

case .strokeCompleted:
let p = tier.strokeCompletedPattern
playOrFallback(
pattern: p,
duration: 0.14,
fallback: { self.impactMedium.impactOccurred(intensity: CGFloat(p.intensity)) })

case .letterCompleted:
if supportsHaptics, let engine {
playLetterCompletedPattern(engine: engine)
} else {
notifyGen.notificationOccurred(.success)
}
}
}

// MARK: Private

private func playOrFallback(
pattern: HapticPattern,
duration: TimeInterval,
fallback: () -> Void
) {
guard supportsHaptics, let engine else { fallback(); return }
do {
let intensityParam = CHHapticEventParameter(
parameterID: .hapticIntensity, value: pattern.intensity)
let sharpnessParam = CHHapticEventParameter(
parameterID: .hapticSharpness, value: pattern.sharpness)
let hapticEvent = CHHapticEvent(
eventType: .hapticTransient,
parameters: [intensityParam, sharpnessParam],
relativeTime: 0,
duration: duration)
let chPattern = try CHHapticPattern(events: [hapticEvent], parameters: [])
let player = try engine.makePlayer(with: chPattern)
try player.start(atTime: CHHapticTimeImmediate)
} catch {
fallback()
}
}

/// Three-pulse "fanfare" for letter completion.
private func playLetterCompletedPattern(engine: CHHapticEngine) {
let pulses: [(time: TimeInterval, intensity: Float, sharpness: Float)] = [
(0.00, 0.60, 0.50),
(0.12, 0.80, 0.70),
(0.24, 1.00, 0.90),
]
do {
let events: [CHHapticEvent] = pulses.map { p in
CHHapticEvent(
eventType: .hapticTransient,
parameters: [
CHHapticEventParameter(parameterID: .hapticIntensity, value: p.intensity),
CHHapticEventParameter(parameterID: .hapticSharpness, value: p.sharpness),
],
relativeTime: p.time,
duration: 0.10)
}
let chPattern = try CHHapticPattern(events: events, parameters: [])
let player = try engine.makePlayer(with: chPattern)
try player.start(atTime: CHHapticTimeImmediate)
} catch {
notifyGen.notificationOccurred(.success)
}
}
}
