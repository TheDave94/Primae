// FontRegistration.swift
// PrimaeNative — Theme
//
// Register the bundled Primae / PrimaeText / Playwrite AT fonts with
// CoreText so SwiftUI's `Font.custom(...)` and UIKit's
// `UIFont(name: ...)` can find them by PostScript name.
//
// Why this exists: the fonts ship inside the SPM package's resource
// bundle (`Bundle.module`), not the host app's main bundle. The
// `UIAppFonts` Info.plist key only registers fonts located in the
// main bundle, so SPM-bundled fonts have to be registered
// programmatically with `CTFontManagerRegisterFontsForURLs`. Call
// `PrimaeFonts.registerAll()` once at app launch (the host app's
// `App.init()` is the natural place).
//
// Idempotent: a second call after the first is a no-op (CoreText
// returns "already registered" errors which are safely ignored).

import CoreText
import Foundation
import os.log

public enum PrimaeFonts {

    /// Every bundled font filename (no extension) that needs CoreText
    /// registration. Keep in sync with the files in
    /// `PrimaeNative/Resources/Fonts/` and the `INFOPLIST_KEY_UIAppFonts`
    /// build setting in `Primae.xcodeproj`.
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

    /// Already-registered marker. Prevents repeat work — and the
    /// log-spam — when something calls `registerAll()` more than
    /// once during a session (for example a SwiftUI Preview that
    /// boots the app type more than once).
    nonisolated(unsafe) private static var didRegister = false
    private static let log = Logger(subsystem: "buchstaben.primae", category: "fonts")

    /// Register every bundled Primae/PrimaeText/Playwrite face with
    /// CoreText. Safe to call repeatedly — only the first call does
    /// real work.
    public static func registerAll() {
        guard !didRegister else { return }
        didRegister = true

        // Probe `Bundle.module` (SPM-bundled location) first, then the
        // main bundle as a fallback for the rare case where the host
        // app embedded the fonts directly. Each font registers
        // exactly once; later misses on the same name are harmless.
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
            // Each entry corresponds to one of the URLs that failed.
            // Most "errors" here are `kCTFontManagerErrorAlreadyRegistered`
            // (code 105) which we can safely ignore — that's idempotent
            // behaviour, not a real failure.
            for err in errArray {
                let code = CFErrorGetCode(err)
                if code == 105 { continue }
                log.error("PrimaeFonts: register failed code=\(code) desc=\(CFErrorCopyDescription(err) as String? ?? "?")")
            }
        }
    }
}
