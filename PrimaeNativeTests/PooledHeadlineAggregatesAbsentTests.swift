// PooledHeadlineAggregatesAbsentTests.swift
//
// Audit R-031: the research export's pooled headline aggregates —
// `phaseCompletionRate_<phase>`, `averageFreeWriteScore` and
// `schedulerEffectivenessProxy` (CSV/TSV metric rows; the JSON
// `thesisMetrics.phaseCompletionRates` / `.averageFreeWriteScore` /
// `.schedulerEffectivenessProxy` keys) — were computed over EVERY enrolled
// row, pooling protocol revisions, cold-probe rows and comparison-mode rows.
// They are removed; analysis recomputes from the per-row fields, which stay.
//
// This suite pins their ABSENCE in all three formats, and pins that the
// neighbouring per-arm aggregates and the row-level inputs are still there,
// so the absence cannot pass because the whole metric section vanished.
//
// The fixture gives every removed aggregate a DEFINED value (observe +
// guided + freeWrite rows; three scored freeWrite rows of one letter with
// varying priority and score, so the proxy has two pairs and non-zero
// variance) — reinstating any one of them writes a non-empty row and turns
// this suite RED.

import Testing
import Foundation
@testable import PrimaeNative

@Suite struct PooledHeadlineAggregatesAbsentTests {

    private let pid = UUID(uuidString: "00000000-0000-0000-0000-00000000A031")!

    private func fixture() -> DashboardSnapshot {
        let t0 = Date(timeIntervalSince1970: 1_793_000_000)
        func row(_ phase: String, _ score: Double, _ prio: Double, _ dt: TimeInterval,
                 probe: String? = nil, revision: Int? = StudyProtocol.revision) -> PhaseSessionRecord {
            PhaseSessionRecord(letter: "A", phase: phase, completed: true, score: score,
                               schedulerPriority: prio, condition: .threePhase,
                               audioCondition: .phoneme, recordedAt: t0.addingTimeInterval(dt),
                               studyMode: true, probe: probe, protocolRevision: revision)
        }
        return DashboardSnapshot(phaseSessionRecords: [
            row("observe", 1.0, 0.9, 10),
            row("guided", 0.6, 0.9, 20),
            row("freeWrite", 0.2, 0.9, 30, revision: 25),
            row("freeWrite", 0.6, 0.5, 40),
            row("freeWrite", 0.7, 0.1, 50, probe: "posttest"),
            // A third TRAINING row: the probe row above no longer pairs into the
            // per-arm scheduler proxy (r27), which needs two pairs.
            row("freeWrite", 0.65, 0.3, 60),
        ])
    }

    /// `metric,value` rows of the delimited export, keyed by the metric name.
    private func metricKeys(_ text: String, sep: Character) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.split(separator: sep, omittingEmptySubsequences: false).map(String.init) }
            .filter { $0.count == 2 }
            .map { $0[0] }
    }

    private func isPooledHeadline(_ key: String) -> Bool {
        key == "averageFreeWriteScore"
            || key == "schedulerEffectivenessProxy"
            || key.hasPrefix("phaseCompletionRate_")
    }

    @Test("CSV and TSV carry no pooled headline aggregate, and keep the per-arm ones",
          arguments: [",", "\t"])
    func delimitedExportsOmitPooledHeadlines(separator: String) {
        let sep = Character(separator)
        let source = ParticipantExportSource(snapshot: fixture(), participantId: pid,
                                             progress: [:], rawTraces: [], enrolledAt: nil)
        let text = String(decoding: ParentDashboardExporter.combinedDelimitedData(
            participants: [source], separator: separator), as: UTF8.self)
        let keys = metricKeys(text, sep: sep)

        let pooled = keys.filter(isPooledHeadline)
        #expect(pooled.isEmpty, "pooled headline aggregates are back in the export: \(pooled)")

        // Positive control: the metric section and the per-arm aggregates stay.
        #expect(keys.contains("metric"), "the metric section header is gone")
        #expect(keys.contains("averageFreeWriteScore_threePhase"))
        #expect(keys.contains("averageFreeWriteScore_audio_phoneme"))
        #expect(keys.contains("schedulerEffectivenessProxy_threePhase"))
        // Row-level inputs stay: phase, score, schedulerPriority, probe, protocolRevision.
        #expect(text.contains("letter\(separator)phase\(separator)completed\(separator)score\(separator)schedulerPriority\(separator)"))
        #expect(text.contains("\(separator)probe\(separator)comparisonConfiguration\(separator)protocolRevision\(separator)"))
    }

    @Test("Single-participant csvData / tsvData omit the pooled headline aggregates too")
    func singleParticipantDelimitedOmitPooledHeadlines() {
        let csv = String(decoding: ParentDashboardExporter.csvData(
            from: fixture(), participantId: pid, progress: [:], enrolledAt: nil), as: UTF8.self)
        let tsv = String(decoding: ParentDashboardExporter.tsvData(
            from: fixture(), participantId: pid, progress: [:], enrolledAt: nil), as: UTF8.self)
        #expect(metricKeys(csv, sep: ",").filter(isPooledHeadline).isEmpty)
        #expect(metricKeys(tsv, sep: "\t").filter(isPooledHeadline).isEmpty)
        #expect(metricKeys(csv, sep: ",").contains("averageFreeWriteScore_threePhase"))
    }

    @Test("JSON thesisMetrics carries no pooled headline aggregate, and keeps the rows")
    func jsonOmitsPooledHeadlines() throws {
        let data = try ParentDashboardExporter.jsonData(
            from: fixture(), participantId: pid, progress: [:], rawTraces: [], enrolledAt: nil)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let metrics = try #require(obj["thesisMetrics"] as? [String: Any],
                                   "thesisMetrics object is gone entirely")
        for key in ["phaseCompletionRates", "averageFreeWriteScore", "schedulerEffectivenessProxy"] {
            #expect(metrics[key] == nil, "thesisMetrics.\(key) is back: \(String(describing: metrics[key]))")
        }
        let rows = try #require(obj["phaseSessionRecords"] as? [[String: Any]])
        #expect(rows.count == 6, "row-level records must all stay: \(rows.count)")

        // The combined (all-participants) JSON goes through the same type.
        let source = ParticipantExportSource(snapshot: fixture(), participantId: pid,
                                             progress: [:], rawTraces: [], enrolledAt: nil)
        let combined = try ParentDashboardExporter.combinedJSONData(participants: [source])
        let arr = try #require(try JSONSerialization.jsonObject(with: combined) as? [[String: Any]])
        let cm = try #require(arr.first?["thesisMetrics"] as? [String: Any])
        #expect(cm["averageFreeWriteScore"] == nil && cm["schedulerEffectivenessProxy"] == nil
                && cm["phaseCompletionRates"] == nil, "combined JSON still pools: \(cm.keys.sorted())")
    }
}
