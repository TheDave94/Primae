import Foundation
import AVFoundation

// MARK: - Audio asset catalog protocol

protocol AudioAssetCatalog {
    /// Returns the bundle resource name (without extension) for a given letter and locale.
    func assetName(for letter: String, locale: Locale) -> String?
    /// Returns the bundle resource name for a phonetic example word.
    func exampleWordAssetName(for letter: String, locale: Locale) -> String?
}

// MARK: - Default catalog (bundled assets)

struct BundledAudioAssetCatalog: AudioAssetCatalog {
    /// Convention: "letter_a_de", "letter_a_en", etc.
    func assetName(for letter: String, locale: Locale) -> String? {
        let lang = locale.language.languageCode?.identifier ?? "de"
        let key = letter.lowercased().filter { $0.isLetter }
        guard !key.isEmpty else { return nil }
        return "letter_\(key)_\(lang)"
    }

    /// Convention: "word_a_de", "word_b_en", etc.
    func exampleWordAssetName(for letter: String, locale: Locale) -> String? {
        let lang = locale.language.languageCode?.identifier ?? "de"
        let key = letter.lowercased().filter { $0.isLetter }
        guard !key.isEmpty else { return nil }
        return "word_\(key)_\(lang)"
    }
}

// MARK: - AVAudioPlayer factory protocol (for testability)

protocol AudioPlayerFactory {
    func makePlayer(for resourceName: String, bundle: Bundle) throws -> AVAudioPlayer?
}

struct BundleAudioPlayerFactory: AudioPlayerFactory {
    func makePlayer(for resourceName: String, bundle: Bundle) throws -> AVAudioPlayer? {
        guard let url = resolveURL(for: resourceName, in: bundle) else { return nil }
        return try AVAudioPlayer(contentsOf: url)
    }

    private func resolveURL(for resourceName: String, in bundle: Bundle) -> URL? {
        let ns = resourceName as NSString
        let file = ns.lastPathComponent
        let subdir = ns.deletingLastPathComponent
        let extensions = ["mp3", "wav", "caf", "aiff", "m4a"]

        // 1. FileManager path -- most reliable for subdirectory assets on device
        if let root = bundle.resourceURL {
            let candidate = root.appendingPathComponent(resourceName)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }

        // 2. Bundle API with subdirectory
        for ext in extensions {
            if !subdir.isEmpty,
               let url = bundle.url(forResource: (file as NSString).deletingPathExtension,
                                    withExtension: ext,
                                    subdirectory: subdir) {
                return url
            }
        }

        // 3. Flat bundle lookup
        for ext in extensions {
            if let url = bundle.url(forResource: (resourceName as NSString).deletingPathExtension,
                                    withExtension: ext) {
                return url
            }
        }
        return nil
    }
}

// MARK: - Silent mode detection

protocol AudioSessionQuerying {
    var isOutputAvailable: Bool { get }
}

struct LiveAudioSessionQuery: AudioSessionQuerying {
    var isOutputAvailable: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.isEmpty == false
    }
}

// MARK: - Letter sound library

final class LetterSoundLibrary {

    private let catalog: AudioAssetCatalog
    private let factory: AudioPlayerFactory
    private let bundle: Bundle
    private let session: AudioSessionQuerying
    private var currentPlayer: AVAudioPlayer?

    init(catalog: AudioAssetCatalog = BundledAudioAssetCatalog(),
         factory: AudioPlayerFactory = BundleAudioPlayerFactory(),
         bundle: Bundle = .module,
         session: AudioSessionQuerying = LiveAudioSessionQuery()) {
        self.catalog = catalog
        self.factory = factory
        self.bundle = bundle
        self.session = session
    }

    /// Play the phonetic letter sound (e.g. "A" → "aah").
    func playLetterSound(for letter: String, locale: Locale = .current) {
        guard session.isOutputAvailable else { return }
        guard let name = catalog.assetName(for: letter, locale: locale) else { return }
        play(resourceName: name)
    }

    /// Play the example word (e.g. "A" → "Apple").
    func playExampleWord(for letter: String, locale: Locale = .current) {
        guard session.isOutputAvailable else { return }
        guard let name = catalog.exampleWordAssetName(for: letter, locale: locale) else { return }
        play(resourceName: name)
    }

    func stopCurrent() {
        currentPlayer?.stop()
        currentPlayer = nil
    }

    // MARK: Private

    private func play(resourceName: String) {
        currentPlayer?.stop()
        guard let player = try? factory.makePlayer(for: resourceName, bundle: bundle) else { return }
        player.prepareToPlay()
        player.play()
        currentPlayer = player
    }
}
