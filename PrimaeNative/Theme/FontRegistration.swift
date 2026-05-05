// FontRegistration.swift
// PrimaeNative — Theme
//
// Register the bundled Primae / PrimaeText / Playwrite AT fonts with
// CoreText. The fonts ship inside the SPM resource bundle
// (`Bundle.module`), not the main bundle, so the `UIAppFonts`
// Info.plist key can't reach them — we register programmatically with
// `CTFontManagerRegisterFontsForURLs`. Call `PrimaeFonts.registerAll()`
// once at app launch (host app's `App.init()`). Idempotent.

import CoreText
import Foundation
import os.log

public enum PrimaeFonts {

    /// Bundled font filenames (no extension). Keep in sync with the
    /// files in `PrimaeNative/Resources/Fonts/` and
    /// `INFOPLIST_KEY_UIAppFonts` in `Primae.xcodeproj`.
    private static let registrations: [(name: String, ext: String)] = [
        ("Primae-Light",                "otf"),
        ("Primae-LightCursive",         "otf"),
        ("Primae-Semilight",            "otf"),
        ("Primae-SemilightCursive",     "otf"),
        ("Primae-Regular",              "otf"),
        ("Primae-Cursive",              "otf"),
        ("Primae-Semibold",             "otf"),
        ("Primae-SemiboldCursive",      "otf"),
        ("Primae-Bold",                 "otf"),
        ("Primae-BoldCursive",          "otf"),
        ("PrimaeText-Light",            "otf"),
        ("PrimaeText-LightCursive",     "otf"),
        ("PrimaeText-Semilight",        "otf"),
        ("PrimaeText-SemilightCursive", "otf"),
        ("PrimaeText-Regular",          "otf"),
        ("PrimaeText-Cursive",          "otf"),
        ("PrimaeText-Semibold",         "otf"),
        ("PrimaeText-SemiboldCursive",  "otf"),
        ("PrimaeText-Bold",             "otf"),
        ("PrimaeText-BoldCursive",      "otf"),
        ("PlaywriteAT-Regular",         "ttf"),
    ]

    /// Already-registered marker. Prevents log spam when callers
    /// invoke `registerAll()` multiple times in a session.
    nonisolated(unsafe) private static var didRegister = false
    private static let log = Logger(subsystem: "buchstaben.primae", category: "fonts")

    /// Register every bundled face. Safe to call repeatedly.
    public static func registerAll() {
        guard !didRegister else { return }
        didRegister = true

        // Probe `Bundle.module` first, then `.main` as a fallback for
        // hosts that embed the fonts directly.
        let bundles: [Bundle] = [.module, .main]
        let subdirs: [String?] = ["Resources/Fonts", "Fonts", nil]

        var urls: [URL] = []
        for (name, ext) in registrations {
            for bundle in bundles {
                var url: URL?
                for subdir in subdirs {
                    if let subdir {
                        url = bundle.url(forResource: name, withExtension: ext, subdirectory: subdir)
                    } else {
                        url = bundle.url(forResource: name, withExtension: ext)
                    }
                    if url != nil { break }
                }
                if let url {
                    urls.append(url)
                    break
                }
            }
        }

        guard !urls.isEmpty else {
            log.warning("PrimaeFonts.registerAll: no font URLs resolved — Resources/Fonts/ may be missing from the bundle.")
            return
        }

        var errorRef: Unmanaged<CFArray>?
        let ok = CTFontManagerRegisterFontsForURLs(
            urls as CFArray,
            .process,
            &errorRef
        )
        if !ok, let errArray = errorRef?.takeRetainedValue() as? [CFError] {
            // Code 105 is `kCTFontManagerErrorAlreadyRegistered` —
            // expected on repeat calls; ignore.
            for err in errArray {
                let code = CFErrorGetCode(err)
                if code == 105 { continue }
                log.error("PrimaeFonts: register failed code=\(code) desc=\(CFErrorCopyDescription(err) as String? ?? "?")")
            }
        }
    }
}
