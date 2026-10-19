// Resource-resolution regression net.
//
// WHY THIS FILE EXISTS. The CoreML model resolved through a path nobody
// had verified and was dark for three months — `recognition_predicted`
// empty in 194 of 194 recognition-bearing records across 41 sessions —
// because a missing model is DESIGNED to degrade quietly. `cb7291d`
// fixed that one resource and pinned it with `BundleResolutionTests`.
//
// Every other bundled resource had the same shape and none of the same
// coverage. Each of these fails silently by design:
//
//   spatial_carrier.wav  the spatial arm plays nothing, which is
//                        behaviourally IDENTICAL to the silent control
//                        arm — a corrupted independent variable that
//                        looks like a valid one
//   fonts                `urls.isEmpty` logs a warning and returns; the
//                        app renders in the system face
//   effect sounds        `systemFallback` chimes, or for tick_stroke
//                        (fallback nil) plays nothing at all
//   letter audio         "no audio files found" is an issue entry, not
//                        a failure
//
// The pre-existing arm-routing tests could not see any of this:
//
//   #expect(vm.activeAudioFiles(for: asset()) == [SpatialSonification.carrierToneFile])
//
// asserts a String constant against itself and never touches the disk.
// Delete the carrier and every one of those tests still passes.
//
// WHAT "RESOLVES" MEANS HERE. Each assertion goes through `PrimaeBundle`,
// the resolver the app itself uses, and — except where noted — through
// the PACKAGE bundle specifically rather than `PrimaeBundle`'s `.main`
// last resort. The package bundle is the one that exists in both layouts:
// nested in `PrimaeNative.framework` in the app, and nested in the same
// framework inside `PrimaeNativeTests.xctest` under test. Proving a
// resource resolves there is what makes app and test agree; a test that
// accepted the `.main` fallback would pass on a host that embeds a copy
// while the package bundle shipped without it.
//
// The audio assertions are the exception to "goes through `PrimaeBundle`
// directly" only in name: they call `PrimaeBundle.audioURL(for:)`, the one
// function `AudioEngine.loadAudioFile` and
// `SpatialSonification.carrierToneURL()` both use. Probing that entry point
// rather than `resourceURL` under it is the point — the audio path resolved
// through a hand-rolled `[Bundle.main, Bundle.module]` loop (which traps)
// in each of those two files until 2026-10-16, and a test of
// `PrimaeBundle.resourceURL` alone would have stayed green through it.

import Testing
import Foundation
import CryptoKit
@testable import PrimaeNative

@Suite struct ResourceResolutionTests {

    /// Resolution restricted to the PACKAGE bundle — `PrimaeBundle`'s
    /// `.main` probe deliberately excluded. See the file header.
    private static func resolvesInPackageBundle(_ relativePath: String) -> Bool {
        let bundle = PrimaeBundle.resources
        for root in [bundle.bundleURL, bundle.resourceURL].compactMap({ $0 }) {
            if FileManager.default.fileExists(
                atPath: root.appendingPathComponent(relativePath).path) { return true }
        }
        return false
    }

    private static func resolvesInPackageBundle(firstOf paths: [String]) -> Bool {
        paths.contains { resolvesInPackageBundle($0) }
    }

    // MARK: - The pilot's independent variable

    /// THE one that matters most. The spatial arm's only sound is this
    /// single letter-independent carrier. If it stops shipping, that arm
    /// becomes the silent arm and the between-arm contrast the study is
    /// built on silently collapses to two conditions wearing three labels.
    @Test("the spatial arm's carrier tone is bundled")
    func spatialCarrierResolves() {
        #expect(Self.resolvesInPackageBundle(SpatialSonification.carrierToneFile),
                """
                \(SpatialSonification.carrierToneFile) is not in the package bundle. \
                The spatial pilot arm has no sound and is indistinguishable from \
                the silent control arm.
                """)
    }

    // MARK: - Audio filenames (engine + carrier)

    /// The engine's own lookup, over the file the spatial arm plays.
    /// `SpatialSonification.carrierToneURL()` and `AudioEngine.loadAudioFile`
    /// share ONE lookup as of 2026-10-16; before that each carried its own
    /// `[Bundle.main, Bundle.module]` loop, so the arm's precondition could
    /// disagree with what the engine would actually play.
    @Test("the engine's audio lookup finds the carrier it is asked to play")
    func engineResolverFindsCarrier() throws {
        let url = try #require(
            PrimaeBundle.audioURL(for: SpatialSonification.carrierToneFile),
            "the audio lookup cannot resolve \(SpatialSonification.carrierToneFile)")
        #expect(FileManager.default.fileExists(atPath: url.path),
                "the resolver handed back \(url.path), which is not on disk")
        #expect(SpatialSonification.carrierToneURL() == url,
                "the arm's precondition and the engine disagree about the carrier's URL")
    }

    /// A name that is not bundled must come back `nil`, never as a URL
    /// that is not there, so a caller can fall back. This pins that
    /// contract on the audio lookup; it does NOT pin the trap fix — the
    /// replaced `Bundle.module` loop also answered nil here, because in
    /// the test host the resource bundle resolves. The bundle-MISSING case
    /// is `audioLookupWithoutThePackageBundleIsNil`.
    @Test("an audio name that is not bundled resolves to nil, never a path that is not there")
    func absentAudioNameResolvesToNil() {
        // Positive control FIRST: the same call resolves the real carrier,
        // so a green `nil` below cannot come from a lookup that answers nil
        // to everything.
        #expect(PrimaeBundle.audioURL(for: SpatialSonification.carrierToneFile) != nil,
                "precondition: the carrier resolves through the lookup under test")

        let absent = "Resources/Sonification/absent_carrier.wav"
        #expect(PrimaeBundle.audioURL(for: absent) == nil,
                "\(absent) is not bundled and must resolve to nil")
        // Every candidate the lookup walks is absent too, so the nil above
        // is the whole list failing, not one probe short-circuiting.
        let layouts = PrimaeBundle.audioLayouts(for: absent)
        #expect(layouts == [absent, "absent_carrier.wav"],
                "expected the path as given, then its flat name; got \(layouts)")
        for layout in layouts {
            #expect(PrimaeBundle.resourceURL(layout) == nil,
                    "\(layout) resolved for a name that is not bundled")
        }
    }

    /// THE trap case, as far as a test can reach it. `Bundle.module`
    /// `fatalError`s when the package's resource bundle cannot be found,
    /// and a trap cannot be observed from inside the test process (Swift
    /// Testing's exit tests do not exist on iOS). What CAN be observed is
    /// the precondition for never reaching it: the audio lookup consults
    /// only the roots `PrimaeBundle` hands it. Take them away — no package
    /// bundle, no `.main` — and the answer must be nil. The replaced
    /// `[Bundle.main, Bundle.module]` loop ignores the roots and finds the
    /// carrier through `Bundle.module` regardless, so it fails this test,
    /// which is the point (mutation-checked: the lane receipt).
    @Test("with the package bundle missing, the audio lookup answers nil and reaches for no other bundle")
    func audioLookupWithoutThePackageBundleIsNil() {
        let carrier = SpatialSonification.carrierToneFile
        // Positive control: the same name resolves with the real roots.
        #expect(PrimaeBundle.audioURL(for: carrier) != nil,
                "precondition: \(carrier) resolves through the default roots")
        #expect(PrimaeBundle.audioURL(for: carrier, roots: []) == nil,
                "the audio lookup found \(carrier) with NO roots — it is reaching past PrimaeBundle")
    }

    /// The bundle `Bundle.module` resolves to. The test target cannot name
    /// the app module's `Bundle.module`, so this follows its generated
    /// accessor: the copy nested in the MAIN bundle first. Measured on the
    /// iPad test host (2026-10-18): that is `Primae.app/PrimaeNative_PrimaeNative.bundle`,
    /// while `PrimaeBundle.resources` resolves to a second, identical copy
    /// under `Frameworks/…_PackageProduct.framework/` that only the test
    /// host carries — so substituting `PrimaeBundle.resources` for
    /// `Bundle.module` would compare the new lookup against itself.
    private static let moduleBundle: Bundle =
        Bundle(url: Bundle.main.bundleURL.appendingPathComponent("PrimaeNative_PrimaeNative.bundle"))
        ?? PrimaeBundle.resources

    /// The replaced loop, verbatim but for `Bundle.module` →
    /// `moduleBundle` (above). A reference to compare against, not code
    /// the app runs.
    private static func replacedLoopURL(for fileName: String) -> URL? {
        let ns    = fileName as NSString
        let name  = (ns.lastPathComponent as NSString).deletingPathExtension
        let ext   = ns.pathExtension
        let dir   = ns.deletingLastPathComponent as String
        for bundle in [Bundle.main, moduleBundle] {
            if let root = bundle.resourceURL {
                let candidate = root.appendingPathComponent(fileName)
                if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            }
            if !dir.isEmpty,
               let url = bundle.url(forResource: name,
                                    withExtension: ext.isEmpty ? nil : ext,
                                    subdirectory: dir) { return url }
            if let url = bundle.url(forResource: name,
                                    withExtension: ext.isEmpty ? nil : ext) { return url }
        }
        return nil
    }

    /// Where a resolved file sits INSIDE its bundle: the path after the
    /// last `PrimaeNative_PrimaeNative.bundle/`, else after the main
    /// bundle. Two copies of the resource bundle give two absolute paths
    /// for one bundled file; this is the part that names the file.
    private static func bundleRelative(_ url: URL) -> String {
        let path = url.resolvingSymlinksInPath().path
        let marker = "PrimaeNative_PrimaeNative.bundle/"
        if let r = path.range(of: marker, options: .backwards) { return String(path[r.upperBound...]) }
        let main = Bundle.main.bundleURL.resolvingSymlinksInPath().path + "/"
        return path.hasPrefix(main) ? "main:" + path.dropFirst(main.count) : path
    }

    /// Moving the lookup must not move what it finds. Every audio name the
    /// real repository serves (letter names, phonemes — copy-prefixed
    /// forms included, exactly as the app receives them), the carrier,
    /// and the shapes the repository can also hand over (bare filename,
    /// path without the tree prefix, no extension, absent) resolve to the
    /// same bundled file — same place inside the bundle, same bytes — or
    /// to nil, under both. "Same bundled file", not "same absolute path":
    /// the test host carries two copies of the resource bundle (see
    /// `moduleBundle`); the shipped app carries one.
    @Test("the audio lookup finds exactly what the replaced loop found, for every served name")
    func audioLookupMatchesTheReplacedLoop() throws {
        let repo = LetterRepository(resources: BundleLetterResourceProvider(),
                                    cache: NullLetterCache())
        let letters = try repo.loadBundledLettersOnly().get()
        let served = letters.flatMap { $0.audioFiles + $0.phonemeAudioFiles }
        let shapes = [
            SpatialSonification.carrierToneFile,
            "spatial_carrier.wav",
            "Sonification/spatial_carrier.wav",
            "Resources/Sonification/spatial_carrier",
            "Resources/Sonification/absent_carrier.wav",
        ]
        let names = Array(Set(served + shapes)).sorted()
        #expect(served.count > 50, "vacuous: the repository served only \(served.count) audio names")

        var mismatches: [String] = []
        var resolved = 0
        for name in names {
            let now = PrimaeBundle.audioURL(for: name)
            let before = Self.replacedLoopURL(for: name)
            switch (now, before) {
            case (nil, nil):
                continue
            case let (now?, before?):
                resolved += 1
                let same = Self.bundleRelative(now) == Self.bundleRelative(before)
                    && (try? Data(contentsOf: now)) == (try? Data(contentsOf: before))
                if !same {
                    mismatches.append("\(name): now \(Self.bundleRelative(now)), before \(Self.bundleRelative(before)) (or bytes differ)")
                }
            default:
                mismatches.append("\(name): now \(now?.path ?? "nil"), before \(before?.path ?? "nil")")
            }
        }
        #expect(resolved > 50, "vacuous: only \(resolved) of \(names.count) names resolved")
        #expect(mismatches.isEmpty,
                "\(mismatches.count) of \(names.count) names resolve differently:\n\(mismatches.joined(separator: "\n"))")
    }

    // MARK: - Fonts

    /// Probes `PrimaeFonts.registrations` itself rather than a copy of the
    /// list. A test carrying its own copy proves the copy.
    @Test("every registered font face resolves")
    func everyRegisteredFontResolves() {
        let missing = PrimaeFonts.registrations.filter { name, ext in
            !Self.resolvesInPackageBundle(
                firstOf: PrimaeBundle.layouts(dir: "Fonts", name: name, ext: ext))
        }.map { "\($0.name).\($0.ext)" }

        #expect(missing.isEmpty,
                """
                \(missing.count) of \(PrimaeFonts.registrations.count) registered faces \
                are not bundled: \(missing.joined(separator: ", ")). \
                registerAll() logs a warning and returns — the app renders in the system face.
                """)
    }

    /// The negative half of `everyRegisteredFontResolves`: a font path
    /// that exists NOWHERE must resolve to `nil` through `PrimaeBundle`.
    /// This pins the nil contract only, with the bundle present; it would
    /// pass against `Bundle.module` too (which returns nil for an absent
    /// name when the bundle itself resolves). The bundle-MISSING case is
    /// `fontLookupWithoutThePackageBundleIsEmpty` below.
    @Test("a font path present nowhere resolves to nil")
    func absentFontPathResolvesToNil() {
        let layout = PrimaeBundle.layouts(dir: "Fonts", name: "Primae-NoSuchFace", ext: "otf")
        #expect(PrimaeBundle.resourceURL(firstOf: layout) == nil,
                "a font path present nowhere returned a URL — a missing face must degrade to the system font, not crash")
    }

    /// Registration's own URL list, with the package bundle taken away.
    /// `registerAll()` used to resolve through `Bundle.module` (`cb7291d`),
    /// which traps when the bundle is missing; through `PrimaeBundle` it
    /// gets an empty list, logs, and the session runs on the system face.
    /// Observable as: `fontURLs` consults only the roots it is handed. A
    /// lookup that went around them (`Bundle.module`) would still find
    /// every face here (mutation-checked: the lane receipt).
    @Test("with the package bundle missing, font registration resolves no face and reaches for no other bundle")
    @MainActor func fontLookupWithoutThePackageBundleIsEmpty() {
        // Positive control: with the real roots every face resolves.
        #expect(PrimaeFonts.fontURLs().count == PrimaeFonts.registrations.count,
                "precondition: every registered face resolves through the default roots")
        #expect(PrimaeFonts.fontURLs(roots: []).isEmpty,
                "font registration found faces with NO roots — it is reaching past PrimaeBundle")
    }

    /// The renderer probes fonts on its own path, for glyph rendering
    /// rather than UI text. Both paths, both asserted.
    @Test("the renderer's font probe resolves the default face")
    func rendererFontProbeResolves() {
        #expect(Self.resolvesInPackageBundle(
            firstOf: PrimaeLetterRenderer.fontLayouts("Primae-Regular", "otf")),
                "PrimaeLetterRenderer.makeFont cannot resolve Primae-Regular — glyph rendering falls back")
    }

    // MARK: - Effect sounds

    /// `tick_stroke` passes `systemFallback: nil`, so its absence is
    /// inaudible and unlogged past a single `log.info`.
    @Test("every effect sound PromptPlayer plays is bundled")
    func effectSoundsResolve() {
        let effects = ["tap", "tap_wrong", "tick_stroke"]
        let missing = effects.filter {
            !Self.resolvesInPackageBundle(firstOf: PromptPlayer.effectLayouts($0))
        }
        #expect(missing.isEmpty,
                "effect sounds not bundled: \(missing.joined(separator: ", ")) — these degrade to system chimes or silence")
    }

    // MARK: - Spoken prompts

    /// Protocol r9: the five recorded study prompts (voice Kiki) ARE the
    /// study voiceover. A session refuses to start without any one of them
    /// (`RecordedPromptSet.refusal`), so a build that does not carry all five
    /// is a build that cannot run — caught here, in the real bundle, rather
    /// than by a proctor with a child waiting. Resolves through the same
    /// layouts `PromptPlayer.locate` walks.
    @Test("all five recorded study prompts resolve in the package bundle)")
    func studyPromptsAreBundled() {
        let missing = RecordedPromptSet.requiredKeys.filter {
            !Self.resolvesInPackageBundle(
                firstOf: PrimaeBundle.layouts(dir: "Prompts", name: $0.rawValue, ext: "mp3"))
        }
        #expect(missing.isEmpty,
                "study prompts not bundled: \(missing.map(\.rawValue).joined(separator: ", "))")
        #expect(RecordedPromptSet.missing().isEmpty,
                "PromptPlayer.locate does not find what the layouts probe finds")
        #expect(RecordedPromptSet.setId() != nil)
    }

    // MARK: - Letter assets

    /// Enumerated through the real provider, not a fixture. Until
    /// 2026-09-06 this asserted "some audio file in each study letter's
    /// folder" — true of the letter-NAME clips, which no sound arm plays
    /// under studyMode: the phoneme arm needs `<L>_phoneme<n>.mp3`
    /// (`LetterAsset.phonemeAudioFiles`, refused otherwise) and the
    /// spatial arm plays the bundled carrier. It stayed green in exactly
    /// the state where the phoneme arm cannot start. ROADMAP H5 closed
    /// 2026-09-14: the five recordings landed, this test flipped from a
    /// `withKnownIssue` to a real failure ("Known issue was not
    /// recorded"), and the wrapper came off here so it stays a gate.
    @Test("the real bundle carries a phoneme recording for every study letter (H5)")
    func studyLetterPhonemesResolve() throws {
        let repo = LetterRepository(resources: BundleLetterResourceProvider(),
                                    cache: NullLetterCache())
        let letters = try repo.loadBundledLettersOnly().get()
        let missing = TrainedLetterSubset.studyLetters.filter { name in
            letters.first(where: { $0.name == name })?.phonemeAudioFiles.isEmpty ?? true
        }
        #expect(missing.isEmpty,
                "study letters without <L>_phoneme<n>.mp3: \(missing.joined(separator: ", "))")
    }

    @Test("the real bundle carries a NAME recording for every study letter")
    func studyLetterNameAudioResolves() throws {
        // Counterpart to `studyLetterPhonemesResolve`, and it did not exist
        // until 2026-09-18 — reported from the device as "F has no sound for
        // some reason". The phoneme path WAS pinned; the name/word path had
        // no coverage at all, so a letter whose name recordings failed to
        // resolve would have looked exactly like a letter with no assets.
        let repo = LetterRepository(resources: BundleLetterResourceProvider(),
                                    cache: NullLetterCache())
        let letters = try repo.loadBundledLettersOnly().get()
        let missing = TrainedLetterSubset.studyLetters.filter { name in
            letters.first(where: { $0.name == name })?.audioFiles.isEmpty ?? true
        }
        #expect(missing.isEmpty,
                "study letters with NO name audio resolved: \(missing.joined(separator: ", "))")
    }

    /// `_meta.json` records bake-time provenance per weight. Missing, the
    /// repository falls through to defaults without complaint.
    @Test("each bundled letter weight carries its _meta.json")
    func letterWeightMetaResolves() {
        let missing = ["Regular", "Light"].filter {
            !Self.resolvesInPackageBundle("Resources/Letters/\($0)/_meta.json")
        }
        #expect(missing.isEmpty, "weights missing _meta.json: \(missing.joined(separator: ", "))")
    }

    /// `LetterRepository.verifyBakeMetadataOnce` recomputes the bundled
    /// font's SHA-256 against `_meta.json` and LOGS a mismatch ("never
    /// fatal"). Nothing asserted it (audit 2026-09-06): a font swapped
    /// without a re-bake leaves every strokes.json golden green while the
    /// rendered ghost and the glyph-bbox → cell mapping the pinned
    /// checkpoints are projected through no longer match. Assert it here
    /// so a swap fails CI the way a strokes.json drift does.
    @Test("the bundled font matches the bake provenance hash of each weight")
    func bundledFontMatchesBakeMeta() throws {
        struct Meta: Decodable { let fontPath: String; let fontSha256: String }
        let bundle = PrimaeBundle.resources
        let roots = [bundle.bundleURL, bundle.resourceURL].compactMap { $0 }
        func url(_ rel: String) -> URL? {
            roots.map { $0.appendingPathComponent(rel) }
                 .first { FileManager.default.fileExists(atPath: $0.path) }
        }
        for weight in ["Regular", "Light"] {
            let metaURL = try #require(url("Resources/Letters/\(weight)/_meta.json"))
            let meta = try JSONDecoder().decode(Meta.self, from: Data(contentsOf: metaURL))
            let fontFile = (meta.fontPath as NSString).lastPathComponent
            let fontURL = try #require(url("Resources/Fonts/\(fontFile)"), "bundled font \(fontFile) for \(weight) missing")
            let digest = SHA256.hash(data: try Data(contentsOf: fontURL))
                .map { String(format: "%02x", $0) }.joined()
            #expect(digest == meta.fontSha256,
                    "\(weight): bundled \(fontFile) sha256 \(digest) ≠ _meta.json \(meta.fontSha256) — the strokes were baked from a different font; re-run scripts/generate_strokes_auto.py --weight \(weight.lowercased())")
        }
    }

    // MARK: - The resolver itself

    /// `layouts(dir:name:ext:)` with an empty extension used to interpolate
    /// `name.` into every layout — a file that never exists, so an
    /// extensionless resource resolved nowhere. (f65a1271 fed it
    /// `pathExtension`, which is "" for such a name, on the audio path.)
    @Test("a name without an extension is laid out as itself, never as \"name.\"")
    func extensionlessLayoutsCarryNoTrailingDot() {
        #expect(PrimaeBundle.layouts(dir: "Prompts", name: "README", ext: "")
                == ["Resources/Prompts/README", "Prompts/README", "README"])
        // Control: an extension is still joined with exactly one dot.
        #expect(PrimaeBundle.layouts(dir: "Prompts", name: "MANIFEST", ext: "json")
                == ["Resources/Prompts/MANIFEST.json", "Prompts/MANIFEST.json", "MANIFEST.json"])
    }

    /// `PrimaeBundle`'s `.main` probe exists for the host's UIAppFonts
    /// copies. It must not be the only reason a resource resolves — if the
    /// package bundle is absent entirely, every test above is measuring the
    /// host instead.
    @Test("the package resource bundle is present and is not .main")
    func packageBundleIsReal() {
        #expect(PrimaeBundle.resources != .main,
                "resolved to Bundle.main — every assertion in this suite is measuring the host bundle, not the package")
    }
}
