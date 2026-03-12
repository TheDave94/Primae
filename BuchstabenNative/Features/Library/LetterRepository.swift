import Foundation

protocol LetterResourceProviding {
    var bundle: Bundle { get }
    var searchBundles: [Bundle] { get }
    func allResourceURLs() -> [URL]
    func resourceURL(for relativePath: String) -> URL?
}

struct BundleLetterResourceProvider: LetterResourceProviding {
    let bundle: Bundle

    init(bundle: Bundle = .module) {
        self.bundle = bundle
    }

    /// All bundles to search: the Swift PM module bundle + Bundle.main.
    /// When running as an Xcode app target, the Letters folder is in Bundle.main
    /// (added via Copy Bundle Resources). When running via Swift PM directly,
    /// it lives in Bundle.module. We search both to cover both cases.
    var searchBundles: [Bundle] {
        var bundles: [Bundle] = [bundle]
        if bundle != .main { bundles.append(.main) }
        return bundles
    }

    /// Enumerate all files from all search bundles using FileManager deep traversal.
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
        // Fallback: bundle API
        let ns = relativePath as NSString
        let file = ns.lastPathComponent
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

    init(resources: LetterResourceProviding = BundleLetterResourceProvider(),
         cache: LetterCacheStoring = JSONLetterCache()) {
        self.resources = resources
        self.cache = cache
    }

    /// Loads letters from bundle with cache fallback.
    /// - Returns letters on success (never empty — uses cache or fallback)
    /// - Throws `LetterRepositoryError` only when both bundle AND cache fail
    func loadLetters() -> [LetterAsset] {
        let result = loadWithErrors()
        switch result {
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
            if !stroked.issues.isEmpty {
                return .success(stroked.letters)   // partial load — letters available, issues logged
            }
            return .success(stroked.letters)
        }

        let folderOnly = loadBundledFolderLettersWithValidation()
        if !folderOnly.letters.isEmpty {
            logValidationIssues(folderOnly.issues)
            persistToCache(folderOnly.letters)
            return .success(folderOnly.letters)
        }

        // Bundle failed — try cache
        if let cached = loadFromCache() {
            return .success(cached)   // cache hit — surface issues but don't fail
        }

        // Both bundle and cache failed
        let allIssues = (stroked.issues + folderOnly.issues).map { "\($0.letter): \($0.message)" }
        if !allIssues.isEmpty {
            return .failure(.partialLoad(loaded: 0, issues: allIssues))
        }
        return .failure(.noAssetsFound)
    }

    // MARK: - Private

    private func persistToCache(_ letters: [LetterAsset]) {
        try? cache.save(letters)
    }

    private func loadFromCache() -> [LetterAsset]? {
        guard let letters = try? cache.load(), !letters.isEmpty else { return nil }
        print("ℹ️ LetterRepository: using cached letters (bundle load failed)")
        return letters
    }

    private func logError(_ error: LetterRepositoryError) {
        switch error {
        case .noAssetsFound:
            print("❌ LetterRepository: no assets found in bundle or cache — using fallback")
        case .partialLoad(_, let issues):
            print("⚠️ LetterRepository: partial load. Issues: \(issues.joined(separator: "; "))")
        case .cacheCorrupted(let msg):
            print("❌ LetterRepository: cache corrupted — \(msg)")
        case .cacheReadFailed(let path):
            print("⚠️ LetterRepository: cache not found at \(path)")
        }
    }
}

private extension LetterRepository {
    typealias ValidationResult = (letters: [LetterAsset], issues: [ValidationIssue])

    func loadBundledStrokeLettersWithValidation() -> ValidationResult {
        let urls = resources.allResourceURLs().filter { $0.pathExtension.lowercased() == "json" }

        let decoder = JSONDecoder()
        var issues: [ValidationIssue] = []

        let letters = urls.compactMap { url -> LetterAsset? in
            // Accept both "A_strokes.json" (old convention) and "strokes.json" (current convention
            // where the file lives inside a per-letter folder like Letters/A/strokes.json).
            let filename = url.lastPathComponent
            let isStrokesFile = filename.hasSuffix("_strokes.json") || filename == "strokes.json"
            guard isStrokesFile else { return nil }
            guard let data = try? Data(contentsOf: url),
                  let strokes = try? decoder.decode(LetterStrokes.self, from: data) else {
                issues.append(.init(letter: url.lastPathComponent, message: "Invalid stroke JSON"))
                return nil
            }

            // Derive the letter base: "A_strokes.json" → "A", or "strokes.json" inside Letters/A/ → "A"
            let base: String
            if filename.hasSuffix("_strokes.json") {
                base = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_strokes", with: "")
            } else {
                // "strokes.json" — use the parent folder name (e.g. Letters/A/strokes.json → "A")
                base = url.deletingLastPathComponent().lastPathComponent
            }
            guard !base.isEmpty, base.count <= 2 else { return nil }
            let imageCandidates = ["Letters/\(base)/\(base).pbm", "\(base)/\(base).pbm", "\(base).pbm"]
            let imageName = imageCandidates.first(where: { bundleHasResource(at: $0) }) ?? "\(base).pbm"

            if !bundleHasResource(at: imageName) {
                issues.append(.init(letter: base, message: "Missing PBM image (expected \(imageCandidates.joined(separator: " or "))"))
            }

            let audio = findAudioAssets(for: base)
            if audio.isEmpty {
                issues.append(.init(letter: base, message: "No audio files found in bundle for letter"))
                return nil
            }

            return LetterAsset(
                id: base,
                name: base.uppercased(),
                imageName: imageName,
                audioFiles: audio,
                strokes: strokes
            )
        }.sorted { $0.name < $1.name }

        return (letters, issues)
    }

    func loadBundledFolderLettersWithValidation() -> ValidationResult {
        let pbms = resources.allResourceURLs().filter { $0.pathExtension.lowercased() == "pbm" }
        var issues: [ValidationIssue] = []

        let letters = pbms.compactMap { pbm -> LetterAsset? in
            let normalized = pbm.path.replacingOccurrences(of: "\\", with: "/")
            let comps = normalized.split(separator: "/")
            guard comps.count >= 2 else { return nil }

            let folder = String(comps[comps.count - 2])
            let file = String(comps.last ?? "")
            guard folder.count == 1 || file.count == 5 else { return nil }

            let id = folder.count == 1 ? folder : String(file.prefix(1))
            let imageRelative = "Letters/\(id)/\(id).pbm"
            let audio = findAudioAssets(for: id)
            if audio.isEmpty {
                issues.append(.init(letter: id, message: "No audio files found for folder-scanned letter"))
                return nil
            }

            return LetterAsset(
                id: id,
                name: id.uppercased(),
                imageName: bundleHasResource(at: imageRelative) ? imageRelative : "\(id)/\(id).pbm",
                audioFiles: audio,
                strokes: defaultStrokes(for: id.uppercased())
            )
        }

        let deduped = Dictionary(grouping: letters, by: { $0.id.uppercased() }).compactMap { $0.value.first }
            .sorted { $0.name < $1.name }

        return (deduped, issues)
    }

    func findAudioAssets(for base: String) -> [String] {
        let supported = Set(["mp3", "wav", "m4a", "aac", "flac", "ogg"])
        let allResources = resources.allResourceURLs()
        // Collect all bundle roots (with trailing slash) for relative path computation
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
                // Return path relative to its bundle root (e.g. "Letters/A/A1.mp3")
                for root in bundleRoots {
                    if normalizedPath.hasPrefix(root) {
                        return String(normalizedPath.dropFirst(root.count))
                    }
                }
                // Fallback: return the letter-folder-relative path (old behaviour)
                if let markerRange = normalizedPath.range(of: marker, options: [.caseInsensitive]) {
                    return String(normalizedPath[markerRange.lowerBound...].dropFirst())
                }
            }

            let file = url.lastPathComponent
            if file.lowercased().hasPrefix(base.lowercased()) {
                return file
            }

            return nil
        }

        let unique = Array(Set(audio)).sorted()

        let preferred = preferredAudioFiles(for: base, available: unique)
        if !preferred.isEmpty {
            return preferred
        }

        let cleaned = unique.filter { !isLikelyStaleAudioReference($0) }
        if !cleaned.isEmpty {
            return cleaned
        }

        // If only autogenerated leftovers exist (e.g. I/O currently), keep one deterministic fallback.
        if ["I", "O"].contains(base.uppercased()), let first = unique.first {
            return [first]
        }

        return unique
    }

    func preferredAudioFiles(for base: String, available: [String]) -> [String] {
        // Pick paths that are inside the letter subfolder (e.g. contain "/A/" or end with "/A/xxx.mp3").
        // This works regardless of whether the path is "Letters/A/A1.mp3" or
        // "BuchstabenNative_BuchstabenNative.bundle/Letters/A/A1.mp3".
        let marker = "/\(base.uppercased())/"
        let subfolderPaths = available.filter {
            $0.range(of: marker, options: .caseInsensitive) != nil
        }.sorted()
        if !subfolderPaths.isEmpty { return subfolderPaths }

        // Fallback: flat files that start with the letter name
        let flatPaths = available.filter {
            let file = ($0 as NSString).lastPathComponent
            return file.lowercased().hasPrefix(base.lowercased())
        }.sorted()
        return flatPaths
    }
    func isLikelyStaleAudioReference(_ path: String) -> Bool {
        let lower = path.lowercased()
        if lower.contains("elevenlabs_") { return true }
        if lower.contains("friendly and approachable") { return true }
        if lower.contains("hmmm") { return true }
        if lower.contains(" (1).") { return true }
        return false
    }

    func bundleHasResource(at relativePath: String) -> Bool {
        resources.resourceURL(for: relativePath) != nil
    }

    func defaultStrokes(for letter: String) -> LetterStrokes {
        // Coordinates measured from real device debug screenshots in the legacy Timestretch build.
        // Matches strokes.json files exactly — stroke order, direction, and checkpoint positions.
        let strokes: [StrokeDefinition]
        switch letter.uppercased() {
        case "A":
            strokes = [
                // Stroke 1: left leg — apex (top-center) DOWN to bottom-left
                .init(id: 1, checkpoints: [
                    .init(x: 0.507, y: 0.240), .init(x: 0.477, y: 0.379),
                    .init(x: 0.410, y: 0.569), .init(x: 0.360, y: 0.759)
                ]),
                // Stroke 2: right leg — apex (top-center) DOWN to bottom-right
                .init(id: 2, checkpoints: [
                    .init(x: 0.532, y: 0.240), .init(x: 0.578, y: 0.379),
                    .init(x: 0.632, y: 0.547), .init(x: 0.678, y: 0.759)
                ]),
                // Stroke 3: crossbar — left to right
                .init(id: 3, checkpoints: [
                    .init(x: 0.377, y: 0.597), .init(x: 0.511, y: 0.597), .init(x: 0.620, y: 0.597)
                ])
            ]
        case "F":
            strokes = [
                // Stroke 1: vertical spine — top to bottom
                .init(id: 1, checkpoints: [
                    .init(x: 0.444, y: 0.251), .init(x: 0.436, y: 0.424),
                    .init(x: 0.431, y: 0.569), .init(x: 0.444, y: 0.759)
                ]),
                // Stroke 2: top crossbar — left to right
                .init(id: 2, checkpoints: [
                    .init(x: 0.456, y: 0.268), .init(x: 0.570, y: 0.268), .init(x: 0.670, y: 0.279)
                ]),
                // Stroke 3: mid crossbar — left to right
                .init(id: 3, checkpoints: [
                    .init(x: 0.452, y: 0.508), .init(x: 0.536, y: 0.508), .init(x: 0.607, y: 0.511)
                ])
            ]
        case "I":
            strokes = [
                // Stroke 1: straight down
                .init(id: 1, checkpoints: [
                    .init(x: 0.532, y: 0.234), .init(x: 0.532, y: 0.396),
                    .init(x: 0.532, y: 0.558), .init(x: 0.532, y: 0.776)
                ])
            ]
        case "K":
            strokes = [
                // Stroke 1: vertical spine — top to bottom
                .init(id: 1, checkpoints: [
                    .init(x: 0.465, y: 0.223), .init(x: 0.436, y: 0.413),
                    .init(x: 0.431, y: 0.580), .init(x: 0.431, y: 0.770)
                ]),
                // Stroke 2: upper arm — top-right DOWN-LEFT to junction
                .init(id: 2, checkpoints: [
                    .init(x: 0.637, y: 0.223), .init(x: 0.578, y: 0.352), .init(x: 0.536, y: 0.480)
                ]),
                // Stroke 3: lower arm — junction DOWN-RIGHT to bottom-right
                .init(id: 3, checkpoints: [
                    .init(x: 0.523, y: 0.519), .init(x: 0.586, y: 0.642), .init(x: 0.653, y: 0.781)
                ])
            ]
        case "L":
            strokes = [
                // Stroke 1: vertical stroke — top to bottom
                .init(id: 1, checkpoints: [
                    .init(x: 0.448, y: 0.234), .init(x: 0.446, y: 0.379),
                    .init(x: 0.444, y: 0.547), .init(x: 0.448, y: 0.731)
                ]),
                // Stroke 2: baseline foot — left to right
                .init(id: 2, checkpoints: [
                    .init(x: 0.448, y: 0.748), .init(x: 0.536, y: 0.753), .init(x: 0.624, y: 0.753)
                ])
            ]
        case "M":
            strokes = [
                // Stroke 1: left spine — top-left down to bottom-left
                .init(id: 1, checkpoints: [
                    .init(x: 0.302, y: 0.301), .init(x: 0.293, y: 0.446),
                    .init(x: 0.289, y: 0.603), .init(x: 0.297, y: 0.759)
                ]),
                // Stroke 2: left diagonal — top-left DOWN-RIGHT to valley
                .init(id: 2, checkpoints: [
                    .init(x: 0.369, y: 0.257), .init(x: 0.436, y: 0.413),
                    .init(x: 0.482, y: 0.519), .init(x: 0.511, y: 0.625)
                ]),
                // Stroke 3: right diagonal — valley UP-RIGHT to top-right
                .init(id: 3, checkpoints: [
                    .init(x: 0.549, y: 0.608), .init(x: 0.607, y: 0.480),
                    .init(x: 0.645, y: 0.391), .init(x: 0.670, y: 0.312)
                ]),
                // Stroke 4: right spine — top-right down to bottom-right
                .init(id: 4, checkpoints: [
                    .init(x: 0.737, y: 0.240), .init(x: 0.745, y: 0.413),
                    .init(x: 0.750, y: 0.592), .init(x: 0.754, y: 0.770)
                ])
            ]
        case "O":
            strokes = [
                // Stroke 1: clockwise oval from top-left all the way around
                .init(id: 1, checkpoints: [
                    .init(x: 0.436, y: 0.268), .init(x: 0.523, y: 0.257),
                    .init(x: 0.641, y: 0.268), .init(x: 0.720, y: 0.368),
                    .init(x: 0.737, y: 0.491), .init(x: 0.716, y: 0.625),
                    .init(x: 0.657, y: 0.725), .init(x: 0.553, y: 0.765),
                    .init(x: 0.440, y: 0.725), .init(x: 0.356, y: 0.608),
                    .init(x: 0.335, y: 0.480), .init(x: 0.356, y: 0.357)
                ])
            ]
        default:
            strokes = [
                .init(id: 1, checkpoints: [.init(x: 0.50, y: 0.20), .init(x: 0.50, y: 0.50), .init(x: 0.50, y: 0.80)])
            ]
        }
        return LetterStrokes(letter: letter, checkpointRadius: 0.04, strokes: strokes)
    }

    func fallbackSampleLetter() -> LetterAsset {
        LetterAsset(id: "A", name: "A", imageName: "A.pbm", audioFiles: ["A.mp3"], strokes: defaultStrokes(for: "A"))
    }

    func logValidationIssues(_ issues: [ValidationIssue]) {
        guard !issues.isEmpty else { return }
        for issue in issues {
            print("⚠️ Asset validation [\(issue.letter)]: \(issue.message)")
        }
    }
}
