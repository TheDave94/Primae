//  LetterSoundLibraryTests.swift
//  BuchstabenNativeTests

import Testing
import Foundation
import AVFoundation
@testable import BuchstabenNative

// MARK: - Mock catalog

final class MockAudioAssetCatalog: AudioAssetCatalog {
    var assetNames: [String: String] = [:]
    var wordNames: [String: String] = [:]
    func assetName(for letter: String, locale: Locale) -> String? { assetNames[letter.uppercased()] }
    func exampleWordAssetName(for letter: String, locale: Locale) -> String? { wordNames[letter.uppercased()] }
}

// MARK: - Mock player factory

final class MockAudioPlayerFactory: AudioPlayerFactory {
    var shouldFail = false
    private(set) var requestedNames: [String] = []
    func makePlayer(for resourceName: String, bundle: Bundle) throws -> AVAudioPlayer? {
        requestedNames.append(resourceName)
        return nil
    }
}

// MARK: - Mock audio session

struct MockAudioSessionQuery: AudioSessionQuerying {
    var isOutputAvailable: Bool
}

// MARK: - BundledAudioAssetCatalog tests

@Suite @MainActor struct BundledAudioAssetCatalogTests {
    let catalog = BundledAudioAssetCatalog()

    @Test func assetName_germanLocale() {
        #expect(catalog.assetName(for: "A", locale: Locale(identifier: "de")) == "letter_a_de")
    }

    @Test func assetName_englishLocale() {
        #expect(catalog.assetName(for: "B", locale: Locale(identifier: "en")) == "letter_b_en")
    }

    @Test func assetName_lowercaseInput_normalized() {
        #expect(catalog.assetName(for: "c", locale: Locale(identifier: "de")) == "letter_c_de")
    }

    @Test func assetName_emptyString_returnsNil() {
        #expect(catalog.assetName(for: "", locale: Locale(identifier: "de")) == nil)
    }

    @Test func assetName_nonLetter_returnsNil() {
        #expect(catalog.assetName(for: "1", locale: Locale(identifier: "de")) == nil)
    }

    @Test func exampleWordAssetName_germanLocale() {
        #expect(catalog.exampleWordAssetName(for: "A", locale: Locale(identifier: "de")) == "word_a_de")
    }

    @Test func exampleWordAssetName_englishLocale() {
        #expect(catalog.exampleWordAssetName(for: "Z", locale: Locale(identifier: "en")) == "word_z_en")
    }

    @Test func allAlphabetLetters_producesName() {
        for ch in "ABCDEFGHIJKLMNOPQRSTUVWXYZ" {
            let name = catalog.assetName(for: String(ch), locale: Locale(identifier: "de"))
            #expect(name != nil, "Expected name for letter \(ch)")
            #expect(name?.hasPrefix("letter_") == true)
        }
    }
}

// MARK: - LetterSoundLibrary tests

private func makeLibrary(
    outputAvailable: Bool = true,
    factory: MockAudioPlayerFactory = MockAudioPlayerFactory(),
    catalog: MockAudioAssetCatalog? = nil
) -> (LetterSoundLibrary, MockAudioPlayerFactory, MockAudioAssetCatalog) {
    let cat = catalog ?? MockAudioAssetCatalog()
    cat.assetNames["A"] = "letter_a_de"
    cat.assetNames["B"] = "letter_b_de"
    cat.wordNames["A"]  = "word_a_de"
    let lib = LetterSoundLibrary(
        catalog: cat, factory: factory, bundle: .main,
        session: MockAudioSessionQuery(isOutputAvailable: outputAvailable)
    )
    return (lib, factory, cat)
}

@Suite struct LetterSoundLibraryTests {

    @Test func playLetterSound_requestsCorrectAssetName() {
        let factory = MockAudioPlayerFactory()
        let (lib, _, _) = makeLibrary(factory: factory)
        lib.playLetterSound(for: "A", locale: Locale(identifier: "de"))
        #expect(factory.requestedNames.contains("letter_a_de"))
    }

    @Test func playExampleWord_requestsCorrectAssetName() {
        let factory = MockAudioPlayerFactory()
        let (lib, _, _) = makeLibrary(factory: factory)
        lib.playExampleWord(for: "A", locale: Locale(identifier: "de"))
        #expect(factory.requestedNames.contains("word_a_de"))
    }

    @Test func silentMode_skipsPlayback() {
        let factory = MockAudioPlayerFactory()
        let (lib, _, _) = makeLibrary(outputAvailable: false, factory: factory)
        lib.playLetterSound(for: "A", locale: Locale(identifier: "de"))
        #expect(factory.requestedNames.isEmpty, "Should not request player when output unavailable")
    }

    @Test func unknownLetter_noAsset_skipsPlayback() {
        let factory = MockAudioPlayerFactory()
        let (lib, _, _) = makeLibrary(factory: factory, catalog: MockAudioAssetCatalog())
        lib.playLetterSound(for: "Q", locale: Locale(identifier: "de"))
        #expect(factory.requestedNames.isEmpty)
    }

    @Test func playLetterSound_emptyCatalog_doesNotCrash() {
        let factory = MockAudioPlayerFactory()
        let (lib, _, _) = makeLibrary(outputAvailable: true, factory: factory)
        lib.playLetterSound(for: "Z", locale: Locale(identifier: "de"))
        // no throw = pass
    }

    @Test func stopCurrent_doesNotCrash_whenNothingPlaying() {
        let (lib, _, _) = makeLibrary()
        lib.stopCurrent()
        // no throw = pass
    }

    @Test func playLetterSound_letterB_requestsLetterB() {
        let factory = MockAudioPlayerFactory()
        let (lib, _, _) = makeLibrary(factory: factory)
        lib.playLetterSound(for: "B", locale: Locale(identifier: "de"))
        #expect(factory.requestedNames.contains("letter_b_de"))
    }

    @Test func consecutivePlays_bothRequested() {
        let factory = MockAudioPlayerFactory()
        let (lib, _, _) = makeLibrary(factory: factory)
        lib.playLetterSound(for: "A", locale: Locale(identifier: "de"))
        lib.playLetterSound(for: "B", locale: Locale(identifier: "de"))
        #expect(factory.requestedNames.count == 2)
    }
}
