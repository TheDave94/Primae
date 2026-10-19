// AssetFormatComplianceTests.swift
//
// WHY THIS FILE EXISTS. `ResourceResolutionTests` proves each phoneme
// recording RESOLVES (`studyLetterPhonemesResolve`, H5) and nothing
// about what is IN it. That leaves the other half of the contract
// unguarded: the phoneme recordings have a chosen format, and a
// regression in it — mono re-exported as stereo, 44.1 kHz resampled to
// 48 kHz — would pass every existing test in the target, because every
// existing test stops at "the file is there".
//
// WHERE THE FORMAT COMES FROM (docs/SOUND_PRODUCTION_SPEC.md). Not from the
// §2 table: its 44.1 kHz / mono rows describe the legacy MP3 letter-name
// files, and the spec's own 2026-10-14 correction scopes it to them. §2.1
// says source files must be mono, on a pan argument the same note's
// offline probe did not reproduce. The format pinned here — mono, 44.1 kHz
// — is a deliberate choice, recorded in that note's 2026-10-18 update
// (protocol revision 10): the five phoneme files were re-encoded to the
// spatial carrier's format so the two sound arms' files differ in content,
// not in channel count or rate. Changing it is a protocol revision.
//
// WHY RAW RIFF BYTES AND NOT AVAudioFile. `AVAudioFile.fileFormat`
// reports the format through AudioToolbox's own container handling —
// the same framework the app already loads these files with. The claim
// under test is the SHIPPED BYTES, so this parses the literal `fmt `
// chunk of the RIFF/WAVE file: no per-file class, no audio session, no
// normalisation in the path. A wrong header is a wrong header on disk.
//
// SCOPE. One assertion per phoneme recording the production resolution
// path actually serves — enumerated through `LetterRepository` (the
// real provider, not a hand-copied list) exactly as the app enumerates
// them, then resolved through `PrimaeBundle`. `spatial_carrier.wav` is
// deliberately NOT asserted here: the r10 choice is about the phoneme
// files (they were matched TO the carrier), and the spec records the
// carrier's own format only as a *measurement* in the 2026-10-14
// correction note. Pinning it would be inventing a choice nobody recorded.

import Testing
import Foundation
@testable import PrimaeNative

@Suite struct AssetFormatComplianceTests {

    // MARK: - Reading the shipped bytes

    /// The three `fmt ` fields this suite reads, from one file.
    struct WAVFormat: Equatable, CustomStringConvertible {
        let channels: Int
        let sampleRate: Int
        let bitsPerSample: Int

        var description: String {
            "\(channels) ch, \(sampleRate) Hz, \(bitsPerSample)-bit"
        }
    }

    enum WAVError: Error, CustomStringConvertible {
        case tooShort(Int)
        case notRIFFWAVE
        case noFmtChunk

        var description: String {
            switch self {
            case .tooShort(let n): return "file is only \(n) bytes — not a WAV"
            case .notRIFFWAVE:     return "missing RIFF/WAVE magic"
            case .noFmtChunk:      return "no `fmt ` chunk"
            }
        }
    }

    /// Parse the `fmt ` chunk out of the literal bytes at `url`.
    static func wavFormat(at url: URL) throws -> WAVFormat {
        let data = try Data(contentsOf: url)

        func u16(_ o: Int) throws -> Int {
            guard o + 2 <= data.count else { throw WAVError.tooShort(data.count) }
            return Int(data[o]) | (Int(data[o + 1]) << 8)
        }
        func u32(_ o: Int) throws -> Int {
            guard o + 4 <= data.count else { throw WAVError.tooShort(data.count) }
            return Int(data[o]) | (Int(data[o + 1]) << 8)
                 | (Int(data[o + 2]) << 16) | (Int(data[o + 3]) << 24)
        }
        func tag(_ o: Int) throws -> String {
            guard o + 4 <= data.count else { throw WAVError.tooShort(data.count) }
            return String(bytes: data[o..<o + 4], encoding: .ascii) ?? "????"
        }

        guard data.count >= 12 else { throw WAVError.tooShort(data.count) }
        guard try tag(0) == "RIFF", try tag(8) == "WAVE" else { throw WAVError.notRIFFWAVE }

        // Walk the chunk list rather than assuming `fmt ` sits at offset
        // 12 — a `JUNK`/`LIST`/`fact` chunk before it is legal and common
        // from some encoders.
        var offset = 12
        while offset + 8 <= data.count {
            let id = try tag(offset)
            let size = try u32(offset + 4)
            let body = offset + 8
            if id == "fmt " {
                guard size >= 16, body + 16 <= data.count else { throw WAVError.tooShort(data.count) }
                return WAVFormat(channels: try u16(body + 2),
                                 sampleRate: try u32(body + 4),
                                 bitsPerSample: try u16(body + 14))
            }
            offset = body + size + (size % 2)   // chunks are word-aligned
        }
        throw WAVError.noFmtChunk
    }

    // MARK: - The production population

    struct PhonemeRecording {
        let letter: String
        let relativePath: String
        let url: URL?
    }

    /// Every phoneme RECORDING (i.e. every distinct file) the production
    /// resolution path serves.
    ///
    /// Enumerated through the REAL repository (`BundleLetterResourceProvider`
    /// + `NullLetterCache`) so this list is what the app's
    /// `TracingViewModel.activeAudioFiles` returns for the phoneme arm —
    /// not a copy of it that can drift. Each path is then resolved the
    /// way the tests already resolve resources: `PrimaeBundle`'s contract
    /// first, the repository's own resolver as the layout-tolerant
    /// fallback.
    ///
    /// TWO normalisations, both measured, both necessary to make the
    /// population the FILES rather than the (letter, file) pairs:
    ///
    ///  1. the repository hands a served path back once per bundle copy
    ///     the test host carries (app, nested framework, xctest), so a
    ///     path can carry a copy-specific prefix — reduced to the
    ///     bundle-root-relative `Resources/…` form `PrimaeBundle` resolves;
    ///  2. many letters resolve the SAME recording (the repository
    ///     attributes the five study files across related letters — e.g.
    ///     `T` and `a` both serve `Resources/Letters/A/A_phoneme1.wav`).
    ///     Asserted per file, so a recording is read and reported once.
    static func phonemeRecordings() throws -> [PhonemeRecording] {
        let provider = BundleLetterResourceProvider()
        let repo = LetterRepository(resources: provider, cache: NullLetterCache())
        let letters = try repo.loadBundledLettersOnly().get()

        var seen = Set<String>()
        var out: [PhonemeRecording] = []
        for asset in letters {
            for raw in asset.phonemeAudioFiles {
                let relative = Self.bundleRelative(raw)
                guard seen.insert(relative).inserted else { continue }
                let url = PrimaeBundle.resourceURL(relative) ?? provider.resourceURL(for: relative)
                out.append(PhonemeRecording(letter: Self.owningFolder(of: relative),
                                            relativePath: relative,
                                            url: url))
            }
        }
        return out.sorted { $0.relativePath < $1.relativePath }
    }

    /// Reduce a possibly copy-prefixed served path to the
    /// `Resources/…` form `PrimaeBundle` resolves: e.g.
    /// `Frameworks/…_PackageProduct.framework/…bundle/Resources/Letters/A/A_phoneme1.wav`
    /// → `Resources/Letters/A/A_phoneme1.wav`. A path that already starts
    /// at `Resources/` is returned unchanged.
    static func bundleRelative(_ path: String) -> String {
        if path.hasPrefix("Resources/") { return path }
        if let range = path.range(of: "Resources/", options: .backwards) {
            return String(path[range.lowerBound...])
        }
        return path
    }

    /// The letter folder a served path lives in (`Resources/Letters/A/…`
    /// → `A`), for the coverage guard and the failure message.
    static func owningFolder(of relativePath: String) -> String {
        let parts = relativePath.split(separator: "/")
        if let i = parts.firstIndex(of: "Letters"), i + 1 < parts.count {
            return String(parts[i + 1])
        }
        return relativePath
    }

    // MARK: - The contract

    /// One assertion over every phoneme recording: mono and 44.1 kHz, the
    /// r10 format (see the header). Failures are accumulated so EVERY offender
    /// is named in one message, not just the first.
    @Test("every phoneme recording is mono at 44.1 kHz (the r10 format pin)")
    func phonemeRecordingsMatchSpecFormat() throws {
        let recordings = try Self.phonemeRecordings()

        // Guard against a vacuous pass: an empty enumeration is not
        // compliance, and the format loop below would silently assert
        // nothing.
        let covered = Set(recordings.map(\.letter))
        #expect(covered.isSuperset(of: TrainedLetterSubset.studyLetters),
                """
                the phoneme sweep covers \(covered.sorted()) but is missing study letters \
                \(Set(TrainedLetterSubset.studyLetters).subtracting(covered).sorted()) — \
                this test would be vacuous for them.
                """)

        var failures: [String] = []
        for recording in recordings {
            guard let url = recording.url else {
                failures.append("\(recording.letter) → \(recording.relativePath): not served by the bundle")
                continue
            }
            do {
                let format = try Self.wavFormat(at: url)
                if format.channels != 1 {
                    failures.append("\(recording.letter) → \(recording.relativePath): \(format.channels) channels, the r10 format is mono (1)")
                }
                if format.sampleRate != 44100 {
                    failures.append("\(recording.letter) → \(recording.relativePath): \(format.sampleRate) Hz, the r10 format is 44100 Hz")
                }
            } catch {
                failures.append("\(recording.letter) → \(recording.relativePath): unreadable — \(error)")
            }
        }

        let measured = recordings.compactMap { r -> String? in
            guard let url = r.url, let f = try? Self.wavFormat(at: url) else { return nil }
            return "\(r.relativePath)=\(f)"
        }
        #expect(failures.isEmpty,
                """
                \(failures.count) phoneme recording(s) are not in the r10 format:
                \(failures.joined(separator: "\n"))
                --- measured ---
                \(measured.joined(separator: "\n"))
                """)
    }
}
