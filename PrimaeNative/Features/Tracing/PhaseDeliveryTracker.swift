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

    /// A letter starts in `phase` (after `load(letter:)`'s skips and probe
    /// jump). Forgets the previous letter's phases.
    mutating func beginLetter(in phase: LearningPhase, counters: LifecycleCounters,
                              environment: EnvironmentStamp) {
        closed = [:]
        open(phase, counters: counters, environment: environment)
    }

    /// The open phase ended and `next` began (a phase transition).
    mutating func transition(to next: LearningPhase, counters: LifecycleCounters,
                             environment: EnvironmentStamp) {
        if let phase = openPhase {
            closed[phase] = share(counters: counters, outputRouteAtEnd: environment.outputRoute)
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
        return share(counters: counters, outputRouteAtEnd: outputRouteNow)
    }

    private mutating func open(_ phase: LearningPhase, counters: LifecycleCounters,
                               environment: EnvironmentStamp) {
        openPhase = phase
        openedWith = counters
        openedEnvironment = environment
    }

    private func share(counters: LifecycleCounters, outputRouteAtEnd: String?) -> PhaseDelivery {
        PhaseDelivery(
            observeRestarts: counters.observeRestarts - openedWith.observeRestarts,
            strokesCancelled: counters.strokesCancelled - openedWith.strokesCancelled,
            routeChanges: counters.routeChanges - openedWith.routeChanges,
            interruptions: counters.interruptions - openedWith.interruptions,
            atStart: openedEnvironment,
            outputRouteAtEnd: outputRouteAtEnd)
    }
}
