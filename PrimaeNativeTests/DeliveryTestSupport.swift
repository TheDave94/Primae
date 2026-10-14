// DeliveryTestSupport.swift
// Shared doubles for the delivery-recording suites (fix batch D, audit
// 2026-10-13: R-017, R-018, R-020, R-021, R-032, R-034, R-123).

import Foundation
import CoreGraphics
@testable import PrimaeNative

/// A dashboard store that records every phase row WITH its batch-D
/// context, and every duration row with its batch-D stamps. Implements the
/// newest requirements directly, so nothing reaches a forwarding default
/// that would drop what is under test.
@MainActor
final class DeliveryRowStore: ParentDashboardStoring {
    struct Row {
        let letter: String
        let phase: String
        let completed: Bool
        let probe: String?
        let context: PhaseRowContext?
    }
    struct Duration {
        let letter: String
        let probe: String?
        let trainedSubset: String?
        let comparisonConfiguration: String?
    }
    var snapshot: DashboardSnapshot { DashboardSnapshot() }
    private(set) var rows: [Row] = []
    private(set) var durations: [Duration] = []

    func recordSession(letter: String, accuracy: Double, durationSeconds: TimeInterval,
                       wallClockSeconds: TimeInterval?, date: Date, condition: ThesisCondition,
                       inputDevice: String?) {
        durations.append(Duration(letter: letter, probe: nil, trainedSubset: nil, comparisonConfiguration: nil))
    }
    func recordSession(letter: String, accuracy: Double, durationSeconds: TimeInterval,
                       wallClockSeconds: TimeInterval?, date: Date, condition: ThesisCondition,
                       inputDevice: String?, audioCondition: PilotAudioCondition?,
                       studyMode: Bool?, probe: String?,
                       trainedSubset: String?, comparisonConfiguration: String?) {
        durations.append(Duration(letter: letter, probe: probe, trainedSubset: trainedSubset,
                                  comparisonConfiguration: comparisonConfiguration))
    }
    func recordPhaseSession(letter: String, phase: String, completed: Bool, score: Double, schedulerPriority: Double, condition: ThesisCondition, audioCondition: PilotAudioCondition, assessment: WritingAssessment?, recognition: RecognitionSample?, inputDevice: String?, rawTraceID: UUID?, trainedSubset: String?, phaseDurationSeconds: Double?, frechetDistance: Double?, checkpointCoverage: Double?, spatialDeviation: Double?, strokeCount: Int?, strokeOrder: String?, reversedStrokeCount: Int?, studyMode: Bool?, probe: String?, comparisonConfiguration: String?) {
        rows.append(Row(letter: letter, phase: phase, completed: completed, probe: probe, context: nil))
    }
    func recordPhaseSession(letter: String, phase: String, completed: Bool, score: Double, schedulerPriority: Double, condition: ThesisCondition, audioCondition: PilotAudioCondition, assessment: WritingAssessment?, recognition: RecognitionSample?, inputDevice: String?, rawTraceID: UUID?, trainedSubset: String?, phaseDurationSeconds: Double?, frechetDistance: Double?, checkpointCoverage: Double?, spatialDeviation: Double?, strokeCount: Int?, strokeOrder: String?, reversedStrokeCount: Int?, studyMode: Bool?, probe: String?, comparisonConfiguration: String?, spatialDeviationRaw: Double?, context: PhaseRowContext) {
        rows.append(Row(letter: letter, phase: phase, completed: completed, probe: probe, context: context))
    }
    func reset() { rows.removeAll(); durations.removeAll() }
    func rows(_ phase: LearningPhase) -> [Row] { rows.filter { $0.phase == phase.rawName } }
}

/// A recognizer that counts model probes and answers from a script — the
/// warm-up's retry is observable only as a second probe.
final class ScriptedAvailabilityRecognizer: LetterRecognizerProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [Bool]
    private var probes = 0
    init(answers: [Bool]) { self.answers = answers }
    var probeCount: Int { lock.lock(); defer { lock.unlock() }; return probes }
    func isModelAvailable() async -> Bool {
        lock.lock(); defer { lock.unlock() }
        probes += 1
        return answers.isEmpty ? false : answers.removeFirst()
    }
    func recognize(points: [CGPoint], strokeStartIndices: [Int], canvasSize: CGSize,
                   expectedLetter: String?, historicalFormScores: [CGFloat]) async -> RecognitionResult? { nil }
}

/// A recognizer whose model takes `delay` to load — a warm-up in flight.
final class SlowAvailabilityRecognizer: LetterRecognizerProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var probes = 0
    private let delay: Duration
    init(delay: Duration) { self.delay = delay }
    var probeCount: Int { lock.lock(); defer { lock.unlock() }; return probes }
    func isModelAvailable() async -> Bool {
        lock.lock(); probes += 1; lock.unlock()
        try? await Task.sleep(for: delay)
        return true
    }
    func recognize(points: [CGPoint], strokeStartIndices: [Int], canvasSize: CGSize,
                   expectedLetter: String?, historicalFormScores: [CGFloat]) async -> RecognitionResult? { nil }
}

/// Header and rows of the PHASE block of a delimited export, by column name.
struct PhaseBlock {
    let header: [String]
    let rows: [[String]]
    func value(_ column: String, row: Int = 0) -> String? {
        guard let i = header.firstIndex(of: column), row < rows.count, i < rows[row].count else { return nil }
        return rows[row][i]
    }
}

enum DelimitedExport {
    /// Splits one RFC 4180 line (quoted fields may contain the separator).
    static func fields(_ line: String, separator: Character = ",") -> [String] {
        var out: [String] = []
        var field = ""
        var quoted = false
        var chars = Array(line)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if quoted {
                if ch == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { field.append("\""); i += 1 }
                    else { quoted = false }
                } else { field.append(ch) }
            } else if ch == "\"" {
                quoted = true
            } else if ch == separator {
                out.append(field); field = ""
            } else {
                field.append(ch)
            }
            i += 1
        }
        out.append(field)
        chars.removeAll()
        return out
    }

    /// The block whose header line starts with `prefix`, up to the next
    /// blank line.
    static func block(in text: String, headerPrefix prefix: String, separator: Character = ",") -> PhaseBlock? {
        let lines = text.components(separatedBy: "\n")
        guard let h = lines.firstIndex(where: { $0.hasPrefix(prefix) }) else { return nil }
        var rows: [[String]] = []
        var i = h + 1
        while i < lines.count, !lines[i].isEmpty {
            rows.append(fields(lines[i], separator: separator)); i += 1
        }
        return PhaseBlock(header: fields(lines[h], separator: separator), rows: rows)
    }
}
