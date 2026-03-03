import Foundation

final class LetterRepository {
    struct ValidationIssue: Equatable {
        let letter: String
        let message: String
    }

    /// Native-first repository. Loads JSON-based stroke metadata and explicitly maps
    /// each letter to concrete audio/image resources in the bundle.
    func loadLetters() -> [LetterAsset] {
        let stroked = loadBundledStrokeLettersWithValidation()
        if !stroked.letters.isEmpty {
            logValidationIssues(stroked.issues)
            return stroked.letters
        }

        let folderOnly = loadBundledFolderLettersWithValidation()
        if !folderOnly.letters.isEmpty {
            logValidationIssues(folderOnly.issues)
            return folderOnly.letters
        }

        return [fallbackSampleLetter()]
    }
}

private extension LetterRepository {
    typealias ValidationResult = (letters: [LetterAsset], issues: [ValidationIssue])

    func loadBundledStrokeLettersWithValidation() -> ValidationResult {
        guard let urls = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil) else {
            return ([], [])
        }

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
                issues.append(.init(letter: base, message: "Missing PBM image (expected \(imageCandidates.joined(separator: " or ")))"))
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
        let pbms = Bundle.main.urls(forResourcesWithExtension: "pbm", subdirectory: nil) ?? []
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
        let allResources = Bundle.main.urls(forResourcesWithExtension: nil, subdirectory: nil) ?? []

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

        return Array(Set(audio)).sorted()
    }

    func bundleHasResource(at relativePath: String) -> Bool {
        let ns = relativePath as NSString
        let file = ns.lastPathComponent
        let directory = ns.deletingLastPathComponent
        if directory.isEmpty {
            return Bundle.main.url(forResource: file, withExtension: nil) != nil
        }
        return Bundle.main.url(forResource: file, withExtension: nil, subdirectory: directory) != nil
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
