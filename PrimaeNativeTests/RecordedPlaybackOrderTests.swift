// RecordedPlaybackOrderTests.swift
//
// `AVAudioPlayer` play()/stop() moved off the main thread (INTEG
// 2026-11-25: `play()` re-activates the session synchronously, a runtime
// "AVAudioSession Hang Risk" on main). The move is safe only because every
// call goes through ONE serial queue: a `stop()` issued after a `play()`
// must run after it, or a stopped prompt keeps sounding. This pins that
// order for the work items the main actor enqueues.
import Testing
import Foundation
@testable import PrimaeNative

nonisolated private final class PlaybackOrderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var order: [Int] = []
    private var inFlight = 0
    private var overlapped = false

    func begin() { lock.lock(); inFlight += 1; if inFlight > 1 { overlapped = true }; lock.unlock() }
    func end(_ i: Int) { lock.lock(); order.append(i); inFlight -= 1; lock.unlock() }
    func result() -> (order: [Int], overlapped: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (order, overlapped)
    }
}

@Suite struct RecordedPlaybackOrderTests {

    /// Interleaved "play"/"stop" items run in exactly the order they were
    /// enqueued, and never two at once.
    @Test nonisolated func callsRunSeriallyInEnqueueOrder() {
        let log = PlaybackOrderLog()
        let group = DispatchGroup()
        let count = 400
        for i in 0..<count {
            group.enter()
            RecordedPlayback.perform {
                log.begin()
                // A play()/stop() takes real time; widen the window a
                // concurrent queue would need to reorder or overlap.
                Thread.sleep(forTimeInterval: 0.0002)
                log.end(i)
                group.leave()
            }
        }
        #expect(group.wait(timeout: .now() + 10) == .success, "the playback queue did not drain")
        let r = log.result()
        #expect(r.order == Array(0..<count), "a stop() could overtake the play() before it")
        #expect(!r.overlapped, "two AVAudioPlayer calls ran at the same time")
    }
}
