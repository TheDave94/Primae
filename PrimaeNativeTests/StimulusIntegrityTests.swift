// StimulusIntegrityTests.swift
//
// R-115 (audit): "`.copy("Resources")` ships ignored files (.DS_Store); WAV
// bytes/format unpinned". Package.swift ships the whole `Resources` tree with
// `.copy`, which copies a directory as it finds it. Ignoring `.DS_Store` in git
// protects the repository, not the build on a Mac where Finder has been open
// on the folder: the file is in the working tree, so it rides into the bundle
// that goes onto a child's iPad. The two checks here guard the stimulus
// files the study arms play, and neither changes what ships.
//
//  1. NO HIDDEN FILE IN THE SHIPPED RESOURCE BUNDLE. This enumerates the
//     bundle the app resolves its resources from (`PrimaeBundle.resources`)
//     with NO `.skipsHiddenFiles` — the other tests that walk the tree pass
//     that option and so cannot see a dotfile by construction.
//  2. THE CARRIER'S BYTES. The five phoneme recordings' sha256 is pinned in
//     `PhonemeOnsetTests.fileSHA16` (the attack-end hints are only valid for
//     those exact files); the spatial carrier, the other arm's only sound,
//     had no byte pin at all. Its format is pinned in
//     `AssetFormatComplianceTests.spatialCarrierMatchesSpecFormat`.
//
// Pattern followed for (2): the phoneme files' own test-local sha256 table in
// `PhonemeOnsetTests`, not `Prompts/MANIFEST.json` + `check_study_prompts.py`.
// That manifest is the spoken-prompt set's (and the set id the app stamps on
// every row); adding the carrier to it would change a shipped file.

import Testing
import Foundation
import CryptoKit
@testable import PrimaeNative

@Suite struct StimulusIntegrityTests {

    /// sha256 of `Resources/Sonification/spatial_carrier.wav` measured at
    /// origin/main c9166da7 (176444 bytes, mono, 44.1 kHz, 16-bit, 2.000 s). A new
    /// carrier is a protocol change (the spatial arm's sound), not a re-pin.
    static let carrierSHA256 = "478ccb29bb80e930d6fec8d5cd8b047e45a64b8578bcd53f020dbd875a65efb5"

    @Test("the spatial carrier's bytes are the reviewed ones (sha256)")
    func carrierBytesArePinned() throws {
        let url = try #require(PrimaeBundle.audioURL(for: SpatialSonification.carrierToneFile),
                               "\(SpatialSonification.carrierToneFile) is not served by the bundle")
        let data = try Data(contentsOf: url)
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(sha == Self.carrierSHA256,
                "spatial_carrier.wav changed (\(data.count) bytes, sha256 \(sha)): the spatial arm now plays different bytes — a protocol change, not a silent edit")
    }

    @Test("the shipped resource bundle contains no hidden file (.DS_Store, ._*, any dotfile)")
    func shippedResourceTreeHasNoDotfiles() throws {
        let root = PrimaeBundle.resources.bundleURL.resolvingSymlinksInPath()
        // `options: []` on purpose: no `.skipsHiddenFiles`, or this sees nothing.
        let walk = try #require(FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil, options: []),
            "cannot enumerate \(root.path)")

        var hidden: [String] = []
        var names = Set<String>()
        for case let url as URL in walk {
            let name = url.lastPathComponent
            names.insert(name)
            if name.hasPrefix(".") {
                let full = url.resolvingSymlinksInPath().path
                hidden.append(full.hasPrefix(root.path + "/") ? String(full.dropFirst(root.path.count + 1)) : full)
            }
        }

        // Vacuity guard: a walk over the wrong directory finds no dotfile
        // either. The study's stimulus files must be in what was walked.
        let stimuli = TrainedLetterSubset.studyLetters.map { "\($0)_phoneme1.wav" } + ["spatial_carrier.wav"]
        let missing = stimuli.filter { !names.contains($0) }
        #expect(missing.isEmpty,
                "walked \(root.path) (\(names.count) distinct names) and did not find \(missing) — the gate looked at the wrong tree")

        #expect(hidden.isEmpty,
                "the shipped resource bundle contains \(hidden.count) hidden file(s): \(hidden.sorted().joined(separator: ", ")) — `.copy(\"Resources\")` shipped them; remove them from PrimaeNative/Resources")
    }
}
