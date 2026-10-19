// PrimaeBundle.swift
// PrimaeNative
//
// One resolver for the SwiftPM-generated resource bundle that carries
// this module's `Resources/` tree.
//
// WHY NOT `Bundle.module`. SwiftPM's generated accessor calls
// `fatalError` when it cannot resolve, which turns a missing resource
// into a launch crash in test hosts. `LetterRepository` documented that
// hazard and hand-rolled around it; so did `LetterRecognizer`,
// separately and differently. This is the shared, non-trapping version.
//
// WHY A PATH PROBE AND NOT `url(forResource:withExtension:)`.
// `.copy("Resources")` preserves the tree verbatim, so
// `GermanLetterRecognizer.mlpackage` ships as a DIRECTORY.
// `Bundle.url(forResource:withExtension:)` is unreliable for
// directory-shaped resources — which is why the recogniser reported
// "not found in any bundle" while the letter loader, which ENUMERATES
// `bundle.resourceURL` instead, resolved the same bundle fine. A direct
// path probe with an existence check does not care whether the resource
// is a file or a directory.

import Foundation

enum PrimaeBundle {

    /// `Bundle(for:)` returns whichever bundle contains the compiled
    /// module: `PrimaeNative.framework` in the app, and the same
    /// framework nested inside `PrimaeNativeTests.xctest` under test.
    /// The resource bundle sits inside it in both layouts.
    private final class Anchor {}

    nonisolated private static let resourceBundleName = "PrimaeNative_PrimaeNative"

    /// The resource bundle, or `.main` when it cannot be located.
    ///
    /// Note what is NOT here: `Bundle(identifier: "PrimaeNative_PrimaeNative")`.
    /// That argument is a CFBundleIdentifier, not a filename — the real
    /// identifier is `primae.PrimaeNative.resources`, so the probe was
    /// dead in both former call sites and had been since it was written.
    /// `nonisolated`: the package sets `-default-isolation MainActor`, so
    /// without it this static would be MainActor-isolated. `Bundle` IS
    /// `Sendable` in the iOS 27 SDK (`NSBundle` is `NS_SWIFT_SENDABLE`,
    /// NSBundle.h:100, in both the 27.0 and 27.2 SDKs), so no `unsafe` is
    /// needed; an earlier comment here claiming otherwise was stale.
    /// Written once by a pure lookup, then only read.
    nonisolated static let resources: Bundle = resolveResourceBundle()

    /// The resolution itself, as a `nonisolated` function. As a
    /// `= { … }()` initialiser the closure took the package's MainActor
    /// default and the compiler rejected a main-actor default value in a
    /// `nonisolated` context — measured at :44, not predicted.
    nonisolated private static func resolveResourceBundle() -> Bundle {
        var anchors: [Bundle] = [Bundle(for: Anchor.self), .main]
        anchors.append(contentsOf: Bundle.allFrameworks)
        anchors.append(contentsOf: Bundle.allBundles)

        for anchor in anchors {
            if anchor.bundleURL.lastPathComponent == resourceBundleName + ".bundle" {
                return anchor
            }
            let nested = anchor.bundleURL.appendingPathComponent(resourceBundleName + ".bundle")
            if FileManager.default.fileExists(atPath: nested.path),
               let bundle = Bundle(url: nested) {
                return bundle
            }
        }
        return .main
    }

    /// The directories `resourceURL` probes, in order: the package
    /// bundle, then `.main` last, and deliberately: the host embeds some
    /// resources directly (fonts via `INFOPLIST_KEY_UIAppFonts`), so a
    /// lookup that misses the package bundle can still legitimately
    /// succeed there. It is a probe INSIDE this resolver rather than a
    /// second resolver beside it — one path, watched by one test, so a
    /// resource that only resolves by accident cannot hide in a fallback
    /// nobody reads.
    ///
    /// The `roots:` parameter below defaults to this and exists for one
    /// reason: a test can hand the resolver a root list with the package
    /// bundle MISSING and see what a caller gets. That is the case
    /// `Bundle.module` traps on, and the only way to observe that a caller
    /// goes through these roots rather than around them.
    nonisolated static var searchRoots: [URL] {
        [resources.bundleURL, resources.resourceURL, Bundle.main.resourceURL].compactMap { $0 }
    }

    /// URL for a path relative to the resource bundle root, verified
    /// against the filesystem. Returns `nil` rather than a URL that does
    /// not exist, so callers can fall back rather than fail later.
    /// `nonisolated` on the MEMBER, not the enum. Marking the enum
    /// `nonisolated` does NOT make its static members callable from a
    /// nonisolated synchronous context — measured, not assumed: the
    /// isolation error at `LetterRecognizer.swift:257` survived it.
    /// `CoreMLLetterRecognizer` is itself `nonisolated` so the model load
    /// can run on a detached Task, and a filesystem probe has no business
    /// hopping to the main actor to satisfy a package-wide default.
    nonisolated static func resourceURL(_ relativePath: String,
                                        roots: [URL] = searchRoots) -> URL? {
        for root in roots {
            let candidate = root.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// First of several candidate layouts that exists.
    ///
    /// `.copy("Resources")` preserves the tree, `.process` flattens toward
    /// the bundle root, and an Xcode copy phase flattens differently again.
    /// Callers pass the layouts their resource can legitimately ship in,
    /// most-specific first, instead of each hand-rolling the same loop.
    nonisolated static func resourceURL(firstOf relativePaths: [String],
                                        roots: [URL] = searchRoots) -> URL? {
        for path in relativePaths {
            if let url = resourceURL(path, roots: roots) { return url }
        }
        return nil
    }

    // MARK: - Audio

    /// Bundle-relative audio filename → URL, or `nil` when it is not
    /// bundled. The one audio lookup: `AudioEngine.loadAudioFile` and
    /// `SpatialSonification.carrierToneURL()` (the spatial arm's start
    /// precondition, ruling C1-6) both call it, so "the engine can play
    /// it" and "the arm may start" cannot disagree about where a file is.
    ///
    /// WAS a hand-rolled `[Bundle.main, Bundle.module]` loop in each of
    /// those two files. `Bundle.module` calls `fatalError` when it cannot
    /// resolve the resource bundle, so a build that lost that bundle
    /// crashed at the first audio load instead of going quiet, the shape
    /// every other missing resource here already had. Every failure this
    /// function can produce is a `nil` return.
    nonisolated static func audioURL(for fileName: String,
                                     roots: [URL] = searchRoots) -> URL? {
        resourceURL(firstOf: audioLayouts(for: fileName), roots: roots)
    }

    /// The layouts an audio filename is probed under: the name as given,
    /// then its last path component at the bundle root. These are the
    /// files the replaced loop could reach — its resource-root path, its
    /// subdirectory-API lookup (the same file as the path, for an
    /// unlocalised bundle) and its flat fallback — so no lookup that
    /// resolved before resolves elsewhere now, and none gains a layout.
    /// The flat candidate is the whole last component, extension and
    /// all, so a name without an extension is probed as itself.
    nonisolated static func audioLayouts(for fileName: String) -> [String] {
        let flat = (fileName as NSString).lastPathComponent
        return flat == fileName ? [fileName] : [fileName, flat]
    }

    /// Bundle-relative layouts a resource under `Resources/<dir>/` can ship in.
    /// An empty `ext` is a file without an extension, laid out as `name`
    /// itself: interpolating it gave `name.`, a file that never exists, so
    /// an extensionless resource could not resolve in any layout.
    nonisolated static func layouts(dir: String, name: String, ext: String) -> [String] {
        let file = ext.isEmpty ? name : "\(name).\(ext)"
        return ["Resources/\(dir)/\(file)", "\(dir)/\(file)", file]
    }
}
