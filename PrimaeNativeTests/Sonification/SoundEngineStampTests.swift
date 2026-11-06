// SoundEngineStampTests.swift
// PrimaeNativeTests — protocol r17 (2026-11-03)
//
// Every r17 phase row names the sound engine that rendered it
// (`PhaseDelivery.soundEngine`, export column `soundEngine`). Since the A/B
// ended (RULINGS 2026-11-03, TDPSOLA final) there is one engine, so the stamp
// is a constant: `LiveSonificationKernel.engineStamp`.

import Testing
import Foundation
@testable import PrimaeNative

@Suite("r17 sound-engine stamp")
@MainActor struct SoundEngineStampTests {

    @Test("rows stamp the one engine, TDPSOLA")
    func rowsCarryTheEngine() throws {
        let box = ThrowawayDefaults()
        let vm = TracingViewModel(TracingDependencies.stubReading(comparisonDefaults: box.defaults))
        vm.loadLetter(name: "A")
        #expect(LiveSonificationKernel.engineStamp == "TDPSOLA")
        #expect(vm.phaseRowContext(for: .observe, finalizedBy: .child).delivery?.soundEngine == "TDPSOLA")
    }

    @Test("the export column carries the stamp, last")
    func exportColumn() {
        #expect(ParentDashboardExporter.phaseRowAppendedColumns.dropLast(ParentDashboardExporter.envelopeColumns.count).last == "soundEngine")
        let rec = PhaseSessionRecord(letter: "A", phase: "guided", completed: true, score: 1, schedulerPriority: 0,
                                     context: PhaseRowContext(delivery: PhaseDelivery(soundEngine: "TDPSOLA")))
        #expect(ParentDashboardExporter.phaseRowAppendedFields(rec, participantId: UUID()).dropLast(ParentDashboardExporter.envelopeColumns.count).last == "TDPSOLA")
    }
}
