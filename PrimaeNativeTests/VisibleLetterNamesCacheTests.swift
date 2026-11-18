// VisibleLetterNamesCacheTests.swift
// PrimaeNativeTests
//
// R-085: `visibleLetterNames` rebuilt a rank dictionary and re-sorted the
// whole pool on EVERY read, and SwiftUI bodies read it on every update
// (295 assets on device, measured). It is now cached and invalidated by
// each input's `didSet`.
//
// These tests pin the EXACT output rather than "non-empty", because a
// cache that returned the wrong ORDER would still be non-empty: the
// ordering is behaviour, not an implementation detail. The fixture set
// covers the three shapes the sort can take — a letter with no rank, a
// tie in rank, and a letter filtered out of the pool — plus a change to
// an input, which is the one thing a cache can silently lose.

import Testing
import Foundation
import CoreGraphics
@testable import PrimaeNative

@Suite(.serialized) @MainActor struct VisibleLetterNamesCacheTests {

    private func makeAsset(_ name: String,
                           base: String,
                           letterCase: LetterAsset.LetterCase) -> LetterAsset {
        LetterAsset(id: name, name: name, baseLetter: base, letterCase: letterCase,
                    audioFiles: [],
                    strokes: LetterStrokes(letter: name, checkpointRadius: 0.1, strokes: []),
                    phonemeAudioFiles: ["\(name)_phoneme1.mp3"])
    }

    private func makeVM(studyMode: Bool) -> TracingViewModel {
        var deps = TracingDependencies.stub
        deps.studyMode = studyMode
        deps.thesisCondition = .threePhase
        // "AFI" is one of the ten assignment buckets. Pinned rather than
        // inherited from ParticipantStore's persisted assignment, which is
        // not deterministic across a test run.
        guard let subset = TrainedLetterSubset(rawValue: "AFI") else {
            fatalError("AFI is not a valid trained subset")
        }
        deps.trainedSubset = subset
        return TracingViewModel(deps)
    }

    /// `.alphabetical` ranks A–Z only, so "Ä" has no rank (Int.max) and
    /// sorts last. "A" and "a" upper-case to the SAME rank key, which is
    /// the tie: `ra == rb ? a < b` puts "A" before "a".
    @Test("a letter with no rank sorts last, and a rank tie breaks alphabetically")
    func unrankedLetterLastAndRankTieBreaksAlphabetically() {
        let vm = makeVM(studyMode: false)
        vm.letterOrdering = .alphabetical
        vm.letters = [
            makeAsset("Q", base: "Q", letterCase: .upper),   // ranked 16
            makeAsset("a", base: "A", letterCase: .lower),   // tie with "A" on rank 0
            makeAsset("A", base: "A", letterCase: .upper),   // ranked 0
            makeAsset("Ä", base: "Ä", letterCase: .upper)    // no rank → Int.max
        ]
        #expect(vm.visibleLetterNames == ["A", "a", "Q", "Ä"])
    }

    /// Study mode filters the pool to the trained subset's UPPERCASE
    /// letters: "K" is outside "AFI" and "a" is lower case, so neither
    /// may appear. The surviving three keep motor-similarity order.
    @Test("a filtered-out letter never reaches the pool")
    func filteredOutLetterNeverReachesThePool() {
        let vm = makeVM(studyMode: true)
        vm.letters = [
            makeAsset("A", base: "A", letterCase: .upper),
            makeAsset("F", base: "F", letterCase: .upper),
            makeAsset("I", base: "I", letterCase: .upper),
            makeAsset("K", base: "K", letterCase: .upper),   // not in the trained subset
            makeAsset("a", base: "A", letterCase: .lower)    // uppercase-only under studyMode
        ]
        #expect(vm.visibleLetterNames == ["I", "F", "A"])
    }

    /// The cache must not survive a change to its inputs. Reading first
    /// populates it; each mutation below must reach the output.
    @Test("a change to an input reaches the output")
    func cacheInvalidatesWhenItsInputsChange() {
        let vm = makeVM(studyMode: false)
        vm.letterOrdering = .motorSimilarity
        vm.letters = [
            makeAsset("A", base: "A", letterCase: .upper),
            makeAsset("I", base: "I", letterCase: .upper),
            makeAsset("M", base: "M", letterCase: .upper)
        ]
        #expect(vm.visibleLetterNames == ["I", "A", "M"])

        vm.letters = [
            makeAsset("M", base: "M", letterCase: .upper),
            makeAsset("A", base: "A", letterCase: .upper)
        ]
        #expect(vm.visibleLetterNames == ["A", "M"])

        vm.letterOrdering = .wordBuilding
        #expect(vm.visibleLetterNames == ["M", "A"])
    }
}
