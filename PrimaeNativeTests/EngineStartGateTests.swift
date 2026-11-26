// EngineStartGateTests.swift
// PrimaeNativeTests — SDK27 (2026-11-24, seat ruling 1)
//
// The ordering `EngineStartGate` guarantees, with fake operations (the
// simulator cannot run AVAudioEngine): the engine is never started before the
// asynchronous session activation has COMPLETED; requests made during an
// activation join it (one activation, one start) and run in order once the
// engine runs; a running engine runs the request at once (the per-touch hot
// path); a failed configuration or start drops the request. The session
// configuration runs before every activation.
// The device halves (a real cold AudioEngine and a real live voice) are in
// AudioEngineTests.

import Testing
import Foundation
import Synchronization
@testable import PrimaeNative

@MainActor
final class FakeStartOps {
    var running = false
    var prepareThrows = false
    var startThrows = false
    var log: [String] = []
    private var release: CheckedContinuation<Void, Never>?
    private(set) var activationsBegun = 0

    /// Completes the activation in flight.
    func finishActivation() { release?.resume(); release = nil }

    var operations: EngineStartGate.Operations {
        EngineStartGate.Operations(
            prepare: { [unowned self] in
                self.log.append("prepare")
                if self.prepareThrows { throw CocoaError(.featureUnsupported) }
            },
            activate: { [unowned self] in
                self.activationsBegun += 1
                self.log.append("activate.begin")
                await withCheckedContinuation { self.release = $0 }
                self.log.append("activate.end")
            },
            isRunning: { [unowned self] in self.running },
            start: { [unowned self] in
                self.log.append("start")
                if self.startThrows { throw CocoaError(.featureUnsupported) }
                self.running = true
            })
    }
}

@Suite("SDK27: the engine starts only after the asynchronous activation")
@MainActor struct EngineStartGateTests {

    /// Lets the gate's task reach its `await` (or finish after a release).
    private func yieldMain(_ n: Int = 5) async { for _ in 0..<n { await Task.yield() } }

    /// CPU time (user + system, µs) the thread behind `port` has used, or
    /// nil if it cannot be read.
    nonisolated private static func cpuMicros(_ port: thread_act_t) -> Int64? {
        var info = thread_basic_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(port, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let t = info.user_time, u = info.system_time
        return Int64(t.seconds + u.seconds) * 1_000_000 + Int64(t.microseconds + u.microseconds)
    }

    @Test("the start waits for the activation to COMPLETE, then the request runs")
    func startFollowsCompletedActivation() async {
        let ops = FakeStartOps()
        let gate = EngineStartGate(operations: ops.operations)
        var ran: [String] = []
        gate.whenRunning { ran.append("play") }
        #expect(!ops.running, "the engine started synchronously, before the activation")
        #expect(ran.isEmpty)
        await yieldMain()
        #expect(ops.log == ["prepare", "activate.begin"], "the start overtook the activation in flight: \(ops.log)")
        #expect(!ops.running)
        ops.finishActivation()
        await gate.settle()
        #expect(ops.log == ["prepare", "activate.begin", "activate.end", "start"])
        #expect(ran == ["play"])
        #expect(gate.startCount == 1)
    }

    @Test("requests during one activation join it: one activation, one start, run in order")
    func requestsJoinOneActivation() async {
        let ops = FakeStartOps()
        let gate = EngineStartGate(operations: ops.operations)
        var ran: [Int] = []
        gate.whenRunning()                 // the launch start
        gate.whenRunning { ran.append(1) } // a load's play
        await yieldMain()
        gate.whenRunning { ran.append(2) } // a play during the activation
        #expect(gate.isStarting)
        ops.finishActivation()
        await gate.settle()
        #expect(ops.activationsBegun == 1)
        #expect(ops.log.filter { $0 == "start" }.count == 1)
        #expect(gate.activationCount == 1)
        #expect(ran == [1, 2])
    }

    @Test("a running engine runs the request at once, with no activation (the per-touch path)")
    func runningEngineRunsNow() async {
        let ops = FakeStartOps()
        ops.running = true
        let gate = EngineStartGate(operations: ops.operations)
        var ran = false
        gate.whenRunning { ran = true }
        #expect(ran)
        #expect(!gate.isStarting)
        #expect(ops.log.isEmpty)
    }

    @Test("a failed configuration reports it, begins no activation and no start, and drops the request")
    func failedPrepareDrops() async {
        let ops = FakeStartOps()
        ops.prepareThrows = true
        let gate = EngineStartGate(operations: ops.operations)
        var failures = 0
        gate.onPrepareFailure = { _ in failures += 1 }
        var ran = false
        gate.whenRunning { ran = true }
        await gate.settle()
        #expect(failures == 1)
        #expect(!gate.isStarting)
        #expect(ops.log == ["prepare"])
        #expect(!ran)
        ops.prepareThrows = false
        gate.whenRunning { ran = true }
        await yieldMain()
        ops.finishActivation()
        await gate.settle()
        #expect(ran, "a later request must configure, activate and start again")
    }

    @Test("a failed start reports it and drops the requests; the next request activates again")
    func failedStartDropsAndRetries() async {
        let ops = FakeStartOps()
        ops.startThrows = true
        let gate = EngineStartGate(operations: ops.operations)
        var failures = 0
        gate.onStartFailure = { _ in failures += 1 }
        var ran = false
        gate.whenRunning { ran = true }
        await yieldMain()
        ops.finishActivation()
        await gate.settle()
        #expect(failures == 1)
        #expect(!ran)
        #expect(gate.startCount == 0)
        ops.startThrows = false
        gate.whenRunning { ran = true }
        await yieldMain()
        ops.finishActivation()
        await gate.settle()
        #expect(ran)
        #expect(gate.activationCount == 2)
    }

    @Test("an engine already started elsewhere during the activation is not started twice")
    func alreadyRunningAfterActivationIsNotRestarted() async {
        let ops = FakeStartOps()
        let gate = EngineStartGate(operations: ops.operations)
        var ran = false
        gate.whenRunning { ran = true }
        await yieldMain()
        ops.running = true
        ops.finishActivation()
        await gate.settle()
        #expect(!ops.log.contains("start"))
        #expect(ran)
    }

    @Test("the production configuration step runs OFF the main thread")
    func productionPrepareRunsOffMain() async throws {
        let onMain = Mutex<Bool?>(nil)
        let prepare = EngineStartGate.offMain { onMain.withLock { $0 = Thread.isMainThread } }
        try await prepare()
        #expect(onMain.withLock { $0 } == false, "setCategory on the main thread is a Hang Risk while the session is active")
    }
    // MARK: Session work outside an activation (the route-change IO buffer)

    @Test("session work (the route-change IO buffer) runs OFF the main thread")
    func sessionWorkRunsOffMain() async {
        let ops = FakeStartOps()
        ops.running = true
        let gate = EngineStartGate(operations: ops.operations)
        let onMain = Mutex<[Bool]>([])
        gate.performSessionWork { onMain.withLock { $0.append(Thread.isMainThread) } }
        await gate.settle()
        #expect(onMain.withLock { $0 } == [false],
                "setPreferredIOBufferDuration on the main thread is a Hang Risk while the session is active")
    }

    @Test("session work waits for an activation in flight, and the start is not reordered behind it")
    func sessionWorkFollowsPendingActivation() async {
        let ops = FakeStartOps()
        let gate = EngineStartGate(operations: ops.operations)
        let ran = Mutex<[String]>([])
        gate.whenRunning { ran.withLock { $0.append("play") } }
        await yieldMain()
        gate.performSessionWork { ran.withLock { $0.append("iobuffer") } }
        await yieldMain()
        #expect(ran.withLock { $0 }.isEmpty, "the session work overtook the activation in flight")
        ops.finishActivation()
        await gate.settle()
        #expect(ran.withLock { $0 } == ["play", "iobuffer"])
        #expect(ops.log == ["prepare", "activate.begin", "activate.end", "start"])
    }

    @Test("an activation begun after session work waits for it")
    func laterActivationWaitsForSessionWork() async {
        let ops = FakeStartOps()
        let gate = EngineStartGate(operations: ops.operations)
        let release = Mutex<Bool>(false)
        let order = Mutex<[String]>([])
        let ranOnMain = Mutex<Bool>(false)
        let timedOut = Mutex<Bool>(false)
        let mainBlocked = Mutex<Bool>(false)
        // The suite is @MainActor, so this is the main thread's port. The
        // session work reads main's CPU time through it (see below).
        let mainPort = mach_thread_self()
        defer { mach_port_deallocate(mach_task_self_, mainPort) }
        #expect(Self.cpuMicros(mainPort) != nil,
                "main's CPU time cannot be read, so the blocked-main check below would be inert")
        gate.performSessionWork {
            // Work that runs ON the main thread (the mutation that inlines
            // performSessionWork) must not spin: the release below is set on
            // main, so a spin there would deadlock the run instead of
            // reporting RED. It is detected directly and recorded below.
            if Thread.isMainThread { ranOnMain.withLock { $0 = true }; return }
            // Off main, the spin ends when the test sets `release`, which it
            // always does. The bound is a backstop only, NOT a timing
            // assertion: a 2 s bound here failed the full device suite
            // (INTEG 2026-11-25) because the main actor was starved for
            // minutes while the parallel Swift Testing suites queued on it
            // (XCTest had already finished), so `release` arrived late with
            // nothing wrong.
            //
            // A starved main actor is BUSY: it runs the queued suites, so its
            // CPU time keeps rising. A main thread that BLOCKS waiting for
            // this work (a synchronous wait on it inside the gate) uses no CPU
            // at all. So the spin gives up early only when main's CPU time
            // has not moved for 5 s; a busy main keeps it waiting up to the
            // backstop, an idle main delivers `release` within microseconds.
            let deadline = Date().addingTimeInterval(600)
            var lastCPU = Self.cpuMicros(mainPort)
            var lastMove = Date()
            while !release.withLock({ $0 }) {
                if Date() >= deadline { timedOut.withLock { $0 = true }; return }
                if let cpu = Self.cpuMicros(mainPort), let last = lastCPU {
                    if cpu - last >= 1_000 {
                        lastCPU = cpu; lastMove = Date()
                    } else if Date().timeIntervalSince(lastMove) >= 5 {
                        mainBlocked.withLock { $0 = true }; return
                    }
                } else {
                    lastCPU = Self.cpuMicros(mainPort); lastMove = Date()
                }
                usleep(1_000)
            }
            order.withLock { $0.append("iobuffer") }
        }
        gate.whenRunning()
        await yieldMain()
        #expect(ops.log.isEmpty, "the activation began while earlier session work was still running: \(ops.log)")
        release.withLock { $0 = true }
        if ranOnMain.withLock({ $0 }) {
            Issue.record("session work ran on the main thread")
        }
        if mainBlocked.withLock({ $0 }) {
            Issue.record("the main thread sat blocked (no CPU for 5 s) while the session work ran")
        }
        if timedOut.withLock({ $0 }) {
            Issue.record("session work never observed the release (600 s backstop)")
        }
        for _ in 0..<2000 where ops.activationsBegun == 0 { try? await Task.sleep(for: .milliseconds(1)) }
        #expect(ops.activationsBegun == 1, "the activation never began after the session work finished")
        #expect(order.withLock { $0 } == ["iobuffer"])
        ops.finishActivation()
        await gate.settle()
        #expect(ops.log == ["prepare", "activate.begin", "activate.end", "start"])
    }
}
