// WritingMode.swift
// BuchstabenNative
//
// Top-level switch between the guided four-phase tracing flow and the
// freeform writing canvas. Stored on TracingViewModel and toggled from
// the letter picker area.

import Foundation

/// Whether the app is currently in guided tracing mode (with reference
/// letter, checkpoints, and phase progression) or freeform writing mode
/// (blank canvas, child writes anything, recognizer labels the result).
enum WritingMode: String, Codable, Sendable, Equatable {
    case guided
    case freeform
}

/// Sub-mode inside freeform. `.letter` recognises one letter at a time,
/// `.word` shows a target word and segments the drawing letter-by-letter.
enum FreeformSubMode: String, Codable, Sendable, Equatable {
    case letter
    case word
}
