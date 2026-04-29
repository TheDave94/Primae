// ThesisConditionAssignmentTests.swift
// PrimaeNativeTests
//
// Verifies the A/B cohort assignment is stable (same UUID → same arm)
// and that assignment covers all three arms across participants.

import Foundation
import Testing
@testable import PrimaeNative

@Suite struct ThesisConditionAssignmentTests {

    @Test("Same UUID always maps to the same condition")
    func stable_assignment() {
        let uuid = UUID()
        let first  = ThesisCondition.assign(participantId: uuid)
        let second = ThesisCondition.assign(participantId: uuid)
        let third  = ThesisCondition.assign(participantId: uuid)
        #expect(first == second)
        #expect(second == third)
    }

    @Test("Assignment spans all three arms across many random UUIDs")
    func covers_all_arms() {
        var seen = Set<ThesisCondition>()
        for _ in 0..<300 {
            seen.insert(ThesisCondition.assign(participantId: UUID()))
            if seen.count == 3 { break }
        }
        #expect(seen.count == 3)
    }

    @Test("Distribution across arms is roughly uniform")
    func roughly_uniform_distribution() {
        var counts: [ThesisCondition: Int] = [:]
        let n = 3000
        for _ in 0..<n {
            counts[ThesisCondition.assign(participantId: UUID()), default: 0] += 1
        }
        // Uniform is 1/3 each = ~1000. Allow +/- 200 for 3000 samples.
        for arm in ThesisCondition.allCases {
            let c = counts[arm] ?? 0
            #expect(c > 800 && c < 1200,
                    "Arm \(arm) got \(c) assignments; expected ~1000 ± 200")
        }
    }

    @Test("Known-byte UUIDs map deterministically")
    func deterministic_by_first_byte() {
        // First byte = 0 → threePhase, 1 → guidedOnly, 2 → control, 3 → threePhase, ...
        // The exact mapping only matters in that it's consistent.
        let byteZero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0,
                                   0, 0, 0, 0, 0, 0, 0, 0))
        let a1 = ThesisCondition.assign(participantId: byteZero)
        let a2 = ThesisCondition.assign(participantId: byteZero)
        #expect(a1 == a2)
    }

    // MARK: - Enrollment gating

    /// The A/B random assignment must not apply to non-enrolled installs —
    /// otherwise 2 out of 3 casual users would silently have Anschauen and
    /// Richtung lernen skipped on every letter. These tests exercise
    /// `ThesisCondition.defaultForInstall` directly (no `TracingDependencies`
    /// instantiation) so they don't drag AudioEngine / JSONProgressStore into
    /// the headless CI test bundle.

    @Test("defaultForInstall is threePhase when not enrolled")
    func default_unenrolled_is_threePhase() {
        let previous = ParticipantStore.isEnrolled
        defer { ParticipantStore.isEnrolled = previous }
        ParticipantStore.isEnrolled = false
        #expect(ThesisCondition.defaultForInstall == .threePhase)
    }

    @Test("defaultForInstall uses ThesisCondition.assign when enrolled")
    func enrolled_uses_assign() {
        let previous = ParticipantStore.isEnrolled
        defer { ParticipantStore.isEnrolled = previous }
        ParticipantStore.isEnrolled = true
        let expected = ThesisCondition.assign(participantId: ParticipantStore.participantId)
        #expect(ThesisCondition.defaultForInstall == expected)
    }
}
