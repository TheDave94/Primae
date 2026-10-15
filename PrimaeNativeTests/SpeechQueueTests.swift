// SpeechQueueTests.swift
// Review of batch C, items 2 and 3 — measured on the study iPad by the
// reviewer's probes P6/P6b, not assumed:
//  - `stopSpeaking(at: .immediate)` issued in the same turn as `speak()`
//    is IGNORED by the system synthesiser (`isSpeaking` is still false):
//    both queued cues still finished, at 2420 / 3741 ms. So the R-071
//    "unconditional stop" stopped nothing, and its test only asserted
//    that a mock had been called.
//  - A cut utterance reports BOTH cancelled and finished (4 reports for
//    2 utterances at 608 ms). The observe start counts cue ends, so the
//    extra "finished" could start a presentation early (R-022).
//
// `AVSpeechSpeechSynthesizer` now hands the system ONE utterance at a
// time and keeps the rest itself, so a stop can drop what has not been
// handed over; an utterance that was handed over before the stop is
// stopped again when the system reports it STARTED (the first moment a
// stop takes effect); and every utterance gets exactly ONE end report,
// matched by identity to the utterance in flight — a duplicate or stale
// report is dropped, and a stopped utterance always reports cancelled.
//
// `DeviceLikeSynthesizer` reproduces the two measured behaviours; the
// device-only probes at the bottom check the real synthesiser.

import Testing
import AVFoundation
@testable import PrimaeNative

/// A system synthesiser double with the measured device behaviour: a stop
/// before anything has STARTED is ignored, and (optionally) a cut
/// utterance reports cancelled and then finished.
final class DeviceLikeSynthesizer: AVSpeechSynthesizer {
    private(set) var queued: [AVSpeechUtterance] = []
    private(set) var speakingNow: AVSpeechUtterance?
    /// Utterances that played to their end.
    private(set) var audible: [String] = []
    private(set) var handedOver = 0
    /// The last utterance that played to its end.
    private(set) var lastFinished: AVSpeechUtterance?
    var doubleReportOnCancel = false

    override var isSpeaking: Bool { speakingNow != nil }
    override func speak(_ utterance: AVSpeechUtterance) {
        handedOver += 1
        queued.append(utterance)
    }
    override func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool {
        guard let cut = speakingNow else { return false }   // measured: ignored before a start
        speakingNow = nil
        let dropped = queued
        queued.removeAll()
        for u in [cut] + dropped { delegate?.speechSynthesizer?(self, didCancel: u) }
        if doubleReportOnCancel { delegate?.speechSynthesizer?(self, didFinish: cut) }
        return true
    }
    /// The system starts the next queued utterance.
    func startNext() {
        guard speakingNow == nil, !queued.isEmpty else { return }
        let u = queued.removeFirst()
        speakingNow = u
        delegate?.speechSynthesizer?(self, didStart: u)
    }
    /// The utterance being spoken plays to its end.
    func finishCurrent() {
        guard let u = speakingNow else { return }
        speakingNow = nil
        audible.append(u.speechString)
        lastFinished = u
        delegate?.speechSynthesizer?(self, didFinish: u)
    }
}

/// A watchdog sleep that ends only when the test says so.
@MainActor
final class ManualSleeper {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    var parked: Int { waiting.count }
    func sleep() async {
        await withCheckedContinuation { waiting.append($0) }
    }
    func wakeAll() {
        let all = waiting
        waiting.removeAll()
        for c in all { c.resume() }
    }
}

/// Records end reports in order.
@MainActor
final class EndReports {
    private(set) var all: [(text: String, cancelled: Bool)] = []
    func attach(to synth: SpeechSynthesizing) {
        synth.setUtteranceEndHandler { [weak self] text, cancelled in self?.all.append((text, cancelled)) }
    }
}

/// The device-only probes run on the physical iPad and nowhere else.
nonisolated let speechQueueOnDevice: Bool = {
    #if targetEnvironment(simulator)
    false
    #else
    true
    #endif
}()

/// Ticks every 10 ms on the main actor and keeps the longest gap
/// between ticks: how late the main actor answered while it ran.
@MainActor
final class MainActorHeartbeat {
    static let starvedMs = 500
    private var maxGapMs = 0
    private var task: Task<Void, Never>?
    init() {
        let clock = ContinuousClock()
        task = Task { @MainActor [weak self] in
            var last = clock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(10))
                let now = clock.now
                let gap = Int((now - last) / .milliseconds(1))
                if let self, gap > self.maxGapMs { self.maxGapMs = gap }
                last = now
            }
        }
    }
    /// Stops the heartbeat; the longest gap seen, in ms.
    func stop() -> Int {
        task?.cancel()
        task = nil
        return maxGapMs
    }
}

@MainActor
private func settle(_ condition: () -> Bool = { false }, polls: Int = 50) async {
    for _ in 0..<polls {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
}

@Suite @MainActor struct SpeechQueueTests {

    private let cue = "Schau genau hin."
    private let next = "Jetzt du."

    /// Waits until the system holds `n` utterances (the hand-over may be
    /// one main-actor turn after `speak`).
    private func handedOver(_ system: DeviceLikeSynthesizer, _ n: Int = 1) async {
        await settle { system.handedOver >= n }
    }

    @Test("a stop after the hand-over but before the system starts the line still silences it (measured: the system ignores such a stop)")
    func stopBeforeTheStartSilences() async {
        let system = DeviceLikeSynthesizer()
        let synth = AVSpeechSpeechSynthesizer(synthesizer: system)
        let reports = EndReports(); reports.attach(to: synth)
        synth.speak(cue)
        await handedOver(system)
        synth.stop()
        system.startNext()                       // the system starts it anyway
        await settle { !reports.all.isEmpty && !system.isSpeaking }
        #expect(!system.isSpeaking, "the stopped cue is still being spoken")
        system.finishCurrent()
        await settle()
        #expect(system.audible.isEmpty, "the stopped cue played to its end: \(system.audible)")
        #expect(reports.all.map(\.cancelled) == [true], "reports: \(reports.all)")
    }

    @Test("what is queued behind it is dropped by the stop and never handed to the system")
    func queuedBehindIsDropped() async {
        let system = DeviceLikeSynthesizer()
        let synth = AVSpeechSpeechSynthesizer(synthesizer: system)
        let reports = EndReports(); reports.attach(to: synth)
        synth.speak(cue)
        synth.speak(cue)
        await handedOver(system)
        synth.stop()
        system.startNext()
        await settle { reports.all.count >= 2 && !system.isSpeaking }
        system.startNext()
        system.finishCurrent()
        await settle()
        #expect(system.audible.isEmpty, "a stopped cue was heard: \(system.audible)")
        #expect(reports.all.count == 2 && reports.all.allSatisfy(\.cancelled), "reports: \(reports.all)")
    }

    @Test("the prompt pattern — stop, then speak — plays the new line once the stopped one is gone")
    func stopThenSpeakPlaysTheNewLine() async {
        let system = DeviceLikeSynthesizer()
        let synth = AVSpeechSpeechSynthesizer(synthesizer: system)
        let reports = EndReports(); reports.attach(to: synth)
        synth.speak(cue)
        await handedOver(system)
        synth.stop()
        synth.speak(next)
        system.startNext()                       // the stopped cue starts…
        await settle { !reports.all.isEmpty && system.queued.count + (system.isSpeaking ? 1 : 0) > 0 }
        system.startNext()                       // …is stopped; the new line follows
        system.finishCurrent()
        await settle { reports.all.count >= 2 }
        #expect(system.audible == [next], "audible: \(system.audible)")
        #expect(reports.all.map(\.text) == [cue, next] && reports.all.map(\.cancelled) == [true, false],
                "reports: \(reports.all)")
    }

    @Test("a cut utterance that reports cancelled AND finished is reported once, as cancelled (R-022)")
    func doubleReportIsReportedOnce() async {
        let system = DeviceLikeSynthesizer()
        system.doubleReportOnCancel = true
        let synth = AVSpeechSpeechSynthesizer(synthesizer: system, lineBudget: { _ in 60.0 })
        let reports = EndReports(); reports.attach(to: synth)
        synth.speak(cue)
        await handedOver(system)
        system.startNext()
        await settle()
        synth.stop()
        await settle { reports.all.count >= 2 }
        #expect(reports.all.count == 1 && reports.all.first?.cancelled == true,
                "one utterance, \(reports.all.count) end reports: \(reports.all)")
    }

    @Test("the cut line's late 'finished' does not end the line that followed it (R-022)")
    func lateReportOfTheCutLineDoesNotEndTheNext() async {
        let system = DeviceLikeSynthesizer()
        system.doubleReportOnCancel = true
        let synth = AVSpeechSpeechSynthesizer(synthesizer: system, lineBudget: { _ in 60.0 })
        let reports = EndReports(); reports.attach(to: synth)
        synth.speak(cue)
        await handedOver(system)
        system.startNext()
        await settle()
        synth.stop()                             // cancelled, then a late finished, for the cue
        synth.speak(next)                        // handed over once the cue's first report lands
        await settle { reports.all.count >= 2 }
        #expect(reports.all.count == 1 && reports.all.first?.text == cue,
                "the next line was reported ended before it was spoken: \(reports.all)")
        system.startNext()
        system.finishCurrent()
        await settle { reports.all.count >= 2 }
        #expect(system.audible == [next], "audible: \(system.audible)")
        #expect(reports.all.map(\.text) == [cue, next] && reports.all.map(\.cancelled) == [true, false],
                "reports: \(reports.all)")
    }

    // MARK: Delta review of batch C

    @Test("a stop in the same turn as speak() drops the line before the system ever gets it (item 4, reviewer P7)")
    func sameTurnStopNeverReachesTheSystem() async {
        let system = DeviceLikeSynthesizer()
        let synth = AVSpeechSpeechSynthesizer(synthesizer: system)
        let reports = EndReports(); reports.attach(to: synth)
        synth.speak(cue)
        synth.stop()
        await settle { !reports.all.isEmpty }
        await settle()
        #expect(system.handedOver == 0, "the stopped line was handed to the system (an audible start)")
        #expect(reports.all.map(\.text) == [cue] && reports.all.map(\.cancelled) == [true],
                "reports: \(reports.all)")
    }

    @Test("lines dropped by a stop report AFTER the line in flight, in the order they were spoken (item 3)")
    func endReportsKeepTheSpokenOrder() async {
        let system = DeviceLikeSynthesizer()
        let synth = AVSpeechSpeechSynthesizer(synthesizer: system)
        let reports = EndReports(); reports.attach(to: synth)
        let third = "Noch einmal."
        synth.speak(cue)
        await handedOver(system)
        system.startNext()
        synth.speak(next)
        synth.speak(third)
        synth.stop()
        await settle { reports.all.count >= 3 }
        #expect(reports.all.map(\.text) == [cue, next, third], "reports: \(reports.all)")
        #expect(reports.all.map(\.cancelled) == [true, true, true], "reports: \(reports.all)")
    }

    @Test("a line the system never reports on is released, so later lines are not held forever (item 2)")
    func unreportedLineIsReleased() async {
        let system = DeviceLikeSynthesizer()             // never starts, never reports
        let synth = AVSpeechSpeechSynthesizer(synthesizer: system, lineBudget: { _ in 0.2 })
        let reports = EndReports(); reports.attach(to: synth)
        synth.speak(cue)
        synth.speak(next)
        await settle({ system.handedOver >= 2 }, polls: 150)
        #expect(system.handedOver == 2, "the next line is still waiting behind a line nobody reported")
        #expect(reports.all.map(\.text) == [cue] && reports.all.map(\.cancelled) == [true],
                "reports: \(reports.all)")
    }

    /// Measured in the full suite on the device: the main actor stalled
    /// ~123 s, the line's budget ran out during the stall, and the
    /// watchdog's wake ran ahead of the system's queued "finished" report,
    /// so a line that had played was reported cancelled.
    ///
    /// The order is FORCED, not hoped for: the system's report is made
    /// from inside the watchdog's sleep, after the wake and before the
    /// watchdog's check, in one main-actor turn (the seam is @MainActor, so
    /// no hop separates the two). The relay has then recorded the report
    /// but its main-actor hand-off cannot run until the watchdog has
    /// looked: exactly the stalled-main-actor state. (Queue order alone
    /// does not do it: with `wakeAll(); finishCurrent()` the report's job
    /// ran first and the guard was never reached; mutation-checked.)
    @Test("the watchdog does not release a line the system has already reported, even when it wakes first (item 2)")
    func watchdogYieldsToAReportAlreadyMade() async {
        let system = DeviceLikeSynthesizer()
        let sleeper = ManualSleeper()
        let synth = AVSpeechSpeechSynthesizer(synthesizer: system, watchdogSleep: { _ in
            await sleeper.sleep()
            system.finishCurrent()      // the budget ran out, and the system reports now
        })
        let reports = EndReports(); reports.attach(to: synth)
        synth.speak(next)
        await handedOver(system)
        await settle { sleeper.parked > 0 }
        #expect(sleeper.parked == 1, "precondition: the hand-over armed the watchdog")
        system.startNext()
        sleeper.wakeAll()
        await settle { !reports.all.isEmpty }
        await settle()
        #expect(system.audible == [next], "the system's report was never made: \(system.audible)")
        #expect(reports.all.map(\.text) == [next] && reports.all.map(\.cancelled) == [false],
                "a line that played to its end was reported cancelled: \(reports.all)")
    }

    @Test("a second report for an utterance that already ended is dropped")
    func staleReportIsDropped() async {
        let system = DeviceLikeSynthesizer()
        let synth = AVSpeechSpeechSynthesizer(synthesizer: system)
        let reports = EndReports(); reports.attach(to: synth)
        synth.speak(cue)
        await handedOver(system)
        system.startNext()
        await settle()
        system.finishCurrent()
        await settle { !reports.all.isEmpty }
        // A late, second report for the same utterance.
        if let ended = system.lastFinished {
            system.delegate?.speechSynthesizer?(system, didFinish: ended)
        }
        await settle { reports.all.count >= 2 }
        #expect(reports.all.count == 1, "reports: \(reports.all)")
    }

    // MARK: - On the device, with the real synthesiser
    //
    // The stop lands when the system's "started" report reaches the main
    // actor, and the end reports are timed there. In the full suite ~1,270
    // tests share the main actor and it answers minutes late (measured:
    // a cue's report at 165 s), so a time bound measures the suite, not
    // the stop. The probes therefore time a heartbeat on the main actor
    // and apply the time bound only when it never stalled for longer than
    // `starvedMs`; otherwise they say so. The structural checks always
    // apply.

    /// Reviewer probe P6, as a regression test: two cues queued and
    /// stopped in the same turn used to finish at 2420 / 3741 ms.
    @Test("device: speak, speak, stop at once — nothing is heard, both report cancelled",
          .enabled(if: speechQueueOnDevice))
    func deviceStopInTheSameTurn() async {
        let synth = AVSpeechSpeechSynthesizer()
        let clock = ContinuousClock()
        let t0 = clock.now
        var reports: [(cancelled: Bool, ms: Int)] = []
        synth.setUtteranceEndHandler { _, cancelled in
            reports.append((cancelled, Int((clock.now - t0) / .milliseconds(1))))
        }
        let beat = MainActorHeartbeat()
        synth.speak(cue)
        synth.speak(cue)
        synth.stop()
        await settle({ reports.count >= 2 }, polls: 800)
        try? await Task.sleep(for: .milliseconds(3000))       // anything still playing would report by now
        let gap = beat.stop()
        print("SPEECHQUEUE-DEVICE same-turn stop: \(reports) main-actor max gap \(gap) ms")
        #expect(reports.count == 2 && reports.allSatisfy(\.cancelled), "reports: \(reports)")
        if gap <= MainActorHeartbeat.starvedMs {
            #expect((reports.map(\.ms).max() ?? .max) < 1500,
                    "a stopped cue was spoken to its end (a full cue takes ~2.4 s): \(reports)")
        } else {
            print("SPEECHQUEUE-DEVICE same-turn stop: time bound NOT applied, main actor stalled \(gap) ms")
        }
    }

    /// Since the hand-over moved one turn later (delta item 4), the two
    /// probes around this one stop lines the system never received. This
    /// one stops a line the system HAS: spoken for ~150 ms, then stopped.
    @Test("device: a stop after the system has started the line cuts it at once",
          .enabled(if: speechQueueOnDevice))
    func deviceStopAfterTheStart() async {
        let synth = AVSpeechSpeechSynthesizer()
        let clock = ContinuousClock()
        let t0 = clock.now
        var reports: [(cancelled: Bool, ms: Int)] = []
        synth.setUtteranceEndHandler { _, cancelled in
            reports.append((cancelled, Int((clock.now - t0) / .milliseconds(1))))
        }
        let beat = MainActorHeartbeat()
        synth.speak(cue)
        try? await Task.sleep(for: .milliseconds(150))
        synth.stop()
        await settle({ reports.count >= 1 }, polls: 800)
        try? await Task.sleep(for: .milliseconds(3000))
        let gap = beat.stop()
        print("SPEECHQUEUE-DEVICE stop-after-start: \(reports) main-actor max gap \(gap) ms")
        #expect(reports.count == 1 && reports.first?.cancelled == true, "reports: \(reports)")
        if gap <= MainActorHeartbeat.starvedMs {
            #expect((reports.first?.ms ?? .max) < 1500, "the stopped cue was spoken to its end: \(reports)")
        } else {
            print("SPEECHQUEUE-DEVICE stop-after-start: time bound NOT applied, main actor stalled \(gap) ms")
        }
    }

    @Test("device: the prompt pattern — stop then speak — speaks only the new line, once",
          .enabled(if: speechQueueOnDevice))
    func deviceStopThenSpeak() async {
        let synth = AVSpeechSpeechSynthesizer()
        let clock = ContinuousClock()
        let t0 = clock.now
        var reports: [(text: String, cancelled: Bool, ms: Int)] = []
        synth.setUtteranceEndHandler { text, cancelled in
            reports.append((text, cancelled, Int((clock.now - t0) / .milliseconds(1))))
        }
        let beat = MainActorHeartbeat()
        synth.speak(cue)
        synth.stop()
        synth.speak(next)
        await settle({ reports.count >= 2 }, polls: 800)
        try? await Task.sleep(for: .milliseconds(1500))
        let gap = beat.stop()
        print("SPEECHQUEUE-DEVICE stop-then-speak: \(reports) main-actor max gap \(gap) ms")
        #expect(reports.map(\.text) == [cue, next], "reports: \(reports)")
        #expect(reports.map(\.cancelled) == [true, false], "reports: \(reports)")
        if gap <= MainActorHeartbeat.starvedMs {
            #expect((reports.first?.ms ?? .max) < 1500, "the stopped cue was spoken to its end: \(reports)")
        } else {
            print("SPEECHQUEUE-DEVICE stop-then-speak: time bound NOT applied, main actor stalled \(gap) ms")
        }
        // "Jetzt du." takes ~1.9 s. A report for it within 500 ms of the
        // cue's is the cut cue's own late "finished" ending it (measured
        // on the device with the identity check removed: both at 239 ms).
        // Holds under a starved main actor too: the new line is handed
        // over only after the cue's report has run there.
        if reports.count == 2 {
            #expect(reports[1].ms - reports[0].ms > 500,
                    "the new line was reported ended before it could have been spoken: \(reports)")
        }
    }
}
