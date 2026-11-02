// FontNameResolutionTests.swift — A25 (audit SURF-1/DEV-1).
// `Font.display/.body(.regular)` asked for "Primae-Regular" / "PrimaeText-Regular",
// names no bundled face carries, so default-weight text silently fell back to the
// system font. Every name the helpers can produce must resolve to a real face.

import Testing
import SwiftUI
import UIKit
@testable import PrimaeNative

@Suite @MainActor struct FontNameResolutionTests {

    static let weights: [Font.Weight] = [
        .ultraLight, .thin, .light, .regular, .medium, .semibold, .bold, .heavy, .black,
    ]

    @Test("every PostScript name the helpers produce resolves with UIFont(name:)")
    func everyProducedNameResolves() {
        PrimaeFonts.registerAll()
        var seen = Set<String>()
        for weight in Self.weights {
            for italic in [false, true] {
                for name in [primaePostScriptName(for: weight, italic: italic),
                             primaeTextPostScriptName(for: weight, italic: italic)] {
                    seen.insert(name)
                    #expect(UIFont(name: name, size: 17) != nil, "\(name) does not resolve to a bundled face")
                }
            }
        }
        // Positive control: the default-weight names are among those checked.
        #expect(seen.contains("Primae") && seen.contains("PrimaeText"))
    }

    @Test("a name no face carries does not resolve (the probe can fail)")
    func unknownNameDoesNotResolve() {
        PrimaeFonts.registerAll()
        #expect(UIFont(name: "Primae-Regular", size: 17) == nil)
    }
}
