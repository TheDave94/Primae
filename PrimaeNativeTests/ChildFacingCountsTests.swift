// ChildFacingCountsTests.swift
// PrimaeNativeTests
//
// Coverage for the three child-facing count/verdict computations that had
// ZERO references from either test target before this file:
//
//   1. `LetterStars.stars(for:)` / `maxStars` — Core/LetterStars.swift
//   2. `PhaseDotIndicator.dot(for:)`           — Features/Tracing/PhaseDotIndicator.swift
//   3. the star TOTALS and the key space they read
//      — SchuleWorldView:361, WorldSwitcherRail:123, FortschritteWorldView:308
//
// WHY THESE. Each decides what a 5-year-old is shown: how many stars a letter
// earned, where the session is in the four-phase flow, and how many stars
// exist in total. `LetterStars` is the declared single source of truth for
// star counts ("one star earned" stays consistent); a wrong number here is a
// wrong stimulus, not a cosmetic bug.
//
// WHAT THIS FILE CANNOT REACH — measured, not assumed. `PhaseDotIndicator
// .completedCount`, `SchuleWorldView.totalStars` and `WorldSwitcherRail
// .starTotal` are all `private` on `View` types. `completedCount`'s only
// consumer is `.accessibilityValue`, and SwiftUI vends NO accessibility
// elements to a unit test in this configuration: a `UIHostingController` in a
// key `UIWindow`, laid out, reports `accessibilityElementCount() == 0`,
// `accessibilityElements == []` and zero subviews. So `completedCount` is not
// asserted here at all (see the report accompanying this file), and the
// totals are pinned through the input they share, which is the only part of
// them that is reachable.

import Testing
import Foundation
import SwiftUI
import UIKit
import CoreGraphics
@testable import PrimaeNative

// MARK: - 1. The star calculator

@MainActor
@Suite struct LetterStarsTests {

    /// A score map for every phase at the same value, keyed the way the
    /// persisted JSON keys it.
    private func allPhasesScored(_ value: Double) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: LearningPhase.allCases.map { ($0.rawName, value) })
    }

    @Test("a letter with no score row earns no stars")
    func absentAndEmptyScoreMapsEarnNothing() {
        #expect(LetterStars.stars(for: nil) == 0,
                "no score row at all is not a perfect letter")
        #expect(LetterStars.stars(for: [:]) == 0,
                "an empty score row is not a perfect letter either")
    }

    /// The comparison is `>=`, so this test reads the threshold out of
    /// production rather than restating it — it pins the OPERATOR, which is
    /// the thing that decides the boundary.
    @Test("a phase scored just under its threshold earns nothing")
    func belowThresholdEarnsNothing() {
        let threshold = Double(LearningPhaseController.starThreshold(for: .guided))
        let view = [LearningPhase.guided.rawName: threshold - 0.01]
        #expect(LetterStars.stars(for: view) == 0,
                "guided just under its own threshold must not earn the star")
    }

    @Test("a phase scored exactly at its threshold earns its star")
    func atThresholdEarnsTheStar() {
        let threshold = Double(LearningPhaseController.starThreshold(for: .guided))
        let view = [LearningPhase.guided.rawName: threshold]
        #expect(LetterStars.stars(for: view) == 1,
                "the comparison is `>=` — a score AT the threshold earns the star")
    }

    /// `maxStars` derives from `LearningPhase.allCases.count` so a
    /// phase-model change propagates. This is the assertion that makes that
    /// derivation load-bearing: a literal that drifted away from the number
    /// of phases that can actually earn a star fails here.
    @Test("a letter passed on every phase earns exactly maxStars")
    func perfectLetterEarnsMaxStars() {
        #expect(LetterStars.stars(for: allPhasesScored(1.0)) == LetterStars.maxStars,
                "maxStars must equal the number of phases that can earn a star")
    }

    @Test("no score row can earn more than maxStars")
    func maxStarsIsACeiling() {
        for mask in 0..<(1 << LearningPhase.allCases.count) {
            var row: [String: Double] = [:]
            for (index, phase) in LearningPhase.allCases.enumerated()
            where mask & (1 << index) != 0 {
                row[phase.rawName] = 1.0
            }
            let earned = LetterStars.stars(for: row)
            #expect(earned <= LetterStars.maxStars,
                    "subset \(mask) earned \(earned), above maxStars \(LetterStars.maxStars)")
        }
    }

    /// `phaseScores` is decoded from persisted JSON, so the key string is a
    /// STORAGE FORMAT. Reading `displayName` (which is German UI copy, free
    /// to change) instead would silently void every star a child had earned.
    @Test("the score row is keyed by rawName, not by displayName")
    func scoreRowIsKeyedByRawName() {
        let byDisplayName = Dictionary(uniqueKeysWithValues:
            LearningPhase.allCases.map { ($0.displayName, 1.0) })
        #expect(LetterStars.stars(for: byDisplayName) == 0,
                "displayName is UI copy — a change to it must not be able to read as progress")
        #expect(LetterStars.stars(for: allPhasesScored(1.0)) == LetterStars.maxStars,
                "rawName is the persisted key — a full row must be recognised in full")
    }

    /// observe and direct are pass/fail on a 0 threshold; guided and
    /// freeWrite are not. The documented consequence is that a child who
    /// skipped the tracing phases cannot collect their stars.
    @Test("zero on every phase earns the two free phases and no more")
    func freePassPhasesCapAtTwo() {
        #expect(LetterStars.stars(for: allPhasesScored(0.0)) == 2,
                "observe and direct are free, guided and freeWrite are not — a zero row is 2 stars, not 4")
    }
}

// MARK: - 2. The phase-progress dots

@MainActor
@Suite(.serialized) struct PhaseDotIndicatorTests {

    // MARK: The instrument

    /// Counts the pixels `PhaseDotIndicator` paints in `primaryBlue`
    /// (0.22, 0.54, 0.87 → 56, 138, 222).
    ///
    /// WHY A RASTER. `dot(for:)` is `private`, its decisions are booleans
    /// inside a `@ViewBuilder`, and SwiftUI vends no accessibility elements
    /// to this process (measured: `accessibilityElementCount() == 0`). The
    /// drawn dot is the only surface that exists.
    ///
    /// Unlike the `ImageRenderer` ring tests that were deleted from
    /// `StudyComparisonSwitchesTests`, this view has no `GeometryReader` — it
    /// is a fixed `HStack` of fixed-size circles — so a real layout pass
    /// produces the real thing rather than a constant background.
    private func bluePixels(_ view: PhaseDotIndicator) -> Int {
        let size = CGSize(width: 320, height: 60)
        let hc = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = hc
        window.makeKeyAndVisible()
        hc.view.frame = window.bounds
        hc.view.setNeedsLayout()
        hc.view.layoutIfNeeded()
        window.layoutIfNeeded()
        defer { window.isHidden = true }

        let image = UIGraphicsImageRenderer(size: size).image { _ in
            hc.view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
        }
        guard let cg = image.cgImage else { return 0 }
        let width = cg.width, height = cg.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &buffer, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return 0 }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

        var count = 0
        for i in stride(from: 0, to: buffer.count, by: 4) where buffer[i + 3] > 200 {
            if abs(Int(buffer[i]) - 56) < 40,
               abs(Int(buffer[i + 1]) - 138) < 40,
               abs(Int(buffer[i + 2]) - 222) < 40 { count += 1 }
        }
        return count
    }

    /// Columns carrying any drawn content at all — filled dot OR hollow
    /// outline. Used only for the row's WIDTH, i.e. how many dots were
    /// rendered, which the fill count cannot see.
    private func contentColumns(_ view: PhaseDotIndicator) -> Int {
        let size = CGSize(width: 320, height: 60)
        let hc = UIHostingController(rootView: view)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = hc
        window.makeKeyAndVisible()
        hc.view.frame = window.bounds
        hc.view.setNeedsLayout()
        hc.view.layoutIfNeeded()
        window.layoutIfNeeded()
        defer { window.isHidden = true }

        let image = UIGraphicsImageRenderer(size: size).image { _ in
            hc.view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
        }
        guard let cg = image.cgImage else { return 0 }
        let width = cg.width, height = cg.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &buffer, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return 0 }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

        // A window raster is opaque, so "has content" cannot mean "is not
        // transparent". Sample a corner as the background and count columns
        // holding anything that differs from it — that catches both the blue
        // fill and the hollow outline's grey.
        let bg = (r: Int(buffer[0]), g: Int(buffer[1]), b: Int(buffer[2]))
        var columns = 0
        for x in 0..<width {
            for y in 0..<height {
                let i = (y * width + x) * 4
                if abs(Int(buffer[i]) - bg.r) > 12
                    || abs(Int(buffer[i + 1]) - bg.g) > 12
                    || abs(Int(buffer[i + 2]) - bg.b) > 12 {
                    columns += 1
                    break
                }
            }
        }
        return columns
    }

    /// Filled dots, calibrated against a configuration whose answer is known
    /// independent of the logic under test: one active phase, no scores, and
    /// the current phase equal to it. `dot(for:)` fills on
    /// `isCompleted || isCurrent`, so exactly one dot is filled there.
    ///
    /// The unit is NOT hardcoded. If `dot(for:)` stops painting fills at all
    /// the unit is 0 and this returns -1, so every caller fails loudly
    /// instead of quietly comparing 0 to 0 — the failure mode that made the
    /// deleted `ImageRenderer` ring tests worthless.
    private func filledDots(_ view: PhaseDotIndicator) -> Int {
        let unit = bluePixels(PhaseDotIndicator(phase: .guided, scores: [:],
                                                activePhases: [.guided]))
        guard unit > 0 else { return -1 }
        return bluePixels(view) / unit
    }

    @Test("the calibration configuration really does fill exactly one dot")
    func instrumentCalibrates() {
        // Without this, a `filledDots` that always returned -1 would still
        // let a `== -1` assertion pass. The instrument is asserted, not assumed.
        #expect(filledDots(PhaseDotIndicator(phase: .guided, scores: [:],
                                              activePhases: [.guided])) == 1)
    }

    // MARK: The decisions

    @Test("every phase already visited fills a dot, whatever the current phase is")
    func visitedPhasesFillDots() {
        let view = PhaseDotIndicator(phase: .guided,
                                     scores: [.observe: 0.9, .direct: 1.0],
                                     activePhases: LearningPhase.allCases)
        #expect(filledDots(view) == 3,
                "observe and direct visited plus guided current is three filled dots, not one")
    }

    /// The dot tracks which phases the session has been THROUGH, not how
    /// well they scored — a phase that was run and scored zero has still
    /// been run. This is the deliberate difference from `LetterStars`, where
    /// the score decides.
    @Test("a phase recorded with a score of zero still fills its dot")
    func zeroScoredPhaseStillFillsItsDot() {
        let view = PhaseDotIndicator(phase: .observe,
                                     scores: [.guided: 0.0],
                                     activePhases: LearningPhase.allCases)
        #expect(filledDots(view) == 2,
                "observe is current and guided was recorded at 0.0 — both dots fill; the dots show progress, not pass/fail")
    }

    @Test("the current phase fills a dot even with no score recorded")
    func currentPhaseFillsWithoutAScore() {
        let view = PhaseDotIndicator(phase: .direct,
                                     scores: [.observe: 0.9],
                                     activePhases: LearningPhase.allCases)
        #expect(filledDots(view) == 2,
                "observe visited and direct current — the 'you are here' dot must fill on position alone")
    }

    /// `.guidedOnly`/`.control` run `.guided` alone. Rendering four dots
    /// there would show three permanently-empty placeholders — a
    /// progress meter that can never complete.
    @Test("narrowing activePhases narrows the row")
    func activePhasesNarrowTheRow() {
        let guidedOnly = PhaseDotIndicator(phase: .guided, scores: [:], activePhases: [.guided])
        let fourPhase = PhaseDotIndicator(phase: .guided, scores: [:],
                                          activePhases: LearningPhase.allCases)
        // Measured on the pilot device: 20 content columns for the one-phase
        // row against 80 for the four-phase row, i.e. 4× for 4× the dots.
        // The factor below is deliberately looser than that.
        let narrow = contentColumns(guidedOnly)
        let wide = contentColumns(fourPhase)
        #expect(narrow > 0, "the guidedOnly row drew nothing at all")
        #expect(wide >= narrow * 2,
                "the four-phase row is not wider than the one-phase row (\(narrow) vs \(wide)) — activePhases is not reaching the ForEach")
    }
}

// MARK: - 3. The star totals and the input they all share

/// The star TOTAL is computed three times over, each with a comment claiming
/// agreement: `SchuleWorldView.totalStars:361` ("same computation as the world
/// rail's badge so the two displays always agree"), `WorldSwitcherRail
/// .starTotal:123` ("keeps the badge in agreement with the celebration
/// overlay and gallery") and `FortschritteWorldView.totalStars:308`. All
/// three are `private`, all three are the same expression, and all three read
/// the same stored property — `vm.allProgress`.
///
/// That means they cannot disagree at run time; what they CAN do is drift
/// apart on a later edit to one copy, which nothing here can catch without a
/// production seam. What IS reachable, and what these tests pin, is the input
/// they share: if the mirror is stale or its keys are not canonical, the
/// aggregate sites (`allProgress.values`) and the per-letter sites
/// (`allProgress[canonicalKey(letter)]`) start describing different letters,
/// and the badge total stops matching the gallery.
@MainActor
@Suite struct StarTotalInputTests {

    private func makeStore() -> (JSONProgressStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("star-total-\(UUID().uuidString).json")
        return (JSONProgressStore(fileURL: url), url)
    }

    private func makeVM(store: ProgressStoring) -> TracingViewModel {
        TracingViewModel(TracingDependencies.stub.with(progressStore: store))
    }

    private func row(_ phases: [LearningPhase], score: Double) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: phases.map { ($0.rawName, score) })
    }

    @Test("the mirror every star total reads is refreshed from the store")
    func mirrorTracksTheStore() {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let vm = makeVM(store: store)

        store.recordCompletion(for: "A", accuracy: 1.0,
                               phaseScores: row([.guided], score: 0.9),
                               speed: nil, recognitionResult: nil, formAccuracy: nil)
        vm.refreshProgressMirror()

        #expect(vm.allProgress.count == 1,
                "one letter recorded, one entry in the aggregate the totals reduce over")
        #expect(vm.allProgress[LetterProgress.canonicalKey("A")]?
                    .phaseScores?[LearningPhase.guided.rawName] == 0.9,
                "the mirror is stale — every total and every per-letter chip would render the pre-write number")
    }

    /// `allProgress` is the aggregate the totals reduce over; the per-letter
    /// chips look the same letter up by `canonicalKey`. Those two access
    /// patterns describe the same letters only while the key space is
    /// canonical — and `canonicalKey` exists precisely because the obvious
    /// `uppercased()` collapses two distinct inputs onto one key.
    @Test("two distinct letters never collapse onto one progress row")
    func distinctLettersDoNotCollide() {
        let (store, url) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let vm = makeVM(store: store)

        #expect(LetterProgress.canonicalKey("ß") != LetterProgress.canonicalKey("SS"),
                "canonicalKey collapsed ß onto SS — those are two different inputs and would share one progress row")

        store.recordCompletion(for: "ß", accuracy: 1.0,
                               phaseScores: row(LearningPhase.allCases, score: 1.0),
                               speed: nil, recognitionResult: nil, formAccuracy: nil)
        store.recordCompletion(for: "SS", accuracy: 1.0,
                               phaseScores: row([.observe], score: 1.0),
                               speed: nil, recognitionResult: nil, formAccuracy: nil)
        vm.refreshProgressMirror()

        #expect(vm.allProgress.count == 2,
                "two letters were recorded but the aggregate holds \(vm.allProgress.count) — one row overwrote the other, so the badge total and the gallery chips are counting different things")
        #expect(vm.allProgress[LetterProgress.canonicalKey("ß")]?.phaseScores?.count == 4,
                "the ß row is not reachable by the key the per-letter chips look up")
        #expect(vm.allProgress[LetterProgress.canonicalKey("SS")]?.phaseScores?.count == 1,
                "the SS row is not reachable by the key the per-letter chips look up")
    }
}
