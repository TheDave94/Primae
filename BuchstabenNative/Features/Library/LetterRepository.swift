import Foundation
import OSLog

private let repoLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "BuchstabenNative",
    category: "LetterRepository"
)

protocol LetterResourceProviding {
    var bundle: Bundle { get }
    var searchBundles: [Bundle] { get }
    func allResourceURLs() -> [URL]
    func resourceURL(for relativePath: String) -> URL?
}

struct BundleLetterResourceProvider: LetterResourceProviding {
    let bundle: Bundle

    init(bundle: Bundle = BundleLetterResourceProvider.safeModuleBundle()) {
        self.bundle = bundle
    }

    /// Returns Bundle.module if available, falling back to Bundle.main.
    /// Avoids the fatalError that SPM's generated Bundle.module accessor
    /// throws when the resource bundle cannot be located (e.g. in test hosts).
    private static func safeModuleBundle() -> Bundle {
        let bundleName = "BuchstabenNative_BuchstabenNative"
        let candidates: [Bundle?] = [
            Bundle(identifier: bundleName),
            Bundle.allBundles.first(where: { $0.bundlePath.hasSuffix(bundleName + ".bundle") }),
            Bundle.allFrameworks.first(where: { $0.bundlePath.hasSuffix(bundleName + ".bundle") })
        ]
        return candidates.compactMap { $0 }.first ?? .main
    }

    var searchBundles: [Bundle] {
        var bundles: [Bundle] = [bundle]
        if bundle != .main { bundles.append(.main) }
        return bundles
    }

    func allResourceURLs() -> [URL] {
        let fm = FileManager.default
        return searchBundles.flatMap { b -> [URL] in
            guard let root = b.resourceURL else { return [] }
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { return [] }
            return enumerator.compactMap { $0 as? URL }.filter {
                (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }
        }
    }

    func resourceURL(for relativePath: String) -> URL? {
        for b in searchBundles {
            guard let root = b.resourceURL else { continue }
            let candidate = root.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        let ns        = relativePath as NSString
        let file      = ns.lastPathComponent
        let directory = ns.deletingLastPathComponent
        for b in searchBundles {
            if directory.isEmpty {
                if let url = b.url(forResource: file, withExtension: nil) { return url }
            } else {
                if let url = b.url(forResource: file, withExtension: nil, subdirectory: directory) { return url }
            }
        }
        return nil
    }
}

final class LetterRepository {
    struct ValidationIssue: Equatable {
        let letter: String
        let message: String
    }

    private let resources: LetterResourceProviding
    private let cache: LetterCacheStoring
    private let userDefaults: UserDefaults

    init(resources: LetterResourceProviding = BundleLetterResourceProvider(),
         cache: LetterCacheStoring = JSONLetterCache(),
         userDefaults: UserDefaults = .standard) {
        self.resources    = resources
        self.cache        = cache
        self.userDefaults = userDefaults
    }

    /// Loads letters from bundle with cache fallback.
    /// Never returns empty — falls back to a hardcoded sample letter.
    func loadLetters() -> [LetterAsset] {
        switch loadWithErrors() {
        case .success(let letters):
            return letters
        case .failure(let error):
            logError(error)
            return [fallbackSampleLetter()]
        }
    }

    /// Typed-error variant for callers that want to surface failures.
    func loadWithErrors() -> Result<[LetterAsset], LetterRepositoryError> {
        let stroked = loadBundledStrokeLettersWithValidation()
        if !stroked.letters.isEmpty {
            logValidationIssues(stroked.issues)
            persistToCache(stroked.letters)
            return .success(stroked.letters)
        }

        let folderOnly = loadBundledFolderLettersWithValidation()
        if !folderOnly.letters.isEmpty {
            logValidationIssues(folderOnly.issues)
            persistToCache(folderOnly.letters)
            return .success(folderOnly.letters)
        }

        // Bundle failed — try cache as fallback.
        if let cached = loadFromCache() {
            repoLogger.info("Using cached letters (bundle load failed)")
            return .success(cached)
        }

        let allIssues = (stroked.issues + folderOnly.issues).map { "\($0.letter): \($0.message)" }
        if !allIssues.isEmpty {
            return .failure(.partialLoad(loaded: 0, issues: allIssues))
        }
        return .failure(.noAssetsFound)
    }

    /// Warm-launch optimisation: return the cached letters when they were
    /// written by the same app build the user is now running. Any app update
    /// (which always bumps CFBundleVersion in App Store builds) invalidates
    /// the cache automatically — no hardcoded letter count to keep in sync
    /// when the bundle gains lowercase / umlaut / digit assets.
    /// Falls back to the canonical bundle path when the cache is missing,
    /// stale, or its bundle-version sentinel is unavailable.
    func loadLettersFast() -> [LetterAsset] {
        if let bundleVersion = currentBundleVersion,
           let cachedVersion = userDefaults.string(forKey: Self.cacheBundleVersionKey),
           cachedVersion == bundleVersion,
           let cached = loadFromCache(),
           !cached.isEmpty {
            return cached
        }
        return loadLetters()
    }

    /// Storage key for the bundle-version sentinel that pairs with the cache
    /// file. Versioning the cache by app build is the standard cache-bust idiom
    /// for resource caches and avoids a hand-maintained "expected count" const.
    private static let cacheBundleVersionKey = "BuchstabenNative.LetterCache.bundleVersion"

    /// Identifier for the build that produced the cache. Combines marketing
    /// version and build number so the cache busts on either kind of release.
    /// Returns nil in environments without a bundle (e.g. unit-test hosts) so
    /// the fast path defers to the slow path rather than serving stale data.
    private var currentBundleVersion: String? {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let parts = [short, build].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "-")
    }

    // MARK: - Private

    private func persistToCache(_ letters: [LetterAsset]) {
        do {
            try cache.save(letters)
        } catch {
            // Skip the version stamp when the cache write itself failed — we
            // must never claim a valid cache exists for a build whose cache
            // file is missing or corrupt.
            return
        }
        if let version = currentBundleVersion {
            userDefaults.set(version, forKey: Self.cacheBundleVersionKey)
        }
    }

    private func loadFromCache() -> [LetterAsset]? {
        guard let letters = try? cache.load(), !letters.isEmpty else { return nil }
        // Loggig moved to the slow-path caller so the fast warm-launch path
        // (loadLettersFast -> cache hit) doesn't emit a misleading "bundle
        // load failed" message on every launch.
        return letters
    }

    private func logError(_ error: LetterRepositoryError) {
        switch error {
        case .noAssetsFound:
            repoLogger.error("No assets found in bundle or cache — using fallback letter")
        case .partialLoad(_, let issues):
            repoLogger.warning("Partial load. Issues: \(issues.joined(separator: "; "))")
        case .cacheCorrupted(let msg):
            repoLogger.error("Cache corrupted: \(msg)")
        case .cacheReadFailed(let path):
            repoLogger.warning("Cache not found at \(path)")
        }
    }
}

private extension LetterRepository {
    typealias ValidationResult = (letters: [LetterAsset], issues: [ValidationIssue])

    func loadBundledStrokeLettersWithValidation() -> ValidationResult {
        let urls    = resources.allResourceURLs().filter { $0.pathExtension.lowercased() == "json" }
        let decoder = JSONDecoder()
        var issues: [ValidationIssue] = []

        let letters = urls.compactMap { url -> LetterAsset? in
            let filename     = url.lastPathComponent
            let isStrokesFile = filename.hasSuffix("_strokes.json") || filename == "strokes.json"
            guard isStrokesFile else { return nil }
            guard let data   = try? Data(contentsOf: url),
                  let strokes = try? decoder.decode(LetterStrokes.self, from: data) else {
                issues.append(.init(letter: url.lastPathComponent, message: "Invalid stroke JSON"))
                return nil
            }

            let base: String
            if filename.hasSuffix("_strokes.json") {
                base = url.deletingPathExtension().lastPathComponent
                    .replacingOccurrences(of: "_strokes", with: "")
            } else {
                base = url.deletingLastPathComponent().lastPathComponent
            }
            guard !base.isEmpty, base.count <= 2 else { return nil }

            let imageCandidates = ["Letters/\(base)/\(base).pbm", "\(base)/\(base).pbm", "\(base).pbm"]
            let imageName = imageCandidates.first(where: { bundleHasResource(at: $0) }) ?? "\(base).pbm"

            if !bundleHasResource(at: imageName) {
                issues.append(.init(letter: base,
                    message: "Missing PBM image (expected \(imageCandidates.joined(separator: " or ")))"))
            }

            let audio = findAudioAssets(for: base)
            if audio.isEmpty {
                issues.append(.init(letter: base, message: "No audio files found in bundle for letter"))
                return nil
            }

            let baseLetter = base == "ß" ? "ß" : base.uppercased()
            let letterCase: LetterAsset.LetterCase = (base == base.lowercased() && base != base.uppercased()) ? .lower : .upper
            return LetterAsset(id: base, name: base,
                               baseLetter: baseLetter, letterCase: letterCase,
                               imageName: imageName, audioFiles: audio, strokes: strokes)
        }.sorted { $0.name < $1.name }

        return (letters, issues)
    }

    func loadBundledFolderLettersWithValidation() -> ValidationResult {
        let pbms = resources.allResourceURLs().filter { $0.pathExtension.lowercased() == "pbm" }
        var issues: [ValidationIssue] = []

        let letters = pbms.compactMap { pbm -> LetterAsset? in
            let normalized = pbm.path.replacingOccurrences(of: "\\", with: "/")
            let comps      = normalized.split(separator: "/")
            guard comps.count >= 2 else { return nil }

            let folder = String(comps[comps.count - 2])
            let file   = String(comps.last ?? "")
            guard folder.count == 1 || file.count == 5 else { return nil }

            let id            = folder.count == 1 ? folder : String(file.prefix(1))
            let imageRelative = "Letters/\(id)/\(id).pbm"
            let audio         = findAudioAssets(for: id)
            if audio.isEmpty {
                issues.append(.init(letter: id, message: "No audio files found for folder-scanned letter"))
                return nil
            }

            return LetterAsset(
                id: id, name: id.uppercased(),
                imageName: bundleHasResource(at: imageRelative) ? imageRelative : "\(id)/\(id).pbm",
                audioFiles: audio,
                strokes: defaultStrokes(for: id.uppercased())
            )
        }

        let deduped = Dictionary(grouping: letters, by: { $0.id.uppercased() })
            .compactMap { $0.value.first }
            .sorted { $0.name < $1.name }

        return (deduped, issues)
    }

    func findAudioAssets(for base: String) -> [String] {
        let supported    = Set(["mp3", "wav", "m4a", "aac", "flac", "ogg"])
        let allResources = resources.allResourceURLs()
        let bundleRoots: [String] = resources.searchBundles.compactMap {
            guard let p = $0.resourceURL?.path else { return nil }
            return p.hasSuffix("/") ? p : p + "/"
        }

        let audio = allResources.compactMap { url -> String? in
            let ext = url.pathExtension.lowercased()
            guard supported.contains(ext) else { return nil }

            let normalizedPath = url.path.replacingOccurrences(of: "\\", with: "/")
            let marker = "/\(base)/"
            if normalizedPath.range(of: marker, options: [.caseInsensitive]) != nil {
                for root in bundleRoots where normalizedPath.hasPrefix(root) {
                    return String(normalizedPath.dropFirst(root.count))
                }
                if let markerRange = normalizedPath.range(of: marker, options: [.caseInsensitive]) {
                    return String(normalizedPath[markerRange.lowerBound...].dropFirst())
                }
            }

            let file = url.lastPathComponent
            if file.lowercased().hasPrefix(base.lowercased()) { return file }
            return nil
        }

        // Filter stale references before any downstream matching so they can never
        // accidentally satisfy a letter lookup (e.g. hmmm.wav matching H via hasPrefix).
        let unique = Array(Set(audio)).sorted().filter { !isLikelyStaleAudioReference($0) }
        let preferred = preferredAudioFiles(for: base, available: unique)
        if !preferred.isEmpty { return preferred }

        if ["I", "O"].contains(base.uppercased()), let first = unique.first { return [first] }
        return unique
    }

    func preferredAudioFiles(for base: String, available: [String]) -> [String] {
        let marker = "/\(base.uppercased())/"
        let subfolderPaths = available.filter {
            $0.range(of: marker, options: .caseInsensitive) != nil
        }.sorted()
        if !subfolderPaths.isEmpty { return subfolderPaths }

        return available.filter {
            let file = ($0 as NSString).lastPathComponent
            return file.lowercased().hasPrefix(base.lowercased())
        }.sorted()
    }

    func isLikelyStaleAudioReference(_ path: String) -> Bool {
        let lower = path.lowercased()
        if lower.contains("elevenlabs_")               { return true }
        if lower.contains("friendly and approachable") { return true }
        if lower.contains("hmmm")                      { return true }
        if lower.contains(" (1).")                     { return true }
        return false
    }

    func bundleHasResource(at relativePath: String) -> Bool {
        resources.resourceURL(for: relativePath) != nil
    }

    func defaultStrokes(for letter: String) -> LetterStrokes {
        let strokes: [StrokeDefinition]
        switch letter.uppercased() {
        case "A":
            strokes = [
                .init(id: 1, checkpoints: [
                    .init(x: 0.58, y: 0.04), .init(x: 0.52, y: 0.13),
                    .init(x: 0.42, y: 0.30), .init(x: 0.34, y: 0.44),
                    .init(x: 0.25, y: 0.60), .init(x: 0.15, y: 0.78), .init(x: 0.03, y: 0.99)]),
                .init(id: 2, checkpoints: [
                    .init(x: 0.58, y: 0.04), .init(x: 0.66, y: 0.17),
                    .init(x: 0.73, y: 0.35), .init(x: 0.78, y: 0.48),
                    .init(x: 0.82, y: 0.60), .init(x: 0.90, y: 0.79), .init(x: 0.97, y: 0.98)]),
                .init(id: 3, checkpoints: [
                    .init(x: 0.26, y: 0.60), .init(x: 0.553, y: 0.60), .init(x: 0.82, y: 0.60)])
            ]
        case "F":
            strokes = [
                .init(id: 1, checkpoints: [
                    .init(x: 0.17, y: 0.05), .init(x: 0.16, y: 0.20),
                    .init(x: 0.15, y: 0.35), .init(x: 0.13, y: 0.55),
                    .init(x: 0.12, y: 0.70), .init(x: 0.10, y: 0.85), .init(x: 0.09, y: 0.95)]),
                .init(id: 2, checkpoints: [
                    .init(x: 0.17, y: 0.08), .init(x: 0.55, y: 0.06), .init(x: 0.92, y: 0.05)]),
                .init(id: 3, checkpoints: [
                    .init(x: 0.14, y: 0.48), .init(x: 0.44, y: 0.47), .init(x: 0.75, y: 0.46)])
            ]
        case "I":
            strokes = [
                .init(id: 1, checkpoints: [
                    .init(x: 0.387, y: 0.237), .init(x: 0.495, y: 0.237), .init(x: 0.602, y: 0.237)]),
                .init(id: 2, checkpoints: [
                    .init(x: 0.579, y: 0.250), .init(x: 0.579, y: 0.369),
                    .init(x: 0.579, y: 0.487), .init(x: 0.579, y: 0.646), .init(x: 0.579, y: 0.764)]),
                .init(id: 3, checkpoints: [
                    .init(x: 0.396, y: 0.771), .init(x: 0.487, y: 0.771), .init(x: 0.579, y: 0.771)])
            ]
        case "K":
            strokes = [
                .init(id: 1, checkpoints: [
                    .init(x: 0.417, y: 0.170), .init(x: 0.413, y: 0.336),
                    .init(x: 0.413, y: 0.502), .init(x: 0.413, y: 0.635), .init(x: 0.413, y: 0.801)]),
                .init(id: 2, checkpoints: [
                    .init(x: 0.685, y: 0.170), .init(x: 0.618, y: 0.270),
                    .init(x: 0.567, y: 0.419), .init(x: 0.517, y: 0.519)]),
                .init(id: 3, checkpoints: [
                    .init(x: 0.503, y: 0.480), .init(x: 0.587, y: 0.580),
                    .init(x: 0.675, y: 0.729), .init(x: 0.691, y: 0.829)])
            ]
        case "L":
            strokes = [
                .init(id: 1, checkpoints: [
                    .init(x: 0.425, y: 0.170), .init(x: 0.425, y: 0.328),
                    .init(x: 0.425, y: 0.486), .init(x: 0.425, y: 0.605), .init(x: 0.425, y: 0.763)]),
                .init(id: 2, checkpoints: [
                    .init(x: 0.293, y: 0.780), .init(x: 0.476, y: 0.780), .init(x: 0.657, y: 0.780)])
            ]
        case "M":
            strokes = [
                .init(id: 1, checkpoints: [
                    .init(x: 0.384, y: 0.170), .init(x: 0.364, y: 0.340),
                    .init(x: 0.324, y: 0.510), .init(x: 0.185, y: 0.668), .init(x: 0.209, y: 0.821)]),
                .init(id: 2, checkpoints: [
                    .init(x: 0.384, y: 0.170), .init(x: 0.396, y: 0.319),
                    .init(x: 0.413, y: 0.419), .init(x: 0.431, y: 0.519), .init(x: 0.450, y: 0.595)]),
                .init(id: 3, checkpoints: [
                    .init(x: 0.569, y: 0.595), .init(x: 0.601, y: 0.481),
                    .init(x: 0.625, y: 0.381), .init(x: 0.645, y: 0.270), .init(x: 0.658, y: 0.170)]),
                .init(id: 4, checkpoints: [
                    .init(x: 0.658, y: 0.170), .init(x: 0.658, y: 0.340),
                    .init(x: 0.672, y: 0.510), .init(x: 0.836, y: 0.668), .init(x: 0.777, y: 0.821)])
            ]
        case "O":
            strokes = [
                .init(id: 1, checkpoints: [
                    .init(x: 0.500, y: 0.197), .init(x: 0.606, y: 0.244),
                    .init(x: 0.661, y: 0.339), .init(x: 0.680, y: 0.425),
                    .init(x: 0.682, y: 0.500), .init(x: 0.680, y: 0.575),
                    .init(x: 0.661, y: 0.661), .init(x: 0.606, y: 0.756),
                    .init(x: 0.500, y: 0.802), .init(x: 0.395, y: 0.754),
                    .init(x: 0.339, y: 0.661), .init(x: 0.320, y: 0.575),
                    .init(x: 0.318, y: 0.500), .init(x: 0.320, y: 0.425),
                    .init(x: 0.339, y: 0.339), .init(x: 0.394, y: 0.244)])
            ]
        default:
            strokes = [
                .init(id: 1, checkpoints: [
                    .init(x: 0.50, y: 0.20), .init(x: 0.50, y: 0.50), .init(x: 0.50, y: 0.80)])
            ]
        }
        return LetterStrokes(letter: letter, checkpointRadius: 0.04, strokes: strokes)
    }

    func fallbackSampleLetter() -> LetterAsset {
        LetterAsset(id: "A", name: "A", imageName: "A.pbm",
                    audioFiles: ["A1.mp3"], strokes: defaultStrokes(for: "A"))
    }

    func logValidationIssues(_ issues: [ValidationIssue]) {
        for issue in issues {
            repoLogger.warning("Asset validation [\(issue.letter)]: \(issue.message)")
        }
    }
}
