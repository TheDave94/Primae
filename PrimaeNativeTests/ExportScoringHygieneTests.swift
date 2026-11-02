// ExportScoringHygieneTests.swift
//
// Pins for fix lane L4 (2026-11-02): A14 (duration `date` column is
// Gregorian), A15 (undefined aggregates are null / empty, not 0), A16
// (fractional-second timestamps, `NaN` spelling, trailing newline), A17
// (`topThree` descending), A18 (non-finite points), A19 (one stroke analysis,
// identical output). Each was written against a defect found by the bug-hunt
// rounds and must go RED when its fix is reverted.

import Testing
import Foundation
import CoreGraphics
@testable import PrimaeNative

private func source(_ snap: DashboardSnapshot, enrolledAt: Date? = nil) -> ParticipantExportSource {
    ParticipantExportSource(snapshot: snap, participantId: UUID(), progress: [:], rawTraces: [], enrolledAt: enrolledAt)
}

private func csv(_ sources: [ParticipantExportSource], enrolments: [EnrolmentRecord] = [], sep: String = ",") -> String {
    String(decoding: ParentDashboardExporter.combinedDelimitedData(participants: sources, enrolments: enrolments, separator: sep),
           as: UTF8.self)
}

@MainActor
struct ExportHygieneTests {

    // MARK: A14

    @Test("A14: the duration 'date' column is Gregorian under a Buddhist device calendar")
    func durationDateColumnIsGregorian() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("L4-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var cal = Calendar(identifier: .buddhist)
        cal.timeZone = TimeZone(identifier: "Europe/Vienna")!
        let store = JSONParentDashboardStore(fileURL: dir.appendingPathComponent("d.json"), calendar: cal,
                                             failureCenter: PersistenceFailureCenter())
        let when = Date(timeIntervalSince1970: 1_793_000_000)   // 2026-10-26 07:33 UTC
        store.recordSession(letter: "F", accuracy: 0.5, durationSeconds: 12, date: when, condition: .threePhase)
        let column = try #require(store.snapshot.sessionDurations.first?.dateString)
        #expect(column == ParentDashboardExporter.dateTag(when, deviceCalendar: cal))
        #expect(column == "2026-10-26")
        // The chart reader looks the same key up through the same calendar.
        let minutes = store.snapshot.dailyPracticeMinutes(days: 1, referenceDate: when, calendar: cal)
        #expect(minutes.first?.minutes == 12.0 / 60.0, "chart lookup missed the Gregorian key: \(minutes)")
        await store.flush()
    }

    // MARK: A15

    private func dropoutSnapshot() -> DashboardSnapshot {
        var snap = DashboardSnapshot()
        snap.phaseSessionRecords = [
            PhaseSessionRecord(letter: "A", phase: "observe", completed: true, score: 1, schedulerPriority: 0),
            PhaseSessionRecord(letter: "A", phase: "direct", completed: false, score: 0, schedulerPriority: 0),
        ]
        return snap
    }

    @Test("A15: with no scored freeWrite the CSV cell is empty and the JSON value is null")
    func undefinedAggregatesAreNullNotZero() throws {
        let src = source(dropoutSnapshot())
        let lines = csv([src]).components(separatedBy: "\n")
        #expect(lines.contains("averageFreeWriteScore,"), "csv averageFreeWriteScore: \(lines.filter { $0.hasPrefix("averageFreeWriteScore") })")
        #expect(lines.contains("schedulerEffectivenessProxy,"))
        let json = try ParentDashboardExporter.combinedJSONData(participants: [src])
        let obj = try #require(try JSONSerialization.jsonObject(with: json) as? [[String: Any]])
        let metrics = try #require(obj.first?["thesisMetrics"] as? [String: Any])
        #expect(metrics["averageFreeWriteScore"] is NSNull, "avg: \(String(describing: metrics["averageFreeWriteScore"]))")
        #expect(metrics["schedulerEffectivenessProxy"] is NSNull, "proxy: \(String(describing: metrics["schedulerEffectivenessProxy"]))")
    }

    @Test("A15: a real mean of 0 is still written as 0.0000 (null is for undefined only)")
    func realZeroStaysZero() throws {
        var snap = DashboardSnapshot()
        snap.phaseSessionRecords = [PhaseSessionRecord(letter: "A", phase: "freeWrite", completed: true, score: 0, schedulerPriority: 0)]
        #expect(snap.averageFreeWriteScoreIfDefined == 0)
        #expect(csv([source(snap)]).components(separatedBy: "\n").contains("averageFreeWriteScore,0.0000"))
    }

    // MARK: A16

    @Test("A16: two rows 500 ms apart keep distinct timestamps, in CSV and JSON")
    func fractionalSeconds() throws {
        let t = Date(timeIntervalSince1970: 1_793_000_000.25)
        var snap = DashboardSnapshot()
        snap.phaseSessionRecords = [
            PhaseSessionRecord(letter: "F", phase: "guided", completed: false, score: 0.3, schedulerPriority: 0, recordedAt: t, rowId: UUID()),
            PhaseSessionRecord(letter: "F", phase: "freeWrite", completed: false, score: 0, schedulerPriority: 0,
                               recordedAt: t.addingTimeInterval(0.5), rowId: UUID()),
        ]
        let src = source(snap, enrolledAt: t.addingTimeInterval(-60.5))
        let text = csv([src])
        #expect(text.contains("2026-10-26T07:33:20.250Z"), "CSV recordedAt lost its fraction")
        #expect(text.contains("2026-10-26T07:33:20.750Z"))
        #expect(text.contains("# enrolledAt=2026-10-26T07:32:19.750Z"), "enrolledAt lost its fraction")
        let enrol = EnrolmentRecord(participantId: UUID(), enrolledAt: t, audioCondition: .phoneme, trainedSubset: "AFI", protocolRevision: 15)
        #expect(csv([src], enrolments: [enrol]).contains("2026-10-26T07:33:20.250Z,phoneme"), "enrolment block enrolledAt lost its fraction")
        let json = String(decoding: try ParentDashboardExporter.combinedJSONData(participants: [src]), as: UTF8.self)
        #expect(json.contains("2026-10-26T07:33:20.250Z") && json.contains("2026-10-26T07:33:20.750Z"),
                "JSON dates lost their fraction")
    }

    @Test("A16: a NaN score is written NaN in CSV and TSV, never nan")
    func nanSpelling() {
        var snap = DashboardSnapshot()
        snap.phaseSessionRecords = [PhaseSessionRecord(letter: "A", phase: "guided", completed: false, score: .nan, schedulerPriority: 0)]
        for sep in [",", "\t"] {
            let text = csv([source(snap)], sep: sep)
            let row = text.components(separatedBy: "\n").first { $0.hasPrefix("A\(sep)guided") } ?? ""
            let fields = row.components(separatedBy: sep)
            #expect(fields.count > 3 && fields[3] == "NaN", "score field: \(fields.count > 3 ? fields[3] : "-") in \(row)")
            #expect(!text.contains("nan"), "lowercase nan survives in the export")
        }
    }

    @Test("A16: the combined CSV/TSV ends with a newline, with and without an enrolment block")
    func combinedCSVEndsWithNewline() {
        let src = source(dropoutSnapshot())
        let enrol = EnrolmentRecord(participantId: UUID(), enrolledAt: nil, audioCondition: .silent, trainedSubset: "AFI", protocolRevision: 15)
        for sep in [",", "\t"] {
            #expect(csv([src], sep: sep).hasSuffix("\n"))
            #expect(csv([src], enrolments: [enrol], sep: sep).hasSuffix("\n"))
            #expect(!csv([src], sep: sep).hasSuffix("\n\n"))
        }
    }
}

// MARK: - A17

@MainActor
struct TopThreeOrderTests {
    @Test("A17: topThree is descending by calibrated confidence; predictedLetter stays the raw top-1")
    func topThreeDescending() throws {
        // I is a default confusable (penalty 0.15): 0.55 -> 0.40, below L's 0.45.
        let cal = ConfidenceCalibrator()
        let r = try #require(CoreMLLetterRecognizer.makeResult(
            from: [LetterClassification(identifier: "I", confidence: 0.55),
                   LetterClassification(identifier: "L", confidence: 0.45)],
            expectedLetter: "I", calibrator: cal, historicalFormScores: []))
        let confs = r.topThree.map(\.confidence)
        #expect(confs == confs.sorted(by: >), "not descending: \(r.topThree)")
        #expect(r.topThree.first?.letter == "L", "after calibration L (0.45) outranks I (0.40): \(r.topThree)")
        #expect(r.predictedLetter == "I", "predictedLetter is the RAW top-1")
        #expect(r.isCorrect)
    }

    @Test("A17: equal calibrated confidences keep the model's order")
    func ties() throws {
        let cal = ConfidenceCalibrator(confusableLetters: [])
        let r = try #require(CoreMLLetterRecognizer.makeResult(
            from: [LetterClassification(identifier: "A", confidence: 0.4),
                   LetterClassification(identifier: "B", confidence: 0.4),
                   LetterClassification(identifier: "C", confidence: 0.4)],
            expectedLetter: nil, calibrator: cal, historicalFormScores: []))
        #expect(r.topThree.map(\.letter) == ["A", "B", "C"])
    }
}

// MARK: - A18 / A19

@MainActor
struct StrokeAnalysisTests {

    static func references() throws -> [LetterStrokes] {
        let repo = LetterRepository(resources: BundleLetterResourceProvider(), cache: NullLetterCache())
        let letters = try repo.loadBundledLettersOnly().get()
        return try TrainedLetterSubset.studyLetters.map { name in
            try #require(letters.first { $0.name == name }, "study letter \(name) not in the bundle").strokes
        }
    }

    /// A deterministic, slightly wobbly trace along the reference strokes.
    static func trace(_ ref: LetterStrokes, wobble: CGFloat) -> (points: [CGPoint], starts: [Int]) {
        var pts: [CGPoint] = []
        var starts: [Int] = []
        for stroke in ref.strokes {
            if !pts.isEmpty { starts.append(pts.count) }
            let c = stroke.checkpoints
            for i in 0..<max(c.count - 1, 0) {
                for k in 0..<8 {
                    let f = CGFloat(k) / 8
                    let n = CGFloat((pts.count * 7919) % 13) / 13 - 0.5
                    pts.append(CGPoint(x: c[i].x + (c[i + 1].x - c[i].x) * f + n * wobble,
                                       y: c[i].y + (c[i + 1].y - c[i].y) * f - n * wobble))
                }
            }
            if let last = c.last { pts.append(CGPoint(x: last.x, y: last.y)) }
        }
        return (pts, starts)
    }

    @Test("A18: a non-finite sample is dropped, not propagated; the clean trace's measures come back")
    func nonFiniteInput() throws {
        let ref = try Self.references()[3]           // L
        let clean = Self.trace(ref, wobble: 0.01)
        let expected = try #require(StrokeProcessScorer.analyze(points: clean.points, strokeStartIndices: clean.starts, reference: ref))
        // Same trace with NaN / infinity spliced in at stroke-interior positions.
        var pts = clean.points
        var starts = clean.starts
        pts.insert(CGPoint(x: CGFloat.nan, y: 0.5), at: 3)
        pts.insert(CGPoint(x: 0.5, y: CGFloat.infinity), at: 9)
        starts = starts.map { $0 + 2 }
        let m = try #require(StrokeProcessScorer.analyze(points: pts, strokeStartIndices: starts, reference: ref),
                             "non-finite input made the whole trace unscorable")
        #expect(m == expected)
        #expect(m.spatialDeviation.isFinite && m.spatialDeviationRaw.isFinite)
        let form = FreeWriteScorer.score(tracedPoints: pts, strokeStartIndices: starts, reference: ref).formAccuracy
        #expect(form.isFinite && form > 0)
    }

    @Test("A18: fewer than two finite points is not a production")
    func tooFewFinitePoints() throws {
        let ref = try Self.references()[3]
        let pts = [CGPoint(x: CGFloat.nan, y: 0), CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0, y: CGFloat.nan)]
        #expect(StrokeProcessScorer.analyze(points: pts, strokeStartIndices: [], reference: ref) == nil)
    }

    @Test("A19: the recorder's assessment and stroke process equal the two standalone calls (golden), 5 letters + 60 strokes")
    func goldenEquality() throws {
        let refs = try Self.references()
        let canvas = CGSize(width: 1000, height: 1000)
        var cases: [(String, LetterStrokes, [CGPoint], [Int])] = []
        for (i, ref) in refs.enumerated() {
            for wobble in [0.0, 0.02] as [CGFloat] {
                let t = Self.trace(ref, wobble: wobble)
                cases.append(("\(TrainedLetterSubset.studyLetters[i]) wobble \(wobble)", ref, t.points, t.starts))
            }
        }
        // 60 short strokes against A.
        var pts: [CGPoint] = []
        var starts: [Int] = []
        for s in 0..<60 {
            if s > 0 { starts.append(pts.count) }
            let a = CGPoint(x: 0.1 + CGFloat(s % 10) * 0.07, y: 0.1 + CGFloat(s / 10) * 0.12)
            pts += [a, CGPoint(x: a.x + 0.02, y: a.y + 0.01), CGPoint(x: a.x + 0.04, y: a.y + 0.005)]
        }
        cases.append(("A 60 strokes", refs[0], pts, starts))

        for (label, ref, points, strokeStarts) in cases {
            let recorder = FreeWritePhaseRecorder()
            recorder.startSession(now: 0)
            var next = strokeStarts[...]
            for (i, p) in points.enumerated() {
                if next.first == i { recorder.beginStroke(); next = next.dropFirst() }
                recorder.record(point: CGPoint(x: p.x * canvas.width, y: p.y * canvas.height),
                                timestamp: CFTimeInterval(i) * 0.016, force: 0.4 + CGFloat(i % 5) * 0.05, canvasSize: canvas)
            }
            let now: CFTimeInterval = CFTimeInterval(points.count) * 0.016 + 1
            let got = recorder.assess(reference: ref, canvasSize: canvas, now: now)

            // The OLD behaviour: two independent calls on the same inputs.
            let normalised = recorder.points.map { CGPoint(x: ($0.x - 0) / max(canvas.width, 1), y: ($0.y - 0) / max(canvas.height, 1)) }
            let oldAssessment = FreeWriteScorer.score(
                tracedPoints: normalised, strokeStartIndices: recorder.strokeStartIndices, reference: ref,
                timestamps: recorder.timestamps, forces: recorder.forces, sessionStart: recorder.sessionStart, sessionEnd: now)
            let oldProcess = StrokeProcessScorer.analyze(points: normalised, strokeStartIndices: recorder.strokeStartIndices, reference: ref)

            #expect(got == oldAssessment, "\(label): assessment differs")
            #expect(recorder.lastStrokeProcess == oldProcess, "\(label): stroke process differs")
            #expect(recorder.lastStrokeProcess != nil, "\(label): vacuous, analyze returned nil")
        }
        #expect(cases.count == 11)
    }

    @Test("A19: score(measures:) uses the analysis it is given and does not recompute it")
    func suppliedMeasuresAreUsed() throws {
        let ref = try Self.references()[3]
        // A trace analyze would score poorly...
        let far = [CGPoint(x: 0.9, y: 0.9), CGPoint(x: 0.95, y: 0.95), CGPoint(x: 0.99, y: 0.9)]
        // ...scored with a supplied perfect deviation.
        let perfect = StrokeProcessMeasures(spatialDeviation: 0, spatialDeviationRaw: 0, strokeCount: 1,
                                            matchedReferenceOrder: [0], reversedStrokeCount: 0)
        let supplied = FreeWriteScorer.score(tracedPoints: far, reference: ref, measures: perfect)
        #expect(supplied.formAccuracy == 1, "formAccuracy was recomputed instead of read from the supplied measures")
        let computed = FreeWriteScorer.score(tracedPoints: far, reference: ref)
        #expect(computed.formAccuracy < 1)
        #expect(FreeWriteScorer.score(tracedPoints: far, reference: ref, measures: nil).formAccuracy == 0)
    }
}
