// DysfluencyMeter.swift
// PrimaeNative
//
// R18DIM slice 7 ("Dysfluency to roughness", Klang-Dimensionen): how halting
// the pen is, measured from the pen's OWN sample stream and nothing else.
//
// DEFINITION (ours, not a literature value). Raw touch samples arrive at an
// irregular rate, so displacement is first pooled into fixed `binSeconds`
// bins (a speed per bin). A "stop-start event" is a bin whose speed falls
// below `dipFraction` of the recent peak speed (the peak itself at least
// `minPeakSpeed` pt/s, so a slow, steady writer produces none), after which the speed has to recover
// above `recoverFraction` of that peak before a second event can count. The
// roughness is the number of events inside the last `windowSeconds`, over
// `saturationCount`, clamped to 0...1. Fluent writing is a smooth speed
// profile (few or no events); jerky, stop-and-go writing is a train of them.
// The audible rendering (amplitude roughness) is the kernel's job
// (`LiveSonificationKernel.setRoughness`); the constants here are the part to
// re-tune in the try-out session (slice 8).
//
// Pure value type: no clock, no audio, no state outside itself; the caller
// supplies the touch time. Not a reproduction of any published sonification;
// no external source was consulted for these definitions.

import Foundation

struct DysfluencyMeter: Equatable {
    struct Tuning: Equatable {
        var binSeconds: Double = 0.05
        var windowSeconds: Double = 1.0
        var minPeakSpeed: Double = 80        // pt/s
        var dipFraction: Double = 0.3
        var recoverFraction: Double = 0.6
        var peakDecayPerBin: Double = 0.97
        var saturationCount: Double = 3
    }

    var tuning = Tuning()
    private var binStart: Double?
    private var binDistance: Double = 0
    private var peak: Double = 0
    private var inDip = false
    private var events: [Double] = []

    init(tuning: Tuning = Tuning()) { self.tuning = tuning }

    /// A pen displacement of `distance` pt arriving at touch time `t` (seconds).
    mutating func add(t: Double, distance: Double) {
        guard t.isFinite, distance.isFinite else { return }
        guard let start = binStart else { binStart = t; binDistance = max(0, distance); return }
        if t < start { reset(); binStart = t; return }      // a clock that went backwards: start over
        binDistance += max(0, distance)
        let span = t - start
        guard span >= tuning.binSeconds else { return }
        closeBin(speed: binDistance / span, at: t)
        binStart = t
        binDistance = 0
    }

    private mutating func closeBin(speed s: Double, at t: Double) {
        peak = max(s, peak * tuning.peakDecayPerBin)
        if inDip {
            if s >= tuning.recoverFraction * peak { inDip = false; peak = s }
        } else if peak >= tuning.minPeakSpeed, s < tuning.dipFraction * peak {
            inDip = true
            events.append(t)
        }
        events.removeAll { t - $0 > tuning.windowSeconds }
    }

    /// Events in the window that ends at `t` (a pen that has stopped sending
    /// samples is a stopped pen, not a rough one: the window only prunes on a new bin).
    func eventCount(at t: Double) -> Int { events.filter { t - $0 <= tuning.windowSeconds }.count }

    /// 0 (smooth) ... 1 (saturated stop-and-go) for the window ending at `t`.
    func roughness(at t: Double) -> Float {
        Float(min(1, Double(eventCount(at: t)) / tuning.saturationCount))
    }

    mutating func reset() {
        binStart = nil; binDistance = 0; peak = 0; inDip = false; events.removeAll(keepingCapacity: true)
    }
}
