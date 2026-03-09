import Foundation

protocol LetterResourceProviding {
    func allResourceURLs() -> [URL]
    func resourceURL(for relativePath: String) -> URL?
}

struct BundleLetterResourceProvider: LetterResourceProviding {
    let bundle: Bundle

    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    func allResourceURLs() -> [URL] {
        bundle.urls(forResourcesWithExtension: nil, subdirectory: nil) ?? []
    }

    func resourceURL(for relativePath: String) -> URL? {
        let ns = relativePath as NSString
        let file = ns.lastPathComponent
        let directory = ns.deletingLastPathComponent
        if directory.isEmpty {
            return bundle.url(forResource: file, withExtension: nil)
        }
        return bundle.url(forResource: file, withExtension: nil, subdirectory: directory)
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
            guard url.lastPathComponent.hasSuffix("_strokes.json") else { return nil }
            guard let data = try? Data(contentsOf: url),
                  let strokes = try? decoder.decode(LetterStrokes.self, from: data) else {
                issues.append(.init(letter: url.lastPathComponent, message: "Invalid stroke JSON"))
                return nil
            }

            let base = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_strokes", with: "")
            let imageCandidates = ["\(base)/\(base).pbm", "\(base).pbm"]
            let imageName = imageCandidates.first(where: { bundleHasResource(at: $0) }) ?? "\(base).pbm"

            if imageName == "\(base).pbm" && !bundleHasResource(at: imageName) {
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
            let imageRelative = "\(id)/\(id).pbm"
            let audio = findAudioAssets(for: id)
            if audio.isEmpty {
                issues.append(.init(letter: id, message: "No audio files found for folder-scanned letter"))
                return nil
            }

            return LetterAsset(
                id: id,
                name: id.uppercased(),
                imageName: bundleHasResource(at: imageRelative) ? imageRelative : "\(id).pbm",
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

        let audio = allResources.compactMap { url -> String? in
            let ext = url.pathExtension.lowercased()
            guard supported.contains(ext) else { return nil }

            let normalizedPath = url.path.replacingOccurrences(of: "\\", with: "/")
            let marker = "/\(base)/"
            if let markerRange = normalizedPath.range(of: marker, options: [.caseInsensitive]) {
                let relative = String(normalizedPath[markerRange.lowerBound...].dropFirst())
                return relative
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
        let key = base.uppercased()
        let mapping: [String: [String]] = [
            "A": ["A/A1.mp3", "A/A2.mp3", "A/A3.mp3", "A/Affe.mp3", "A/Sirene.mp3", "A1.mp3", "A2.mp3", "A3.mp3", "Affe.mp3", "Sirene.mp3"],
            "F": ["F/Frosch.mp3", "F/Föhn.mp3", "Frosch.mp3", "Föhn.mp3"],
            "K": ["K/K.mp3", "K/Katze.mp3", "K/Kuckuck1.mp3", "K.mp3", "Katze.mp3", "Kuckuck1.mp3"],
            "L": ["L/Löwe.mp3", "Löwe.mp3"],
            "M": ["M/Meer.mp3", "M/Möwe.mp3", "Meer.mp3", "Möwe.mp3"]
        ]

        guard let preferredOrder = mapping[key] else { return [] }
        let availableSet = Set(available)
        return preferredOrder.filter { availableSet.contains($0) }
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
        LetterStrokes(
            letter: letter,
            checkpointRadius: 0.06,
            strokes: [
                .init(id: 1, checkpoints: [.init(x: 0.3, y: 0.8), .init(x: 0.5, y: 0.2), .init(x: 0.7, y: 0.8)]),
                .init(id: 2, checkpoints: [.init(x: 0.38, y: 0.55), .init(x: 0.62, y: 0.55)])
            ]
        )
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
