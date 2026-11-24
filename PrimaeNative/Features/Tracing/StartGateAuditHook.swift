// StartGateAuditHook.swift
// PrimaeNative
//
// DEBUG-only UI-test instrument. `AccessibilityAuditUITests.
// testBlockedStartGate` audits the "Studie kann nicht starten" screen, which
// only exists while no participant is enrolled. The study iPad always has one,
// and un-enrolling it for real would wipe a participant, so this launch
// argument makes `ParticipantStore.isEnrolled` READ false for that launch
// only. Nothing is written: the device's enrolment is untouched once the app
// is relaunched without the argument.
//
// The whole file is `#if DEBUG`, so the argument string is not in the
// Release-Study binary (checked with `strings`).

#if DEBUG
import Foundation

enum StartGateAuditHook {
    static let launchArgument = "-auditStartGateUnenrolled"

    static var isArmed: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }
}
#endif
