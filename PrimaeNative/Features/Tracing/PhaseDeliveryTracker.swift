// PhaseDeliveryTracker.swift
// PrimaeNative
//
// Splits a letter's interruption bookkeeping into PER-PHASE deliveries
// (fix batch D, audit 2026-10-13, R-020). `LifecycleCounters` (batch C)
// count for the whole letter and every phase row of a completed letter is
// written at the same moment, at the end — so without this split the
// observe row would carry the free-writing phase's cancelled strokes, and
// every row of a letter the same totals. Each phase's share is the
// difference between the counters when it opened and when it closed.

import Foundation

struct PhaseDeliveryTracker: Equatable {
    /// The phase currently open, if any.
    private(set) var openPhase: LearningPhase?
    private var openedWith = LifecycleCounters()
    private var openedEnvironment: EnvironmentStamp?
    /// Deliveries of the phases this letter has already closed.
    private(set) var closed: [LearningPhase: PhaseDelivery] = [:]
    /// ENV3 (r17): the lift-to-touch gaps measured while the open phase was open, and the child's tempo as it stood
    /// at the last one (nil until the first). The hold and stall in force are the tempo's, read when the phase closes.
    private var openGaps: [Double] = []
    private(set) var tempo = StrokeTempo()

    /// A letter starts in `phase` (after `load(letter:)`'s skips and probe
    /// jump). Forgets the previous letter's phases.
    mutating func beginLetter(in phase: LearningPhase, counters: LifecycleCounters,
                              environment: EnvironmentStamp) {
        closed = [:]
        open(phase, counters: counters, environment: environment)
    }

    /// One measured lift-to-touch gap in the open phase.
    mutating func noteGap(_ gap: Double) { openGaps.append(gap) }
    /// The child's tempo, for the hold and stall columns (set by the view model before a row is built and at every phase close).
    mutating func setTempo(_ t: StrokeTempo) { tempo = t }

    /// The open phase ended and `next` began (a phase transition).
    mutating func transition(to next: LearningPhase, counters: LifecycleCounters,
                             environment: EnvironmentStamp) {
        if let phase = openPhase {
            closed[phase] = share(of: phase, counters: counters, outputRouteAtEnd: environment.outputRoute)
        }
        open(next, counters: counters, environment: environment)
    }

    /// The delivery for `phase`: its closed record, or — for the phase
    /// still open — its share up to now. Nil for a phase this letter never
    /// opened.
    func delivery(for phase: LearningPhase, counters: LifecycleCounters,
                  outputRouteNow: String?) -> PhaseDelivery? {
        if let done = closed[phase] { return done }
        guard openPhase == phase else { return nil }
        return share(of: phase, counters: counters, outputRouteAtEnd: outputRouteNow)
    }

    private mutating func open(_ phase: LearningPhase, counters: LifecycleCounters,
                               environment: EnvironmentStamp) {
        openPhase = phase
        openGaps = []
        openedWith = counters
        openedEnvironment = environment
    }

    /// `counters` must be settled (`LifecycleCounters.settled(at:)`), so a
    /// running observe sound's seconds are in them. The observe-sound
    /// fields (protocol r11) belong to the observe row alone.
    private func share(of phase: LearningPhase, counters: LifecycleCounters,
                       outputRouteAtEnd: String?) -> PhaseDelivery {
        let observe = phase == .observe
        return PhaseDelivery(
            observeRestarts: counters.observeRestarts - openedWith.observeRestarts,
            strokesCancelled: counters.strokesCancelled - openedWith.strokesCancelled,
            routeChanges: counters.routeChanges - openedWith.routeChanges,
            interruptions: counters.interruptions - openedWith.interruptions,
            atStart: openedEnvironment,
            outputRouteAtEnd: outputRouteAtEnd,
            observeLossesDuringSound: observe
                ? counters.observeLossesDuringSound - openedWith.observeLossesDuringSound : nil,
            observeLossesWithoutSound: observe
                ? counters.observeLossesWithoutSound - openedWith.observeLossesWithoutSound : nil,
            observeSoundSeconds: observe
                ? counters.observeSoundSeconds - openedWith.observeSoundSeconds : nil,
            observeSoundDeliveredSeconds: observe
                ? counters.observeSoundDeliveredSeconds - openedWith.observeSoundDeliveredSeconds : nil,
            liftHoldSeconds: tempo.holdSeconds,
            stallSeconds: tempo.stallSeconds,
            strokeGaps: openGaps.count,
            strokeGapMedianSeconds: openGaps.isEmpty ? nil : StrokeTempoMedian.of(openGaps))
    }
}

nonisolated enum StrokeTempoMedian {
    static func of(_ v: [Double]) -> Double {
        let s = v.sorted(), n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }
}
