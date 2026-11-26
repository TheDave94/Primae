// AudioSessionInterruptionTests.swift
// PrimaeNativeTests: SDK27 (2026-11-24)
//
// Pins `AudioSessionInterruption`, the one reader of iOS 27's
// didBecomeInactive / resumptionRecommendation pair that both `AudioEngine`
// and `LiveSonificationAudio` act on (r16 B1/C2: stop on an interruption,
// resume only when the system recommends it). The value decisions first,
// then the same decisions through genuine posted notifications
// (`ForgedSessionNotifications`), then the live voice's observer end to end.

import Testing
import Foundation
import AVFoundation
@testable import PrimaeNative

@Suite("SDK27 audio-session interruption mapping")
@MainActor struct AudioSessionInterruptionTests {

    @Test("a system deactivation begins an interruption; the app's own does not; no context fails safe")
    func deactivationValues() {
        #expect(AudioSessionInterruption(deactivatedBySystem: true) == .began)
        #expect(AudioSessionInterruption(deactivatedBySystem: false) == nil)
        #expect(AudioSessionInterruption(deactivatedBySystem: nil) == .began)
    }

    @Test("resume only on a shouldResume recommendation; no context means do not resume")
    func resumptionValues() {
        #expect(AudioSessionInterruption(resumptionRecommended: true) == .ended(shouldResume: true))
        #expect(AudioSessionInterruption(resumptionRecommended: false) == .ended(shouldResume: false))
        #expect(AudioSessionInterruption(resumptionRecommended: nil) == .ended(shouldResume: false))
    }

    @Test("the observed names are exactly the iOS 27 pair")
    func names() {
        #expect(AudioSessionInterruption.notificationNames == [
            AVAudioSession.didBecomeInactiveNotification,
            AVAudioSession.resumptionRecommendationNotification,
        ])
    }

    @Test("genuine context objects: the forgery reads back through the public getters")
    func forgeryIsGenuine() throws {
        let d = try #require(ForgedSessionNotifications.deactivationContext(source: .system))
        #expect(d.source == .system)
        #expect(d.interruptionContext == nil)
        let a = try #require(ForgedSessionNotifications.deactivationContext(source: .app))
        #expect(a.source == .app)
        let r = try #require(ForgedSessionNotifications.resumptionContext(.shouldResume))
        #expect(r.recommendation == .shouldResume)
        let n = try #require(ForgedSessionNotifications.resumptionContext(.shouldNotResume))
        #expect(n.recommendation == .shouldNotResume)
    }

    @Test("notifications map through their context objects")
    func notifications() throws {
        let sys = try #require(ForgedSessionNotifications.inactive(source: .system))
        #expect(AudioSessionInterruption(sys) == .began)
        let app = try #require(ForgedSessionNotifications.inactive(source: .app))
        #expect(AudioSessionInterruption(app) == nil)
        let bare = try #require(ForgedSessionNotifications.inactive(source: nil))
        #expect(AudioSessionInterruption(bare) == .began)
        let yes = try #require(ForgedSessionNotifications.resumption(.shouldResume))
        #expect(AudioSessionInterruption(yes) == .ended(shouldResume: true))
        let no = try #require(ForgedSessionNotifications.resumption(.shouldNotResume))
        #expect(AudioSessionInterruption(no) == .ended(shouldResume: false))
        let none = try #require(ForgedSessionNotifications.resumption(nil))
        #expect(AudioSessionInterruption(none) == .ended(shouldResume: false))
        let other = Notification(name: AVAudioSession.routeChangeNotification)
        #expect(AudioSessionInterruption(other) == nil)
    }

    /// The live voice's own observer, driven by posted notifications: a system
    /// deactivation silences it, an app deactivation does not, and only a
    /// shouldResume recommendation brings it back.
    @Test("the live voice observes the iOS 27 pair end to end")
    func liveVoiceObserves() async throws {
        let center = NotificationCenter()   // private: a forged post reaches no other suite's voice
        let output = FakeLiveOutput()
        let host = HostSpy()
        let src = LiveSonificationAudioTests.tone("a")
        let voice = LiveSonificationAudio(host: host, output: output, kernel: LiveSonificationKernel(),
                                          fadeOutSeconds: 0.05, observeSession: true,
                                          notificationCenter: center,
                                          resolve: { $0 == "a" ? src : nil })
        voice.loadAudioFile(named: "a", autoplay: true)
        #expect(voice.isPlaying)

        #expect(ForgedSessionNotifications.post(ForgedSessionNotifications.inactive(source: .app), to: center))
        try await Self.settle()
        #expect(voice.isPlaying, "the app's own deactivation is not an interruption")
        #expect(!voice.interrupted)

        #expect(ForgedSessionNotifications.post(ForgedSessionNotifications.inactive(source: .system), to: center))
        try await Self.settle()
        #expect(!voice.isPlaying, "a system deactivation must silence the voice (B1)")
        #expect(voice.interrupted)
        #expect(voice.loadedKey == "a")

        #expect(ForgedSessionNotifications.post(ForgedSessionNotifications.resumption(.shouldNotResume), to: center))
        try await Self.settle()
        #expect(!voice.isPlaying, "shouldNotResume must stay silent")
        #expect(!voice.interrupted)

        // A second interruption while silent captures no resume intent (C2), so
        // the child's next play comes first, as after any shouldNotResume.
        voice.play()
        #expect(voice.isPlaying)
        #expect(ForgedSessionNotifications.post(ForgedSessionNotifications.inactive(source: .system), to: center))
        try await Self.settle()
        #expect(!voice.isPlaying)
        #expect(ForgedSessionNotifications.post(ForgedSessionNotifications.resumption(.shouldResume), to: center))
        try await Self.settle()
        #expect(voice.isPlaying, "a shouldResume recommendation must resume")
    }

    /// The observers are `for await` sequences on the main actor: give them a turn.
    static func settle() async throws {
        for _ in 0..<5 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(80))
    }
}
