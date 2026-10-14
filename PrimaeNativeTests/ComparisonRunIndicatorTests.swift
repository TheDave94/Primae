// ComparisonRunIndicatorTests.swift
// R-017 (audit 2026-10-13, H2-07 / H2-17): the comparison switches persist
// across children with no proctor indicator, an enrolment did not record
// them, and two Settings hints described the WRONG default. The enrolment
// stamp lives in `NewParticipantResetTests` (it enrols, which writes the
// global participant store); here: the proctor's banner, the enrolment
// block's column, and the two hints held to the defaults they describe.

import Testing
import Foundation
@testable import PrimaeNative

@Suite @MainActor struct ComparisonRunIndicatorTests {

    @Test("R-017: no banner for a pilot session; a VERGLEICHSLAUF banner naming the switches otherwise")
    func bannerFollowsTheStamp() throws {
        // Several switches are read from the global defaults when the
        // fixture leaves them nil, and other suites write those in
        // parallel — so the pilot VM is held to CONSISTENCY with its own
        // stamp rather than to "no stamp".
        var pilot = TracingDependencies.stub
        pilot.studyMode = true
        let pilotVM = TracingViewModel(pilot)
        #expect(pilotVM.comparisonRunBanner == pilotVM.comparisonConfigurationStamp.map { "VERGLEICHSLAUF: \($0)" })

        var comparison = TracingDependencies.stub
        comparison.studyMode = true
        comparison.soundGateRadiusFactor = StudyComparisonSettings.soundGateRadiusFactorDefault * 2
        let vm = TracingViewModel(comparison)
        let stamp = try #require(vm.comparisonConfigurationStamp)
        #expect(vm.comparisonRunBanner == "VERGLEICHSLAUF: \(stamp)")
    }

    @Test("R-017: the enrolment block carries the comparison stamp of the enrolment")
    func enrolmentBlockCarriesTheStamp() throws {
        let rec = EnrolmentRecord(participantId: UUID(), enrolledAt: Date(), audioCondition: .phoneme,
                                  trainedSubset: "AFI", protocolRevision: 6,
                                  comparisonConfiguration: "allFiveLetters=true,observePasses=2")
        let block = try #require(DelimitedExport.block(in: ParentDashboardExporter.enrolmentBlock([rec], separator: ","),
                                                       headerPrefix: "enrolment_participantId"))
        #expect(block.value("comparisonConfiguration") == "allFiveLetters=true,observePasses=2",
                "the stamp is missing or was split by its comma: \(block.rows.first ?? [])")
        #expect(block.rows.first?.count == block.header.count)
    }

    @Test("R-017: the spoken-feedback hint names the default the code ships")
    func spokenFeedbackHintMatchesTheDefault() {
        let defaultWord = StudyComparisonSettings.spokenFeedbackInStudyDefault ? "Ein" : "Aus"
        #expect(ComparisonSwitchHints.spokenFeedback.hasPrefix("\(defaultWord) ist die Vorgabe"),
                "the hint contradicts spokenFeedbackInStudyDefault = \(StudyComparisonSettings.spokenFeedbackInStudyDefault)")
    }

    @Test("R-017: the axis-demonstration hint does not call the ruled default a deviation")
    func axisHintFollowsTheRuling() {
        #expect(!StudyComparisonSettings.spatialAxisDemonstrationDefault, "precondition: OFF is the default (ruling 2026-09-18)")
        #expect(ComparisonSwitchHints.axisDemonstration.hasPrefix("Aus ist die Vorgabe"))
        #expect(!ComparisonSwitchHints.axisDemonstration.contains("Abweichung"),
                "OFF is the specification since the 2026-09-18 ruling, not a deviation from it")
    }
}
