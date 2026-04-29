// AppWorld.swift
// PrimaeNative
//
// Top-level navigation model for the three-world UI. Each world is a
// full-screen environment; a persistent 64pt rail on the left edge of
// the screen lets the child switch between them. Settings and research
// features live behind a parental gate (see ParentAreaView) and are
// never reachable from these enum cases.

import Foundation

/// One of the three child-facing worlds.
enum AppWorld: String, CaseIterable, Identifiable, Sendable {
    /// Buchstaben-Schule — guided four-phase letter learning.
    case schule
    /// Schreibwerkstatt — freeform letter and word writing.
    case werkstatt
    /// Meine Fortschritte — child-facing progress / stars / streak.
    case fortschritte

    var id: String { rawValue }

    /// SF Symbol used by the world-switcher rail and any in-world chrome.
    var icon: String {
        switch self {
        case .schule:       return "book.fill"
        case .werkstatt:    return "pencil.tip"
        case .fortschritte: return "star.fill"
        }
    }

    /// Short German label shown underneath the rail icon.
    var label: String {
        switch self {
        case .schule:       return "Schule"
        case .werkstatt:    return "Werkstatt"
        case .fortschritte: return "Sterne"
        }
    }

    /// Full VoiceOver-friendly German name.
    var accessibilityLabel: String {
        switch self {
        case .schule:       return "Buchstaben-Schule"
        case .werkstatt:    return "Schreibwerkstatt"
        case .fortschritte: return "Meine Fortschritte"
        }
    }
}
