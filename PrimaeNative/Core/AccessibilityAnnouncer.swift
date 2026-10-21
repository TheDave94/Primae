// AccessibilityAnnouncer.swift
// PrimaeNative
//
// A seam over VoiceOver announcements, so "a message was announced" is
// assertable without a screen reader: `AccessibilityNotification.Announcement`
// posts into the system and nothing in a unit or UI test can observe it
// (U10, 2026-10-21).

import SwiftUI

protocol AccessibilityAnnouncing {
    func announce(_ message: String)
}

/// Posts a VoiceOver announcement. Silent when VoiceOver is off.
struct SystemAccessibilityAnnouncer: AccessibilityAnnouncing {
    func announce(_ message: String) {
        AccessibilityNotification.Announcement(message).post()
    }
}
