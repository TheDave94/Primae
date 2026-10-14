// SetCompletionLedger.swift
// PrimaeNative
//
// Which participants have FINISHED their trained set on this device
// (audit 2026-10-13, R-033). The end-of-set hold
// (`TracingViewModel.awaitingNextParticipant`) lived only in memory, so a
// crash, jetsam or force-quit after the last letter relaunched the app
// parked on the first trained letter of the SAME participant — and a
// second full pass could be recorded under that id.
//
// Per participant, not a single flag: a new child has a new id, so the
// hold can never leak forward, and a restored child keeps the hold their
// training day ended with.

import Foundation

@MainActor
protocol SetCompletionRecording {
    func isSetComplete(for participantId: UUID) -> Bool
    func markSetComplete(for participantId: UUID)
}

/// UserDefaults-backed: one small string array, written synchronously,
/// so the hold is on disk before the next touch can reach the app.
final class UserDefaultsSetCompletionLedger: SetCompletionRecording {
    static let key = "de.flamingistan.primae.setCompleteParticipants"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func isSetComplete(for participantId: UUID) -> Bool {
        (defaults.stringArray(forKey: Self.key) ?? []).contains(participantId.uuidString)
    }

    func markSetComplete(for participantId: UUID) {
        var ids = defaults.stringArray(forKey: Self.key) ?? []
        guard !ids.contains(participantId.uuidString) else { return }
        ids.append(participantId.uuidString)
        defaults.set(ids, forKey: Self.key)
    }
}
