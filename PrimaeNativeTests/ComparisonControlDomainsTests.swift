// ComparisonControlDomainsTests.swift
// PrimaeNativeTests
//
// Holds what the proctor's "Vergleichsmodus" panel OFFERS
// (`ComparisonControlDomains`, read by `SettingsView`) to what the store it
// writes to DOES (`StudyComparisonSettings`).
//
// The store's own behaviour — keys, defaults, clamps, reset — is covered
// elsewhere (`StudyComparisonSwitchesTests`, `ComparisonSeamDefaultsTests`,
// `ComparisonResetChangeTests`). What nothing covered is the join: the panel's
// option lists, ranges and "(Vorgabe)" labels lived inline in a view no test
// can construct. These tests reach the store only through a throwaway
// `UserDefaults` suite (`ThrowawayDefaults`), never `.standard`.
//
// NOT COVERED HERE, and why: the 26 write-through bindings and the 26-line
// "Vergleichsmodus zurücksetzen" mirror stay inline in the view. Their
// setters call static properties on `UserDefaults.standard`, which a parallel
// test must not touch, and a `Binding` cannot be read without the view.

import Testing
import Foundation
@testable import PrimaeNative

@Suite @MainActor struct ComparisonControlDomainsTests {

    private typealias S = StudyComparisonSettings
    private typealias C = StudyComparisonConfiguration

    // MARK: - Probes

    /// One picker, type-erased so the same checks run over every one.
    private struct PickerProbe {
        let name: String
        let labels: [String]
        let values: [AnyHashable]
        let defaultValue: AnyHashable
        /// Each offered value written to a fresh store and read back through
        /// the store's own resolution (clamps included).
        let resolved: [AnyHashable]
    }

    private func picker<V: Hashable>(
        _ name: String,
        _ options: [ComparisonOption<V>],
        default defaultValue: V,
        write: (UserDefaults, V) -> Void,
        read: (C) -> V
    ) -> PickerProbe {
        let resolved: [AnyHashable] = options.map { option in
            let box = ThrowawayDefaults()
            write(box.defaults, option.value)
            return AnyHashable(read(S.configuration(in: box.defaults)))
        }
        return PickerProbe(name: name,
                           labels: options.map(\.label),
                           values: options.map { AnyHashable($0.value) },
                           defaultValue: AnyHashable(defaultValue),
                           resolved: resolved)
    }

    private var pickers: [PickerProbe] {
        typealias D = ComparisonControlDomains
        return [
            picker("Vorzeigen", D.observePasses, default: S.observePassesDefault,
                   write: { $0.set($1, forKey: S.observePassesKey) }, read: { $0.observePasses }),
            picker("Wiederholungen je Buchstabe", D.letterRepeatCount, default: S.letterRepeatCountDefault,
                   write: { $0.set($1, forKey: S.letterRepeatCountKey) }, read: { $0.letterRepeatCount }),
            picker("Höhe steuert Tonhöhe", D.pitchScope, default: S.pitchScopeDefault,
                   write: { $0.set($1.rawValue, forKey: S.pitchScopeKey) }, read: { $0.pitchScope }),
            picker("Tonumfang der Höhe", D.pitchRangeCents, default: S.pitchRangeCentsDefault,
                   write: { $0.set($1, forKey: S.pitchRangeCentsKey) }, read: { $0.pitchRangeCents }),
            picker("Ton-Trigger: Nähe", D.soundGateRadiusFactor, default: S.soundGateRadiusFactorDefault,
                   write: { $0.set($1, forKey: S.soundGateRadiusFactorKey) }, read: { $0.soundGateRadiusFactor }),
            picker("Ton-Trigger: Bewegung", D.soundGateVelocityFloor, default: S.soundGateVelocityFloorDefault,
                   write: { $0.set($1, forKey: S.soundGateVelocityFloorKey) }, read: { $0.soundGateVelocityFloor }),
        ]
    }

    /// One stepper: its domain, the store default, and how to write/read it.
    private struct StepperProbe {
        let name: String
        let domain: ComparisonStepperDomain
        let defaultValue: Double
        let key: String
        let read: (C) -> Double
    }

    private var steppers: [StepperProbe] {
        typealias D = ComparisonControlDomains
        return [
            StepperProbe(name: "Abstand: Dämpfung", domain: D.distanceToneFarLevelDB,
                         defaultValue: S.distanceToneFarLevelDBDefault,
                         key: S.distanceToneFarLevelDBKey, read: { $0.distanceToneFarLevelDB }),
            StepperProbe(name: "Abstand: Grenzfrequenz", domain: D.distanceToneFarCutoffHz,
                         defaultValue: S.distanceToneFarCutoffHzDefault,
                         key: S.distanceToneFarCutoffHzKey, read: { $0.distanceToneFarCutoffHz }),
            StepperProbe(name: "Richtung: Schwelle", domain: D.directionMuteBackwardCosine,
                         defaultValue: S.directionMuteBackwardCosineDefault,
                         key: S.directionMuteBackwardCosineKey, read: { $0.directionMuteBackwardCosine }),
            StepperProbe(name: "Stiftdruck: Umfang", domain: D.pressureLoudnessRangeDB,
                         defaultValue: S.pressureLoudnessRangeDBDefault,
                         key: S.pressureLoudnessRangeDBKey, read: { $0.pressureLoudnessRangeDB }),
            StepperProbe(name: "Rauheit: Tiefe", domain: D.dysfluencyRoughnessDepth,
                         defaultValue: S.dysfluencyRoughnessDepthDefault,
                         key: S.dysfluencyRoughnessDepthKey, read: { $0.dysfluencyRoughnessDepth }),
            StepperProbe(name: "Rauheit: Rate", domain: D.dysfluencyRoughnessRateHz,
                         defaultValue: S.dysfluencyRoughnessRateHzDefault,
                         key: S.dysfluencyRoughnessRateHzKey, read: { $0.dysfluencyRoughnessRateHz }),
            StepperProbe(name: "Abstand zwischen Buchstaben", domain: D.presentationSpacingSeconds,
                         defaultValue: S.presentationSpacingSecondsDefault,
                         key: S.presentationSpacingKey, read: { $0.presentationSpacingSeconds }),
        ]
    }

    /// Every value a stepper can land on: the lower bound plus whole steps,
    /// up to and including the upper bound.
    private func gridPoints(of domain: ComparisonStepperDomain) -> [Double] {
        let count = Int(((domain.range.upperBound - domain.range.lowerBound) / domain.step).rounded())
        return (0...count).map { domain.range.lowerBound + Double($0) * domain.step }
    }

    // MARK: - Pickers

    @Test("every picker offers the store's default, so an untouched device shows a selection")
    func everyPickerOffersItsDefault() {
        for probe in pickers {
            #expect(probe.values.contains(probe.defaultValue),
                    "\(probe.name): the store defaults to \(probe.defaultValue) but the picker does not offer it — the control would render with nothing selected")
        }
    }

    @Test("every value a picker offers is what the store keeps, not a value it clamps away")
    func everyPickerValueSurvivesTheStore() {
        for probe in pickers {
            #expect(probe.resolved == probe.values,
                    "\(probe.name): offered \(probe.values) but the store resolves them to \(probe.resolved) — the control would show one setting and the session run another")
        }
    }

    @Test("no picker offers a value twice (the ForEach is keyed by value)")
    func pickerValuesAreUnique() {
        for probe in pickers {
            #expect(Set(probe.values).count == probe.values.count, "\(probe.name): duplicate option value in \(probe.values)")
            #expect(Set(probe.labels).count == probe.labels.count, "\(probe.name): duplicate option label in \(probe.labels)")
        }
    }

    @Test("a label marked (Vorgabe) sits on the store's default and on nothing else")
    func vorgabeLabelFollowsTheDefault() {
        let marker = ComparisonControlDomains.defaultMarker
        var markedPickers = 0
        for probe in pickers {
            let marked = zip(probe.labels, probe.values).filter { $0.0.contains(marker) }
            for (label, value) in marked {
                #expect(value == probe.defaultValue,
                        "\(probe.name): \"\(label)\" is marked (\(marker)) but the store's default is \(probe.defaultValue)")
            }
            if !marked.isEmpty { markedPickers += 1 }
        }
        // The two trigger pickers carry the marker today; a rename of the
        // marker word would otherwise turn the loop above into a no-op.
        #expect(markedPickers == 2, "expected exactly the two trigger pickers to mark their default, found \(markedPickers)")
    }

    // MARK: - Steppers

    @Test("every stepper's range contains the store's default, on a step it can reach")
    func everyStepperReachesItsDefault() {
        for probe in steppers {
            let lo = probe.domain.range.lowerBound
            #expect(probe.domain.range.contains(probe.defaultValue),
                    "\(probe.name): default \(probe.defaultValue) is outside \(probe.domain.range)")
            let steps = ((probe.defaultValue - lo) / probe.domain.step).rounded()
            #expect(abs(lo + steps * probe.domain.step - probe.defaultValue) < 1e-9,
                    "\(probe.name): default \(probe.defaultValue) is not on the \(probe.domain.step) grid from \(lo) — the stepper could never return to it")
        }
    }

    @Test("every value a stepper can land on is what the store keeps")
    func everyStepperValueSurvivesTheStore() {
        for probe in steppers {
            for value in gridPoints(of: probe.domain) {
                let box = ThrowawayDefaults()
                box.defaults.set(value, forKey: probe.key)
                let resolved = probe.read(S.configuration(in: box.defaults))
                #expect(abs(resolved - value) < 1e-9,
                        "\(probe.name): the stepper offers \(value) but the store resolves it to \(resolved)")
            }
        }
    }

    @Test("a stepper's last grid point is its upper bound")
    func stepperGridEndsAtTheBound() {
        for probe in steppers {
            let last = gridPoints(of: probe.domain).last!
            #expect(abs(last - probe.domain.range.upperBound) < 1e-9,
                    "\(probe.name): \(probe.domain.range) is not a whole number of \(probe.domain.step) steps, so its top is unreachable")
        }
    }

    // MARK: - Labels

    @Test("the roughness depth label reads whole percents, including the float-drift values a stepper produces")
    func roughnessDepthPercentIsRounded() {
        typealias D = ComparisonControlDomains
        #expect(D.roughnessDepthPercent(S.dysfluencyRoughnessDepthDefault) == 80)
        // The stepper adds 0.1 repeatedly, which drifts: 0.1 + … + 0.1 (eight
        // times) is 0.7999999999999999, and truncating its x100 reads 79.
        var accumulated = 0.0
        var shown: [Int] = [D.roughnessDepthPercent(accumulated)]
        for _ in 0..<10 {
            accumulated += D.dysfluencyRoughnessDepth.step
            shown.append(D.roughnessDepthPercent(min(accumulated, D.dysfluencyRoughnessDepth.range.upperBound)))
        }
        #expect(shown == [0, 10, 20, 30, 40, 50, 60, 70, 80, 90, 100])
    }
}
