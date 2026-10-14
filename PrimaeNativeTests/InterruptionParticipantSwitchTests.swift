// InterruptionParticipantSwitchTests.swift
// Batch C review, item 1 (reviewer probe M2): an interruption's carried
// state — a held observe to restart, a held quiet window, a held phase
// instruction — belonged to the OUTGOING child, but only a following
// `load(letter:)` cleared it, and "Teilnehmer wiederherstellen" never
// loads. Restoring a child under the parent area in the middle of an
// observe, then closing it, replayed the outgoing child's observe cue
// behind the relaunch block screen. A participant switch now clears the
// carried state, and a resume restarts nothing while the session is
// blocked or the letter is closed.
//
// An EXTENSION of `NewParticipantResetTests`: these tests enrol and
// restore through the process-wide `ParticipantStore`, and only that
// suite's `.serialized` trait keeps them from interleaving.

import Testing
import SwiftUI
@testable import PrimaeNative

extension NewParticipantResetTests {

    fileprivate var observeCue: String { ChildSpeechLibrary.phaseEntry(.observe) }

    fileprivate func keepingIdentity(_ body: () async throws -> Void) async rethrows {
        let pedOverride    = ParticipantStore.conditionOverride
        let audioOverride  = ParticipantStore.audioConditionOverride
        let subsetOverride = ParticipantStore.trainedSubsetOverride
        let enrolled       = ParticipantStore.isEnrolled
        defer {
            ParticipantStore.conditionOverride = pedOverride
            ParticipantStore.audioConditionOverride = audioOverride
            ParticipantStore.trainedSubsetOverride = subsetOverride
            ParticipantStore.isEnrolled = enrolled
        }
        try await body()
    }

    /// Load A and let its observe presentation start. After an enrolment
    /// the incoming child's own first load may already have queued a cue
    /// for A (when their subset contains it), so cues are ended until the
    /// presentation starts — the newest load's cue end is the one that
    /// counts.
    fileprivate func observing(_ rig: LifecycleRig) async {
        rig.vm.loadLetter(name: "A")
        for _ in 0..<3 where rig.vm.animation.armedStrokes == nil {
            rig.speech.end(observeCue)
            await rig.waitUntil(3) { rig.vm.animation.armedStrokes != nil }
        }
    }

    @Test("restore under the parent area mid-observe: closing it replays nothing of the outgoing child's observe")
    func restoreUnderTheParentAreaReplaysNothing() async {
        await keepingIdentity {
            let rig = LifecycleRig()
            let childA = rig.vm.resetForNewParticipant()
            _ = rig.vm.resetForNewParticipant()            // child C is live
            await observing(rig)
            #expect(rig.vm.animation.armedStrokes != nil, "precondition: C's observe is running")
            rig.vm.parentAreaDidOpen()
            let cues = rig.prompts.count(.phaseObserve)

            #expect(rig.vm.restoreParticipant(uuidString: childA.uuidString) == .restored(childA))
            let carry = rig.vm.debugInterruptionCarry
            #expect(carry.observeRestartLetter == nil && !carry.quietWindowHeld && carry.heldPhasePrompt == nil,
                    "the outgoing child's interruption state survived the restore: \(carry)")

            rig.vm.parentAreaDidClose()
            #expect(rig.vm.sessionBlockReason != nil, "precondition: a restore blocks until the relaunch")
            #expect(rig.prompts.count(.phaseObserve) == cues,
                    "the outgoing child's observe cue was replayed behind the relaunch block")
            #expect(rig.vm.animation.armedStrokes == nil && !rig.vm.debugObservePresentationPending)
            #expect(rig.vm.lifecycleCounters.observeRestarts == 0)
        }
    }

    /// Path-independent: the stub repository holds only "A", and whether
    /// the incoming child's first letter can load depends on the subset
    /// their random id draws (4 of 10 contain A). Either way the
    /// outgoing child's observe must not restart; the test repeats until
    /// it has seen the no-load path, where only the participant switch
    /// itself can clear the held observe (P(never) = 0.4^12).
    @Test("'Nächstes Kind' under the parent area mid-observe: the outgoing child's observe never restarts")
    func nextChildUnderTheParentAreaRestartsNothingOfTheOutgoingChild() async {
        await keepingIdentity {
            let rig = LifecycleRig()
            var sawNoLoad = false
            for _ in 0..<12 where !sawNoLoad {
                await observing(rig)
                rig.vm.parentAreaDidOpen()
                let cues = rig.prompts.count(.phaseObserve)
                _ = rig.vm.resetForNewParticipant()
                let incomingLoaded = rig.vm.visibleLetterNames.contains("A")
                let carry = rig.vm.debugInterruptionCarry
                if incomingLoaded {
                    // The incoming child's own first observe, deferred to the close.
                    #expect(carry.observeRestartLetter == nil || carry.observeRestartLetter == "A")
                } else {
                    sawNoLoad = true
                    #expect(carry.observeRestartLetter == nil && !carry.quietWindowHeld && carry.heldPhasePrompt == nil,
                            "the outgoing child's interruption state survived 'Nächstes Kind': \(carry)")
                }
                rig.vm.parentAreaDidClose()
                #expect(rig.vm.lifecycleCounters.observeRestarts == 0,
                        "the outgoing child's observe was restarted for the incoming child")
                if !incomingLoaded {
                    #expect(rig.prompts.count(.phaseObserve) == cues,
                            "the outgoing child's observe cue was replayed after 'Nächstes Kind'")
                }
            }
            #expect(sawNoLoad, "never reached the path where no letter loads for the incoming child")
        }
    }

    @Test("an assignment change made in the parent area blocks the session; closing it restarts no observe")
    func blockedSessionRestartsNoObserve() async {
        await keepingIdentity {
            let rig = LifecycleRig()
            await observing(rig)
            rig.vm.parentAreaDidOpen()
            let cues = rig.prompts.count(.phaseObserve)
            rig.vm.markAssignmentOverrideChanged()
            rig.vm.parentAreaDidClose()
            #expect(rig.vm.sessionBlockReason != nil, "precondition")
            #expect(rig.prompts.count(.phaseObserve) == cues,
                    "the observe was restarted on a session that must not run")
            #expect(rig.vm.animation.armedStrokes == nil && !rig.vm.debugObservePresentationPending)
        }
    }
}
