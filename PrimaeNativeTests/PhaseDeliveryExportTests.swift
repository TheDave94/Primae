// PhaseDeliveryExportTests.swift
// R-020 (audit 2026-10-13), export half: what a phase delivered — its
// interruptions, cancelled strokes, observe restarts, device route changes,
// the output route at its start and end, the device state at its start,
// the voice, the recognizer, the binary and the launch — and why its row
// was written (`finalizedBy`) reach the CSV and the JSON, appended after
// every legacy column; the enrolment block carries the device state and
// the build at enrolment. Old files decode, with empty cells.
//
// Round trip: row → store file → reloaded store → export.

import Testing
import Foundation
@testable import PrimaeNative

@Suite @MainActor struct PhaseDeliveryExportTests {

    static let environment = EnvironmentStamp(
        outputRoute: "Headphones", outputVolume: 0.5, outputLatency: 0.005,
        otherAudioPlaying: true, secondaryAudioHint: false, guidedAccess: true,
        idleTimerDisabled: true, lowPowerMode: false, thermalState: "fair", batteryLevel: 0.8)
    static let build = BuildStamp(
        launchId: "L-1", previousRunAbnormal: true, appVersion: "1.0 (7)",
        buildConfiguration: "release", buildUUID: "B-UUID", osVersion: "Version 27.2",
        deviceModel: "iPad13,1")
    static let delivery = PhaseDelivery(
        observeRestarts: 1, strokesCancelled: 2, routeChanges: 3, interruptions: 4,
        atStart: environment, outputRouteAtEnd: "Speaker", voiceId: "com.apple.voice.premium.de-DE.Anna",
        recognizerAvailable: false, build: build)

    /// Every delivery column and the value the row above must export.
    static let expected: [(String, String)] = [
        ("finalizedBy", "background"),
        ("observeRestarts", "1"), ("strokesCancelled", "2"), ("routeChanges", "3"), ("interruptions", "4"),
        ("outputRouteAtStart", "Headphones"), ("outputRouteAtEnd", "Speaker"),
        ("outputVolume", "0.5000"), ("outputLatency", "0.005000"),
        ("otherAudioPlaying", "true"), ("secondaryAudioHint", "false"),
        ("voiceId", "com.apple.voice.premium.de-DE.Anna"), ("recognizerAvailable", "false"),
        ("guidedAccess", "true"), ("idleTimerDisabled", "true"), ("lowPowerMode", "false"),
        ("thermalState", "fair"), ("batteryLevel", "0.8000"),
        ("launchId", "L-1"), ("previousRunAbnormal", "true"), ("appVersion", "1.0 (7)"),
        ("buildConfiguration", "release"), ("buildUUID", "B-UUID"),
        ("osVersion", "Version 27.2"), ("deviceModel", "iPad13,1"),
    ]

    private func csvText(_ snap: DashboardSnapshot) -> String {
        String(data: ParentDashboardExporter.csvData(from: snap, participantId: UUID(),
                                                     progress: [:], enrolledAt: nil), encoding: .utf8)!
    }

    @Test("R-020: every delivery column reaches the CSV with the row's value, across the disk")
    func deliveryReachesTheCSV() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("delivery-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = JSONParentDashboardStore(fileURL: url)
        store.recordPhaseSession(
            letter: "A", phase: "freeWrite", completed: true, score: 0.5, schedulerPriority: 0,
            condition: .threePhase, audioCondition: .phoneme, assessment: nil, recognition: nil,
            inputDevice: "finger", rawTraceID: nil, trainedSubset: "AFI", phaseDurationSeconds: nil,
            frechetDistance: nil, checkpointCoverage: nil, spatialDeviation: nil, strokeCount: nil,
            strokeOrder: nil, reversedStrokeCount: nil, studyMode: true, probe: nil,
            comparisonConfiguration: nil, spatialDeviationRaw: nil,
            context: PhaseRowContext(finalizedBy: .background, delivery: Self.delivery))
        await store.flush()
        let reloaded = JSONParentDashboardStore(fileURL: url)
        #expect(reloaded.snapshot.phaseSessionRecords.first?.delivery == Self.delivery,
                "the delivery did not survive the store file")

        let block = try #require(DelimitedExport.block(in: csvText(reloaded.snapshot), headerPrefix: "letter,phase,completed"))
        #expect(block.rows.first?.count == block.header.count)
        for (column, value) in Self.expected {
            #expect(block.value(column) == value, "\(column): \(String(describing: block.value(column))) ≠ \(value)")
        }
        // Appended after the legacy columns, never between them.
        let legacyEnd = try #require(block.header.firstIndex(of: "spatialDeviationRaw"))
        for (column, _) in Self.expected {
            #expect((block.header.firstIndex(of: column) ?? -1) > legacyEnd, "\(column) is not after the legacy columns")
        }
    }

    @Test("R-020: the JSON export carries the delivery and finalizedBy, and decodes back to them")
    func deliveryReachesTheJSON() throws {
        var snap = DashboardSnapshot()
        snap.phaseSessionRecords.append(PhaseSessionRecord(
            letter: "A", phase: "guided", completed: false, score: 0.2, schedulerPriority: 0,
            context: PhaseRowContext(finalizedBy: .navigation, delivery: Self.delivery)))
        let data = try ParentDashboardExporter.jsonData(from: snap, participantId: UUID(), progress: [:], enrolledAt: nil)
        struct Envelope: Decodable { let phaseSessionRecords: [PhaseSessionRecord] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(Envelope.self, from: data).phaseSessionRecords
        #expect(back.first?.finalizedBy == "navigation")
        #expect(back.first?.delivery == Self.delivery)
    }

    @Test("R-020: a row written before the delivery existed decodes, and exports empty delivery cells")
    func oldRowHasEmptyDeliveryCells() throws {
        let old = #"{"letter":"A","phase":"guided","completed":true,"score":0.7,"schedulerPriority":0,"condition":"threePhase","audioCondition":"spatial"}"#
        let rec = try StoreCoding.decoder().decode(PhaseSessionRecord.self, from: Data(old.utf8))
        #expect(rec.delivery == nil && rec.finalizedBy == nil)
        var snap = DashboardSnapshot()
        snap.phaseSessionRecords = [rec]
        let block = try #require(DelimitedExport.block(in: csvText(snap), headerPrefix: "letter,phase,completed"))
        #expect(block.rows.first?.count == block.header.count)
        for (column, _) in Self.expected {
            #expect(block.value(column) == "", "\(column) is not empty on an old row")
        }
        // A malformed delivery costs only itself, not the row.
        let malformed = #"{"letter":"A","phase":"guided","completed":true,"score":0.7,"schedulerPriority":0,"delivery":{"routeChanges":"many"},"finalizedBy":7}"#
        let kept = try StoreCoding.decoder().decode(PhaseSessionRecord.self, from: Data(malformed.utf8))
        #expect(kept.letter == "A" && kept.finalizedBy == nil)
        #expect(kept.delivery?.routeChanges == nil)
    }

    @Test("R-020: the enrolment block carries the device state and build at enrolment; old records decode")
    func enrolmentBlockCarriesEnvironment() throws {
        let rec = EnrolmentRecord(participantId: UUID(), enrolledAt: Date(timeIntervalSince1970: 1_770_000_000),
                                  audioCondition: .spatial, trainedSubset: "AFI", protocolRevision: 6,
                                  comparisonConfiguration: nil, voiceId: nil,
                                  environment: Self.environment, build: Self.build)
        let text = ParentDashboardExporter.enrolmentBlock([rec], separator: ",")
        let block = try #require(DelimitedExport.block(in: text, headerPrefix: "enrolment_participantId"))
        #expect(Array(block.header.prefix(5)) == ["enrolment_participantId", "enrolledAt", "audioCondition", "trainedSubset", "protocolRevision"],
                "the legacy enrolment columns moved")
        #expect(block.rows.first?.count == block.header.count)
        let enrolmentExpected: [(String, String)] = [
            ("outputRoute", "Headphones"), ("outputVolume", "0.5000"), ("otherAudioPlaying", "true"),
            ("guidedAccess", "true"), ("lowPowerMode", "false"), ("batteryLevel", "0.8000"),
            ("launchId", "L-1"), ("previousRunAbnormal", "true"), ("buildUUID", "B-UUID"),
            ("deviceModel", "iPad13,1"),
        ]
        for (column, value) in enrolmentExpected {
            #expect(block.value(column) == value, "\(column): \(String(describing: block.value(column)))")
        }

        let old = #"{"participantId":"6F1C1D2E-0000-4000-8000-000000000001","enrolledAt":781000000,"audioCondition":"silent","trainedSubset":"AFI","protocolRevision":4}"#
        let decoded = try StoreCoding.decoder().decode(EnrolmentRecord.self, from: Data(old.utf8))
        #expect(decoded.environment == nil && decoded.build == nil && decoded.voiceId == nil
                && decoded.comparisonConfiguration == nil)
        let oldBlock = try #require(DelimitedExport.block(in: ParentDashboardExporter.enrolmentBlock([decoded], separator: ","),
                                                          headerPrefix: "enrolment_participantId"))
        #expect(oldBlock.rows.first?.count == oldBlock.header.count)
        #expect(oldBlock.value("buildUUID") == "")
    }
}
