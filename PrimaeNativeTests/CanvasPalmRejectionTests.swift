// CanvasPalmRejectionTests.swift
// PrimaeNativeTests
//
// Audit R-042, "palm-first becomes the trace": a contact whose
// `majorRadius` exceeds `CanvasTouchArbiter.palmMajorRadius` is a palm. It
// never becomes the pen, does not count against a finger landing beside it,
// and a pen that grows into a palm is rejected so the next finger can be
// acquired. The movement rule for resting contacts (UI-1 / B10) is pinned in
// `CanvasAndSettingsFixTests.swift`.

import Testing
import Foundation
import CoreGraphics
@testable import PrimaeNative

@MainActor
@Suite struct CanvasPalmRejectionTests {

    typealias Arbiter = CanvasTouchArbiter<Int>
    typealias Sample = Arbiter.Sample
    typealias Touch = Arbiter.Touch

    /// `#expect` evaluates its expression in a closure, where a `var`
    /// struct cannot be mutated.
    final class Box { var v = Arbiter() }

    private let finger: CGFloat = 20
    private var palm: CGFloat { Arbiter.palmMajorRadius + 20 }

    private func s(_ x: CGFloat, _ y: CGFloat, _ t: CFTimeInterval) -> Sample {
        Sample(point: CGPoint(x: x, y: y), time: t)
    }

    @Test("a single finger is acquired at touch-down")
    func singleFingerAcquired() {
        let a = Box()
        let n = Arbiter.penCandidateCount([Touch(id: 1, isPencil: false, majorRadius: finger, isActive: true)])
        #expect(n == 1)
        #expect(a.v.began(1, at: s(10, 10, 0), majorRadius: finger, fingersInView: n)
                == .begin(1, replay: [s(10, 10, 0)]))
        #expect(a.v.tracked == 1)
    }

    @Test("a palm landing alone is never the pen, even when it moves")
    func palmRejected() {
        let a = Box()
        let n = Arbiter.penCandidateCount([Touch(id: 1, isPencil: false, majorRadius: palm, isActive: true)])
        #expect(n == 0)
        #expect(a.v.began(1, at: s(700, 700, 0), majorRadius: palm, fingersInView: n) == .none)
        #expect(a.v.moved(1, samples: [s(760, 700, 0.2)], majorRadius: palm) == .none,
                "a sliding palm was adopted as the trace")
        #expect(a.v.tracked == nil)
    }

    @Test("palm resting + finger lands: the finger is the pen at once")
    func palmRestingThenFinger() {
        let a = Box()
        let palmDown = [Touch(id: 1, isPencil: false, majorRadius: palm, isActive: true)]
        _ = a.v.began(1, at: s(700, 700, 0), majorRadius: palm,
                      fingersInView: Arbiter.penCandidateCount(palmDown))
        let both = palmDown + [Touch(id: 2, isPencil: false, majorRadius: finger, isActive: true)]
        #expect(a.v.began(2, at: s(100, 100, 0.3), majorRadius: finger,
                          fingersInView: Arbiter.penCandidateCount(both))
                == .begin(2, replay: [s(100, 100, 0.3)]),
                "the resting palm blocked the finger")
        // The palm drifting while the finger traces does not take the pen.
        #expect(a.v.moved(1, samples: [s(740, 700, 0.4)], majorRadius: palm) == .none)
        #expect(a.v.tracked == 2)
    }

    /// A pencil never reaches the arbiter as a candidate: the finger overlay
    /// leaves it to the pencil overlay, exactly as before R-042.
    @Test("a pencil on the canvas does not count against a finger")
    func pencilUnchanged() {
        let a = Box()
        let touches = [
            Touch(id: 1, isPencil: true, majorRadius: 0.5, isActive: true),
            Touch(id: 2, isPencil: false, majorRadius: finger, isActive: true),
        ]
        #expect(Arbiter.penCandidateCount(touches) == 1)
        #expect(Arbiter.penCandidateCount([Touch(id: 1, isPencil: true, majorRadius: 0.5, isActive: true)]) == 0)
        #expect(a.v.began(2, at: s(50, 50, 0), majorRadius: finger,
                          fingersInView: Arbiter.penCandidateCount(touches))
                == .begin(2, replay: [s(50, 50, 0)]))
    }

    @Test("the acquired touch ends: the remaining finger is re-acquired")
    func reacquireAfterEnd() {
        let a = Box()
        _ = a.v.began(1, at: s(100, 100, 0), majorRadius: finger, fingersInView: 1)
        _ = a.v.began(2, at: s(400, 400, 0.1), majorRadius: finger, fingersInView: 2)
        let ended = a.v.ended(1)
        #expect(ended)
        #expect(a.v.tracked == nil)
        #expect(a.v.moved(2, samples: [s(400, 440, 0.3)], majorRadius: finger)
                == .begin(2, replay: [s(400, 400, 0.1), s(400, 440, 0.3)]))
    }

    /// The heel of the hand lands small and grows as the hand settles: the
    /// pen it became is rejected, and the finger that lands next is the pen.
    @Test("a pen that grows into a palm is rejected and a finger re-acquired")
    func penGrowsIntoPalm() {
        let a = Box()
        #expect(a.v.began(1, at: s(700, 700, 0), majorRadius: finger, fingersInView: 1)
                == .begin(1, replay: [s(700, 700, 0)]))
        #expect(a.v.moved(1, samples: [s(702, 700, 0.1)], majorRadius: palm) == .reject(1))
        #expect(a.v.tracked == nil)
        #expect(a.v.moved(1, samples: [s(704, 700, 0.2)], majorRadius: finger) == .none,
                "a palm stays a palm until it lifts")
        #expect(a.v.began(2, at: s(100, 100, 0.3), majorRadius: finger, fingersInView: 1)
                == .begin(2, replay: [s(100, 100, 0.3)]))
        #expect(a.v.ended(1) == false, "the palm's lift must not end the finger's stroke")
    }

    /// A finger that was down beside the pen when the pen turned into a palm
    /// is waiting for the movement rule. The palm sliding far must not count
    /// as a moving finger that keeps the waiting one from being acquired.
    @Test("a sliding palm does not block a waiting finger's acquisition")
    func slidingPalmDoesNotBlockWaitingFinger() {
        let a = Box()
        _ = a.v.began(1, at: s(700, 700, 0), majorRadius: finger, fingersInView: 1)
        #expect(a.v.began(2, at: s(100, 100, 0.1), majorRadius: finger, fingersInView: 2) == .none)
        #expect(a.v.moved(1, samples: [s(702, 700, 0.2)], majorRadius: palm) == .reject(1))
        #expect(a.v.moved(1, samples: [s(780, 700, 0.3)], majorRadius: palm) == .none)
        #expect(a.v.moved(2, samples: [s(100, 140, 0.4)], majorRadius: finger)
                == .begin(2, replay: [s(100, 100, 0.1), s(100, 140, 0.4)]),
                "the sliding palm blocked the waiting finger")
        #expect(a.v.tracked == 2)
    }
}
