// R27ExportTests.swift
// PrimaeNativeTests
//
// Protocol r27's export changes (audit 2026-11-23, findings 3-5, and the
// shear column):
//   * `spatialFitShearDegrees` and `armSoundDelivered`, appended last;
//   * a comma-bearing field (`strokeOrder`) is quoted in TSV as in CSV;
//   * the combined JSON carries the enrolment block and the set-aside files.
// The probe filter on the means is `ProbeRowsExcludedFromMeansTests`; the
// shear fit itself is `SlantFitTests` / `SlantFitAngleTests`.

import Testing
import Foundation
@testable import PrimaeNative

@MainActor
@Suite struct R27ExportTests {

    private let pid = UUID(uuidString: "00000000-0000-0000-0000-00000000F027")!
    private let t0 = Date(timeIntervalSince1970: 1_793_200_000)

    private func record(audio: PilotAudioCondition = .phoneme, probe: String? = nil,
                        revision: Int? = StudyProtocol.revision, order: String? = nil,
                        shear: Double? = nil) -> PhaseSessionRecord {
        PhaseSessionRecord(letter: "A", phase: "freeWrite", completed: true, score: 0.5, schedulerPriority: 0,
                           condition: .threePhase, audioCondition: audio, recordedAt: t0,
                           strokeCount: order == nil ? nil : 2, strokeOrder: order, studyMode: true,
                           probe: probe, protocolRevision: revision,
                           context: PhaseRowContext(spatialFitShearDegrees: shear))
    }

    private func snapshot(_ records: [PhaseSessionRecord]) -> DashboardSnapshot {
        var s = DashboardSnapshot()
        s.phaseSessionRecords = records
        return s
    }

    private func delimited(_ snap: DashboardSnapshot, separator: String) -> String {
        let src = ParticipantExportSource(snapshot: snap, participantId: pid, progress: [:], rawTraces: [], enrolledAt: nil)
        return String(decoding: ParentDashboardExporter.combinedDelimitedData(participants: [src], separator: separator),
                      as: UTF8.self)
    }

    // MARK: columns

    @Test("r27: spatialFitShearDegrees and armSoundDelivered are the two phase-row columns before the final-test columns, and carry the row's values")
    func theTwoColumnsAreAppendedLast() throws {
        #expect(ParentDashboardExporter.r27Columns == ["spatialFitShearDegrees", "armSoundDelivered"])
        #expect(Array(ParentDashboardExporter.phaseRowAppendedColumns.dropLast(ParentDashboardExporter.finalTestColumns.count).suffix(2)) == ParentDashboardExporter.r27Columns)
        let text = delimited(snapshot([record(shear: -7.25)]), separator: ",")
        let block = try #require(DelimitedExport.block(in: text, headerPrefix: "letter,phase,completed"))
        #expect(Array(block.header.dropLast(ParentDashboardExporter.finalTestColumns.count).suffix(2)) == ["spatialFitShearDegrees", "armSoundDelivered"])
        #expect(block.rows.first?.count == block.header.count)
        #expect(block.value("spatialFitShearDegrees") == "-7.250", "\(String(describing: block.value("spatialFitShearDegrees")))")
        #expect(block.value("armSoundDelivered") == "true")
        // The legacy columns did not move.
        let legacyEnd = try #require(block.header.firstIndex(of: "spatialDeviationRaw"))
        #expect((block.header.firstIndex(of: "spatialFitShearDegrees") ?? -1) > legacyEnd)
    }

    @Test("r27: a row with no measured deviation leaves the shear column empty")
    func noShearNoValue() throws {
        let block = try #require(DelimitedExport.block(in: delimited(snapshot([record()]), separator: ","),
                                                       headerPrefix: "letter,phase,completed"))
        #expect(block.value("spatialFitShearDegrees") == "")
    }

    @Test("r27: the shear reaches the store file, comes back, and is a JSON key of the row")
    func shearSurvivesTheStoreAndIsInTheJSON() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shear-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = JSONParentDashboardStore(fileURL: url)
        store.recordPhaseSession(
            letter: "A", phase: "freeWrite", completed: true, score: 0.5, schedulerPriority: 0,
            condition: .threePhase, audioCondition: .phoneme, assessment: nil, recognition: nil,
            inputDevice: nil, rawTraceID: nil, trainedSubset: "AFI", phaseDurationSeconds: nil,
            frechetDistance: nil, checkpointCoverage: nil, spatialDeviation: 0.01, strokeCount: 1,
            strokeOrder: "0", reversedStrokeCount: 0, studyMode: true, probe: nil,
            comparisonConfiguration: nil, spatialDeviationRaw: 0.02,
            context: PhaseRowContext(finalizedBy: .child, spatialFitShearDegrees: 3.875))
        #expect(store.snapshot.phaseSessionRecords.first?.spatialFitShearDegrees == 3.875)
        await store.flush()
        let reloaded = JSONParentDashboardStore(fileURL: url)
        #expect(reloaded.snapshot.phaseSessionRecords.first?.spatialFitShearDegrees == 3.875,
                "the shear did not survive the store file")
        let json = try ParentDashboardExporter.jsonData(from: reloaded.snapshot, participantId: pid, enrolledAt: nil)
        let obj = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        let rows = try #require(obj["phaseSessionRecords"] as? [[String: Any]])
        #expect(rows.first?["spatialFitShearDegrees"] as? Double == 3.875)
        // An older row (no key) decodes with no shear.
        let old = #"{"letter":"A","phase":"freeWrite","completed":true,"score":0.7,"schedulerPriority":0}"#
        #expect(try StoreCoding.decoder().decode(PhaseSessionRecord.self, from: Data(old.utf8)).spatialFitShearDegrees == nil)
    }

    // MARK: armSoundDelivered

    @Test("r27: armSoundDelivered says what the child heard: silent arm and sound-off probes are false, the rest true",
          arguments: [
            // (audio, probe, revision, expected column)
            (PilotAudioCondition.phoneme, String?.none, Int?(27), "true"),
            (.spatial, nil, 27, "true"),
            (.silent, nil, 27, "false"),
            // r12 onward: every probe is sound-off in every arm.
            (.phoneme, "pretest", 26, "false"),
            (.spatial, "posttest", 12, "false"),
            (.phoneme, "delayed", 27, "false"),
            // r2-r11: a probe had the arm's sound (DECISIONS r12, "Data").
            (.phoneme, "pretest", 11, "true"),
            (.spatial, "posttest", 2, "true"),
            // r1 probes were sound-off; the silent arm never had sound.
            (.phoneme, "pretest", 1, "false"),
            (.silent, "pretest", 5, "false"),
            // A probe row with no revision (r1-r3) cannot say.
            (.phoneme, "pretest", nil, ""),
            (.silent, "pretest", nil, "false"),
          ] as [(PilotAudioCondition, String?, Int?, String)])
    func armSoundDeliveredRule(audio: PilotAudioCondition, probe: String?, revision: Int?, expected: String) throws {
        let rec = record(audio: audio, probe: probe, revision: revision)
        let fields = ParentDashboardExporter.phaseRowAppendedFields(rec, participantId: pid)
        let cell = fields.dropLast(ParentDashboardExporter.finalTestColumns.count).last
        #expect(cell == expected, "\(audio) probe=\(String(describing: probe)) r\(String(describing: revision)): \(String(describing: cell))")
        #expect(rec.audioCondition == audio, "audioCondition stays the ASSIGNED arm")
    }

    // MARK: quoting

    @Test("r27: a comma-bearing strokeOrder is quoted in the TSV as in the CSV, and the row keeps its column count",
          arguments: ["0,1", "0,2,1", "-,0"])
    func strokeOrderIsQuotedInBothFormats(order: String) throws {
        let snap = snapshot([record(order: order)])
        for sep in [",", "\t"] {
            let text = delimited(snap, separator: sep)
            let block = try #require(DelimitedExport.block(in: text, headerPrefix: "letter\(sep)phase\(sep)completed",
                                                           separator: Character(sep)))
            #expect(block.rows.first?.count == block.header.count, "sep \(sep.debugDescription): the row split into \(block.rows.first?.count ?? 0)")
            #expect(block.value("strokeOrder") == order)
            #expect(text.contains("\(sep)\"\(order)\"\(sep)"), "sep \(sep.debugDescription): \(order) is not quoted")
        }
    }

    @Test("r27: the quoting touches nothing else — plain fields and negative numbers stay bare")
    func quotingTouchesOnlyCommas() {
        let f = ParentDashboardExporter.delimitedField
        #expect(f("0,1", "\t") == "\"0,1\"")
        #expect(f("0,1", ",") == "\"0,1\"")
        #expect(f("0.250000", "\t") == "0.250000")
        #expect(f("-7.250", "\t") == "-7.250" && f("-7.250", ",") == "-7.250")
        #expect(f("A", "\t") == "A" && f("", "\t") == "")
        #expect(f("a\tb", "\t") == "\"a\tb\"")
        #expect(f("say \"hi\"", "\t") == "\"say \"\"hi\"\"\"")
        // No formula neutralisation: the file never did it, and a negative angle is data.
        #expect(f("=1+1", "\t") == "=1+1" && f("@x", ",") == "@x")
    }

    // MARK: combined JSON

    private func enrolments() -> [EnrolmentRecord] {
        [EnrolmentRecord(participantId: UUID(uuidString: "00000000-0000-0000-0000-00000000F0A1")!, enrolledAt: t0,
                         audioCondition: .spatial, trainedSubset: "FIL", protocolRevision: 27,
                         comparisonConfiguration: "observePasses=2", voiceId: "rec:kiki:0123456789ab",
                         environment: EnvironmentStamp(outputRoute: "BuiltInSpeaker", outputVolume: 0.5),
                         build: BuildStamp(launchId: "L-1", appVersion: "1.0 (27)")),
         // A child who enrolled and did nothing: only the enrolment block knows them.
         EnrolmentRecord(participantId: UUID(uuidString: "00000000-0000-0000-0000-00000000F0A2")!, enrolledAt: nil,
                         audioCondition: .silent, trainedSubset: "AIM", protocolRevision: 27)]
    }

    private func combinedJSON(enrolments: [EnrolmentRecord] = [], setAside: [ArchiveSetAside] = []) throws -> [[String: Any]] {
        let src = ParticipantExportSource(snapshot: snapshot([record(shear: 1.5)]), participantId: pid,
                                          progress: [:], rawTraces: [], enrolledAt: nil)
        let data = try ParentDashboardExporter.combinedJSONData(participants: [src], enrolments: enrolments, setAside: setAside)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }

    @Test("r27: the combined JSON carries the enrolment block as one extra LAST element; the participants stay as they were")
    func combinedJSONCarriesTheEnrolmentBlock() throws {
        let elements = try combinedJSON(enrolments: enrolments())
        #expect(elements.count == 2, "one participant plus the block")
        #expect(elements[0]["participantId"] as? String == pid.uuidString)
        #expect(elements[0]["enrolments"] == nil)
        let block = elements[1]
        #expect(block["participantId"] == nil, "the block must not read as a participant")
        let rows = try #require(block["enrolments"] as? [[String: Any]])
        #expect(rows.count == 2)
        #expect(rows[0]["participantId"] as? String == "00000000-0000-0000-0000-00000000F0A1")
        #expect(rows[0]["audioCondition"] as? String == "spatial")
        #expect(rows[0]["trainedSubset"] as? String == "FIL")
        #expect(rows[0]["protocolRevision"] as? Int == 27)
        #expect(rows[0]["comparisonConfiguration"] as? String == "observePasses=2")
        #expect(rows[0]["voiceId"] as? String == "rec:kiki:0123456789ab")
        let env = try #require(rows[0]["environment"] as? [String: String])
        #expect(env["outputRoute"] == "BuiltInSpeaker" && env["outputVolume"] == "0.5000")
        let build = try #require(rows[0]["build"] as? [String: String])
        #expect(build["launchId"] == "L-1" && build["appVersion"] == "1.0 (27)")
        // The zero-row dropout is in it, with its arm and subset, no environment.
        #expect(rows[1]["audioCondition"] as? String == "silent" && rows[1]["trainedSubset"] as? String == "AIM")
        #expect((rows[1]["environment"] as? [String: String])?.isEmpty == true)
        #expect(block["setAside"] == nil, "no set-aside file: no key, like the CSV's absent lines")
    }

    @Test("r27: set-aside archive files ride the block too, with the participant id read from the name")
    func combinedJSONCarriesTheSetAsideFiles() throws {
        let named = ArchiveSetAside(fileName: "00000000-0000-0000-0000-00000000F0A3_1793200000.json")
        let anon = ArchiveSetAside(fileName: "garbled.json")
        let elements = try combinedJSON(setAside: [named, anon])
        #expect(elements.count == 2)
        let aside = try #require(elements[1]["setAside"] as? [[String: Any]])
        #expect(aside.count == 2)
        #expect(aside[0]["fileName"] as? String == named.fileName)
        #expect(aside[0]["participantId"] as? String == "00000000-0000-0000-0000-00000000F0A3")
        #expect(aside[1]["fileName"] as? String == "garbled.json" && aside[1]["participantId"] == nil)
        #expect((elements[1]["enrolments"] as? [Any])?.isEmpty == true)
    }

    @Test("r27: with nothing to add the combined JSON is exactly what it was — no extra element, same bytes")
    func combinedJSONWithoutABlockIsUnchanged() throws {
        let src = ParticipantExportSource(snapshot: snapshot([record()]), participantId: pid,
                                          progress: [:], rawTraces: [], enrolledAt: nil)
        let plain = try ParentDashboardExporter.combinedJSONData(participants: [src])
        let explicit = try ParentDashboardExporter.combinedJSONData(participants: [src], enrolments: [], setAside: [])
        #expect(plain == explicit)
        let arr = try #require(try JSONSerialization.jsonObject(with: plain) as? [[String: Any]])
        #expect(arr.count == 1)
    }

    @Test("r27: the file the proctor shares (combinedExportFileURL) writes the block into the JSON")
    func theSharedJSONFileHasTheBlock() throws {
        let src = ParticipantExportSource(snapshot: snapshot([record()]), participantId: pid,
                                          progress: [:], rawTraces: [], enrolledAt: nil)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("r27-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try ParentDashboardExporter.combinedExportFileURL(
            participants: [src], enrolments: enrolments(), setAside: [], format: .json, tempDirectory: dir)
        let arr = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        #expect(arr.count == 2 && (arr[1]["enrolments"] as? [Any])?.count == 2)
        #expect(url.lastPathComponent.contains("_all1."), "all<N> counts participants, not enrolments: \(url.lastPathComponent)")
    }
}
