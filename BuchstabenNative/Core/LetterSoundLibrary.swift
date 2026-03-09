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
        guard let url = bundle.url(forResource: resourceName, withExtension: "mp3")
               ?? bundle.url(forResource: resourceName, withExtension: "caf")
               ?? bundle.url(forResource: resourceName, withExtension: "aiff") else {
            return nil
        }
        return try AVAudioPlayer(contentsOf: url)
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
         bundle: Bundle = .main,
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
