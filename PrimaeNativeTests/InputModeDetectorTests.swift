import Testing
import Foundation
@testable import PrimaeNative

@Suite @MainActor struct InputModeDetectorTests {

    // MARK: - Initial state

    @Test func initialKind_isFinger() {
        #expect(InputModeDetector().detectedKind == .finger)
        #expect(InputModeDetector().effectiveKind == .finger)
    }

    @Test func initialOverride_isAuto() {
        #expect(InputModeDetector().override == .auto)
    }

    // MARK: - Pencil promotion

    @Test func firstPencilTouch_promotesImmediately() {
        let d = InputModeDetector()
        d.observeTouchBegan(isPencil: true)
        #expect(d.detectedKind == .pencil)
        #expect(d.effectiveKind == .pencil)
    }

    @Test func fingerTouchAlone_doesNotPromote() {
        let d = InputModeDetector()
        d.observeTouchBegan(isPencil: false)
        d.observeTouchBegan(isPencil: false)
        #expect(d.detectedKind == .finger)
    }

    // MARK: - Hysteresis — stray finger during pencil session

    @Test func strayFingerDuringPencilSession_doesNotDemote() {
        let d = InputModeDetector()
        d.observeTouchBegan(isPencil: true)
        d.observeTouchBegan(isPencil: false) // palm rest
        #expect(d.detectedKind == .pencil)
    }

    @Test func sequenceReset_doesNotDemote_whenRecentPencilTouch() {
        let d = InputModeDetector()
        let t0 = Date()
        d.observeTouchBegan(isPencil: true, at: t0)
        // Only 10 seconds later — below the 60s idle threshold.
        d.resetForSequenceChange(at: t0.addingTimeInterval(10))
        #expect(d.detectedKind == .pencil)
    }

    @Test func sequenceReset_doesNotDemote_whenFingerStreakTooShort() {
        let d = InputModeDetector()
        let t0 = Date()
        d.observeTouchBegan(isPencil: true, at: t0)
        // Idle enough — 120s passes — but only 1 finger touch arrives.
        d.observeTouchBegan(isPencil: false, at: t0.addingTimeInterval(90))
        d.resetForSequenceChange(at: t0.addingTimeInterval(120))
        #expect(d.detectedKind == .pencil)
    }

    @Test func sequenceReset_demotes_whenIdleAndFingerStreakMet() {
        let d = InputModeDetector()
        let t0 = Date()
        d.observeTouchBegan(isPencil: true, at: t0)
        let later = t0.addingTimeInterval(120)
        d.observeTouchBegan(isPencil: false, at: later)
        d.observeTouchBegan(isPencil: false, at: later)
        d.observeTouchBegan(isPencil: false, at: later)
        d.resetForSequenceChange(at: later)
        #expect(d.detectedKind == .finger)
    }

    @Test func sequenceReset_hasNoEffect_whenAlreadyFinger() {
        let d = InputModeDetector()
        d.resetForSequenceChange()
        #expect(d.detectedKind == .finger)
    }

    // MARK: - Debug override

    @Test func forceFinger_suppressesPencilPromotion() {
        let d = InputModeDetector()
        d.override = .forceFinger
        d.observeTouchBegan(isPencil: true)
        #expect(d.detectedKind == .pencil)        // underlying detection still flips
        #expect(d.effectiveKind == .finger)       // but the effective kind is forced
    }

    @Test func forcePencil_overridesFingerSession() {
        let d = InputModeDetector()
        d.override = .forcePencil
        #expect(d.effectiveKind == .pencil)
    }

    @Test func revertingOverrideToAuto_restoresDetectedKind() {
        let d = InputModeDetector()
        d.observeTouchBegan(isPencil: true)
        d.override = .forceFinger
        #expect(d.effectiveKind == .finger)
        d.override = .auto
        #expect(d.effectiveKind == .pencil)
    }

    // MARK: - Finger streak resets after pencil touch

    @Test func pencilTouch_resetsFingerStreakCounter() {
        let d = InputModeDetector()
        let t0 = Date()
        d.observeTouchBegan(isPencil: true, at: t0)
        d.observeTouchBegan(isPencil: false, at: t0)
        d.observeTouchBegan(isPencil: false, at: t0)
        // Pencil back in play — streak resets.
        d.observeTouchBegan(isPencil: true, at: t0.addingTimeInterval(90))
        d.observeTouchBegan(isPencil: false, at: t0.addingTimeInterval(91))
        // Reset at a time that would be idle enough, but only one finger
        // touch has accrued since the last pencil — must stay pencil.
        d.resetForSequenceChange(at: t0.addingTimeInterval(200))
        #expect(d.detectedKind == .pencil)
    }
}
