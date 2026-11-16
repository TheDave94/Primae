// Byte-comparison golden for the research CSV export (ROADMAP §4 D11 item 4).
//
// `ExporterArmStratificationTests` calls itself "golden coverage" but parses
// the metric section and asserts on rows; no checked-in expected output
// existed, so a change that left every parsed row intact — a reordered or
// renamed column, a number format, a header, the enrolment block, the r25
// attempt columns — could ship green. This suite compares the WHOLE file.
//
// WHAT IS COMPARED: `ParentDashboardExporter.combinedDelimitedData` (the file
// a proctor's batch export writes) over `GoldenExportFixture` — three
// children, one per thesis arm and per audio arm, a pre-enrolment row, an
// observe row, three scored free-writing rows, a rejected r25 attempt, a cold
// pretest probe row, and an enrolment-only dropout — against
// `GoldenExportExpected.csv`, as raw UTF-8 bytes.
//
// DETERMINISM, and what had to be injected. Every input is a literal (see the
// fixture's header) and the build / device / audio-environment stamps are
// plain value structs the fixture fills itself, so nothing is read from the
// machine. The ONE machine-dependent byte in the export was the
// `# timezone=` header (`TimeZone.current`); the exporter now takes it as a
// `timeZone:` parameter defaulting to `.current`, so production output is
// unchanged and this test pins Europe/Vienna. NO column is masked.
//
// Not covered here, by design: the JSON export and the TSV separator (same
// builder, different encoding) and the per-child `csvData` entry point, which
// shares `delimitedData` with the combined path exercised here.

import Testing
import Foundation
@testable import PrimaeNative

@Suite struct ExporterGoldenFileTests {

    @Test("The combined research CSV matches the checked-in golden byte for byte")
    func combinedCsvMatchesGoldenByteForByte() {
        let actual = GoldenExportFixture.csv()
        let expected = GoldenExportExpected.csv

        // Bytes, not `String ==`: Swift compares strings by canonical
        // equivalence, and a golden's job is to be literal.
        if Array(actual.utf8) == Array(expected.utf8) { return }

        let a = actual.components(separatedBy: "\n")
        let e = expected.components(separatedBy: "\n")
        var report = "The export no longer matches GoldenExportExpected.csv.\n"
        if let i = (0..<min(a.count, e.count)).first(where: { a[$0] != e[$0] }) {
            report += "First difference at line \(i + 1):\n  expected: \(e[i])\n  actual:   \(a[i])\n"
        } else {
            report += "Common prefix identical; expected \(e.count) lines, actual \(a.count).\n"
        }
        report += "\nIf the format change is deliberate, replace the literal in "
            + "GoldenExportExpected.swift with this full actual output:\n"
            + "-----BEGIN ACTUAL-----\n\(actual)-----END ACTUAL-----"
        Issue.record(Comment(rawValue: report))
    }

    /// The golden is only as strong as what it contains. A regeneration from
    /// a trimmed fixture would stay byte-identical to itself and cover less,
    /// so this pins what the golden must keep covering.
    @Test("The golden keeps covering every arm, the r25 columns, a probe row and the enrolment block")
    func goldenKeepsItsCoverage() {
        let golden = GoldenExportExpected.csv
        let lines = golden.components(separatedBy: "\n")

        for arm in ThesisCondition.allCases {
            #expect(lines.contains { $0.hasPrefix("averageFreeWriteScore_\(arm.rawValue),") },
                    "golden has no scored free-writing row for thesis arm \(arm.rawValue)")
        }
        for arm in PilotAudioCondition.allCases {
            #expect(lines.contains { $0.hasPrefix("averageFreeWriteScore_audio_\(arm.rawValue),") },
                    "golden has no scored free-writing row for audio arm \(arm.rawValue)")
        }
        for column in ParentDashboardExporter.attemptColumns {
            #expect(golden.contains(column), "golden lost the r25 column \(column)")
        }
        #expect(golden.contains(",attemptRejected,"), "golden has no rejected-attempt row")
        #expect(golden.contains(",pretest,"), "golden has no cold-probe row")
        #expect(golden.contains("# ==================== enrolments (not participants)"),
                "golden has no enrolment block")
        #expect(golden.contains("# timezone=Europe/Vienna"), "golden is not in the pinned timezone")
    }
}
