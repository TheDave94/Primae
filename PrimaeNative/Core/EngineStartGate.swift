// EngineStartGate.swift
// PrimaeNative — SDK27 (2026-11-24, seat ruling 1)
//
// The ONE place the shared AVAudioEngine (AudioEngine's graph, which also
// hosts the r17 live voice's source node) is started. Every start is ordered
// after iOS 27's asynchronous `AVAudioSession.activate(options:)` has
// completed; nothing on the main thread blocks on a session activation.
//
// Before this type there were three start sites: `AudioEngine.init` (already
// async), `AudioEngine.startIfNeeded` and `SourceNodeOutput.startIfNeeded`
// (both a synchronous `setActive(true)` then `engine.start()`). On the iPad a
// cold launch's first sound reached a synchronous site before init's
// activation had returned (capture `engine.firstStart alreadyRunning=true`),
// so the engine started on a session the async activation had not finished,
// and Xcode reported the main-thread activation as "UI unresponsiveness".
//
// The contract the synchronous sites kept (the 2026-09-15 fix: a caller that
// asked for a start must not abandon its play) is kept here as a
// CONTINUATION: `whenRunning` runs its closure now when the engine already
// runs (the per-touch hot path, unchanged), and otherwise once the
// activation and the start have completed. Requests that arrive while an
// activation is in flight join it; the engine is started once. The session
// configuration (`setCategory`, which has no asynchronous form) runs off the
// main thread before each activation, so no session call blocks the main
// thread (measured on the iPad before this: one SessionCore "Hang Risk" per
// engine constructed into an active, differently configured session).

import AVFoundation
import Foundation
import OSLog

@MainActor
final class EngineStartGate {

    /// The engine and session operations the gate orders. Production:
    /// `AVAudioSession` + the shared `AVAudioEngine`; tests: fakes (the
    /// simulator cannot run AVAudioEngine).
    struct Operations {
        /// The session configuration (category, mode, options), OFF the main
        /// thread: `setCategory` has no asynchronous form, and on the main
        /// thread while the session is active it is a runtime "Hang Risk".
        /// Runs before every activation; a no-op when already configured.
        var prepare: @MainActor () async throws -> Void
        /// The asynchronous session activation (iOS 27 `activate(options:)`).
        var activate: @MainActor () async throws -> Void
        var isRunning: @MainActor () -> Bool
        var start: @MainActor () throws -> Void
    }

    private let ops: Operations
    private var activation: Task<Void, Never>?
    /// Session work outside an activation (the route-change IO buffer),
    /// chained: each runs after the work and the activation before it, and an
    /// activation begun later waits for it. One order for every session call.
    private var sessionWork: Task<Void, Never>?
    private var waiters: [@MainActor () -> Void] = []
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "PrimaeNative",
                             category: "EngineStartGate")

    /// Called when a start throws (AudioEngine resets its player state and,
    /// for the launch start, raises the init toast).
    var onStartFailure: (@MainActor (Error) -> Void)?
    /// Called when the session configuration throws; no activation and no
    /// start follow, and the requests are dropped (AudioEngine raises the
    /// "Audio nicht verfügbar" toast, as the synchronous configuration did).
    var onPrepareFailure: (@MainActor (Error) -> Void)?

    /// Starts performed by this gate, each after a completed activation.
    private(set) var startCount = 0
    /// Activations begun (one per not-running period, however many requests).
    private(set) var activationCount = 0

    init(operations: Operations) { self.ops = operations }

    /// True while an activation is in flight and the start has not happened.
    var isStarting: Bool { activation != nil }

    /// Run `then` once the engine is running: immediately when it already
    /// runs; otherwise after the configuration, the asynchronous activation
    /// and the start. Dropped (not run) when the configuration or the start
    /// fails, exactly as the synchronous sites returned without playing then.
    func whenRunning(_ then: (@MainActor () -> Void)? = nil) {
        if ops.isRunning() { then?(); return }
        if let then { waiters.append(then) }
        guard activation == nil else { return }
        activationCount += 1
        let prior = sessionWork
        activation = Task { [weak self] in
            await prior?.value
            await self?.activateThenStart()
        }
    }

    /// Runs `work` (a session call with no asynchronous form, e.g.
    /// `setPreferredIOBufferDuration`) OFF the main thread, after any session
    /// work and any activation already in flight; an activation begun after
    /// this call waits for it. On the main thread while the session is active
    /// such a call is a runtime "Hang Risk" (TESTWARN's device runs: the
    /// route-change IO buffer, `SoundEnvelope.applyPreferredIOBuffer`).
    func performSessionWork(_ work: @escaping @Sendable () -> Void) {
        let prior = sessionWork, pendingActivation = activation
        sessionWork = Task {
            await prior?.value
            await pendingActivation?.value
            await Task.detached(priority: .userInitiated) { work() }.value
        }
    }

    /// Awaits the activation and the session work in flight, if any (tests,
    /// and the cold-launch readiness check).
    func settle() async {
        await activation?.value
        await sessionWork?.value
    }

    private func activateThenStart() async {
        #if DEBUG || POPCAP
        let t0 = PopCapture.nowNs()
        #endif
        do {
            try await ops.prepare()
        } catch {
            log.error("Audio session configuration failed: \(error.localizedDescription, privacy: .public)")
            #if DEBUG || POPCAP
            PopCapture.armed?.event("session.configure", "ok=false error=\(error.localizedDescription)")
            #endif
            activation = nil
            waiters = []
            onPrepareFailure?(error)
            return
        }
        do {
            try await ops.activate()
            #if DEBUG || POPCAP
            PopCapture.armed?.event("session.activate", "ok=true ms=\(Double(PopCapture.nowNs() - t0) / 1e6)")
            #endif
        } catch {
            // Logged, then the start is still attempted: the synchronous sites
            // fell through to `engine.start()` after a failed activation too.
            log.error("Failed to activate audio session: \(error.localizedDescription, privacy: .public)")
            #if DEBUG || POPCAP
            PopCapture.armed?.event("session.activate", "ok=false error=\(error.localizedDescription)")
            #endif
        }
        activation = nil
        let pending = waiters
        waiters = []
        // `alreadyRunning=true` here would mean something started the engine
        // OUTSIDE this gate during the activation: the race this type removes.
        #if DEBUG || POPCAP
        PopCapture.armed?.event("engine.gateStart", "alreadyRunning=\(ops.isRunning()) waiters=\(pending.count)")
        #endif
        if !ops.isRunning() {
            do {
                try ops.start()
                startCount += 1
            } catch {
                log.error("Engine failed to start: \(error.localizedDescription, privacy: .public)")
                onStartFailure?(error)
                return
            }
        }
        guard ops.isRunning() else { return }
        for w in pending { w() }
    }
}

extension EngineStartGate {
    /// The production gate for `engine` on the shared session.
    /// `sessionPreparation` (the r17 IO buffer, `SoundEnvelope.makeHostEngine`)
    /// runs in the same off-main prepare, before the configuration, so it is
    /// set before every activation and therefore before the first start.
    static func production(for engine: AVAudioEngine,
                           sessionPreparation: (@Sendable () -> Void)? = nil) -> EngineStartGate {
        EngineStartGate(operations: Operations(
            prepare: offMain {
                sessionPreparation?()
                try AudioEngine.configureSessionIfNeeded()
            },
            activate: { _ = try await AVAudioSession.sharedInstance().activate(options: []) },
            isRunning: { engine.isRunning },
            start: { try engine.start() }
        ))
    }

    /// Runs `work` on a detached task, never the main thread: the session
    /// configuration has no asynchronous form, and `setCategory` on the main
    /// thread while the session is active is a runtime "Hang Risk".
    nonisolated static func offMain(_ work: @escaping @Sendable () throws -> Void)
        -> @MainActor () async throws -> Void {
        { try await Task.detached(priority: .userInitiated) { try work() }.value }
    }
}
