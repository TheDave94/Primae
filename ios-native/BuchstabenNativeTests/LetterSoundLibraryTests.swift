//  LetterSoundLibraryTests.swift
//  BuchstabenNativeTests

import XCTest
import AVFoundation
@testable import BuchstabenNative

// MARK: - Mock catalog

final class MockAudioAssetCatalog: AudioAssetCatalog {
    var assetNames: [String: String] = [:]
    var wordNames: [String: String] = [:]

    func assetName(for letter: String, locale: Locale) -> String? {
        assetNames[letter.uppercased()]
    }
    func exampleWordAssetName(for letter: String, locale: Locale) -> String? {
        wordNames[letter.uppercased()]
    }
}

// MARK: - Mock player factory

final class MockAudioPlayerFactory: AudioPlayerFactory {
    var shouldFail = false
    private(set) var requestedNames: [String] = []

    func makePlayer(for resourceName: String, bundle: Bundle) throws -> AVAudioPlayer? {
        requestedNames.append(resourceName)
        if shouldFail { return nil }
        // Return nil (no real audio file in test bundle) but record the call
        return nil
    }
}

// MARK: - Mock audio session

struct MockAudioSessionQuery: AudioSessionQuerying {
    var isOutputAvailable: Bool
}

// MARK: - BundledAudioAssetCatalog tests

final class BundledAudioAssetCatalogTests: XCTestCase {

    private let catalog = BundledAudioAssetCatalog()

    func testAssetName_germanLocale() {
        let name = catalog.assetName(for: "A", locale: Locale(identifier: "de"))
        XCTAssertEqual(name, "letter_a_de")
    }

    func testAssetName_englishLocale() {
        let name = catalog.assetName(for: "B", locale: Locale(identifier: "en"))
        XCTAssertEqual(name, "letter_b_en")
    }

    func testAssetName_lowercaseInput_normalized() {
        let name = catalog.assetName(for: "c", locale: Locale(identifier: "de"))
        XCTAssertEqual(name, "letter_c_de")
    }

    func testAssetName_emptyString_returnsNil() {
        XCTAssertNil(catalog.assetName(for: "", locale: Locale(identifier: "de")))
    }

    func testAssetName_nonLetter_returnsNil() {
        XCTAssertNil(catalog.assetName(for: "1", locale: Locale(identifier: "de")))
    }

    func testExampleWordAssetName_germanLocale() {
        let name = catalog.exampleWordAssetName(for: "A", locale: Locale(identifier: "de"))
        XCTAssertEqual(name, "word_a_de")
    }

    func testExampleWordAssetName_englishLocale() {
        let name = catalog.exampleWordAssetName(for: "Z", locale: Locale(identifier: "en"))
        XCTAssertEqual(name, "word_z_en")
    }

    func testAllAlphabetLetters_producesName() {
        for ch in "ABCDEFGHIJKLMNOPQRSTUVWXYZ" {
            let name = catalog.assetName(for: String(ch), locale: Locale(identifier: "de"))
            XCTAssertNotNil(name, "Expected name for letter \(ch)")
            XCTAssertTrue(name!.hasPrefix("letter_"))
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
    cat.wordNames["A"] = "word_a_de"

    let lib = LetterSoundLibrary(
        catalog: cat,
        factory: factory,
        bundle: .main,
        session: MockAudioSessionQuery(isOutputAvailable: outputAvailable)
    )
    return (lib, factory, cat)
}

final class LetterSoundLibraryTests: XCTestCase {

    func testPlayLetterSound_requestsCorrectAssetName() {
        let factory = MockAudioPlayerFactory()
        let (lib, _, _) = makeLibrary(factory: factory)
        lib.playLetterSound(for: "A", locale: Locale(identifier: "de"))
        XCTAssertTrue(factory.requestedNames.contains("letter_a_de"))
    }

    func testPlayExampleWord_requestsCorrectAssetName() {
        let factory = MockAudioPlayerFactory()
        let (lib, _, _) = makeLibrary(factory: factory)
        lib.playExampleWord(for: "A", locale: Locale(identifier: "de"))
        XCTAssertTrue(factory.requestedNames.contains("word_a_de"))
    }

    func testSilentMode_skipsPlayback() {
        let factory = MockAudioPlayerFactory()
        let (lib, _, _) = makeLibrary(outputAvailable: false, factory: factory)
        lib.playLetterSound(for: "A", locale: Locale(identifier: "de"))
        XCTAssertTrue(factory.requestedNames.isEmpty, "Should not request player when output unavailable")
    }

    func testUnknownLetter_noAsset_skipsPlayback() {
        let factory = MockAudioPlayerFactory()
        let cat = MockAudioAssetCatalog() // no entries
        let (lib, _, _) = makeLibrary(factory: factory, catalog: cat)
        lib.playLetterSound(for: "Q", locale: Locale(identifier: "de"))
        XCTAssertTrue(factory.requestedNames.isEmpty)
    }

    func testPlayLetterSound_emptyCatalog_doesNotCrash() {
        let factory = MockAudioPlayerFactory()
        let (lib, _, _) = makeLibrary(outputAvailable: true, factory: factory)
        XCTAssertNoThrow(lib.playLetterSound(for: "Z", locale: Locale(identifier: "de")))
    }

    func testStopCurrent_doesNotCrash_whenNothingPlaying() {
        let (lib, _, _) = makeLibrary()
        XCTAssertNoThrow(lib.stopCurrent())
    }

    func testPlayLetterSound_letterB_requestsLetterB() {
        let factory = MockAudioPlayerFactory()
        let (lib, _, _) = makeLibrary(factory: factory)
        lib.playLetterSound(for: "B", locale: Locale(identifier: "de"))
        XCTAssertTrue(factory.requestedNames.contains("letter_b_de"))
    }

    func testConsecutivePlays_bothRequested() {
        let factory = MockAudioPlayerFactory()
        let (lib, _, _) = makeLibrary(factory: factory)
        lib.playLetterSound(for: "A", locale: Locale(identifier: "de"))
        lib.playLetterSound(for: "B", locale: Locale(identifier: "de"))
        XCTAssertEqual(factory.requestedNames.count, 2)
    }
}
