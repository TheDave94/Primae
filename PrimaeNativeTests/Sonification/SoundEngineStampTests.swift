// SoundEngineStampTests.swift
// PrimaeNativeTests — protocol r17 (2026-11-03)
//
// Every r17 phase row names the sound engine that rendered it
// (`PhaseDelivery.soundEngine`, export column `soundEngine`). Since the A/B
// ended (RULINGS 2026-11-03, TDPSOLA final) there is one engine per arm; from
// protocol r31 the phoneme arm's is TDPSOLA2 (pitch bake-off), so the stamp
// follows the row's arm: `LiveSonificationKernel.engineStamp(for:)`.

import Testing
import Foundation
@testable import PrimaeNative

@Suite("r17 sound-engine stamp")
@MainActor struct SoundEngineStampTests {

    @Test("rows stamp their arm's engine: TDPSOLA2 in the phoneme arm, TDPSOLA in the spatial and silent arms",
          arguments: PilotAudioCondition.allCases)
    func rowsCarryTheEngine(arm: PilotAudioCondition) throws {
        let box = ThrowawayDefaults()
        let vm = TracingViewModel(TracingDependencies.stubReading(comparisonDefaults: box.defaults).with(audioCondition: arm))
        vm.loadLetter(name: "A")
        #expect(vm.audioCondition == arm)
        let want = arm == .phoneme ? "TDPSOLA2" : "TDPSOLA"
        #expect(vm.phaseRowContext(for: .observe, finalizedBy: .child).delivery?.soundEngine == want)
    }

    @Test("the export column carries the stamp, last")
    func exportColumn() {
        #expect(ParentDashboardExporter.phaseRowAppendedColumns.dropLast(ParentDashboardExporter.envelopeColumns.count + ParentDashboardExporter.attemptColumns.count + ParentDashboardExporter.r27Columns.count + ParentDashboardExporter.finalTestColumns.count).last == "soundEngine")
        let rec = PhaseSessionRecord(letter: "A", phase: "guided", completed: true, score: 1, schedulerPriority: 0,
                                     context: PhaseRowContext(delivery: PhaseDelivery(soundEngine: "TDPSOLA")))
        #expect(ParentDashboardExporter.phaseRowAppendedFields(rec, participantId: UUID()).dropLast(ParentDashboardExporter.envelopeColumns.count + ParentDashboardExporter.attemptColumns.count + ParentDashboardExporter.r27Columns.count + ParentDashboardExporter.finalTestColumns.count).last == "TDPSOLA")
    }
}
