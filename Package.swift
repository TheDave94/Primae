// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "PrimaeNative",
    platforms: [
        .iOS(.v26),
        .macOS(.v15)
    ],
    products: [
        .library(name: "PrimaeNative", targets: ["PrimaeNative"]),
    ],
    targets: [
        .target(
            name: "PrimaeNative",
            path: "PrimaeNative",
            // `Resources` stays `.copy`: it holds 87 identically-named
            // `strokes.json` files in per-letter directories, and
            // `.process` flattens toward the bundle root. Measured, not
            // assumed — SwiftPM rejects the manifest outright with
            // "multiple resources named 'strokes.json'".
            //
            // The CoreML model lives in its own root so it can carry
            // `.process`, which ships the COMPILED `.mlmodelc`. Under
            // `.copy` the model shipped as a raw `.mlpackage` directory
            // and every cold load called `MLModel.compileModel(at:)` at
            // runtime — behaviour Apple does not document as guaranteed,
            // in the one feature that already failed silently across 194
            // records (`cb7291d`).
            resources: [.copy("Resources"), .process("MLResources")],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("InferSendableFromCaptures"),
                // STUDY_BUILD unconditionally on (2026-09-14): the pilot is
                // the only thing this app runs now (CLAUDE.md, "the casual
                // path is paused"), so there is exactly one configuration
                // worth being able to build, and a flag that can only ever
                // be set one way is not a flag, it is dead weight that also
                // happens to be the reason Xcode's own Run button couldn't
                // build this target. `SWIFT_ACTIVE_COMPILATION_CONDITIONS`
                // set at the PROJECT level never reached this SwiftPM
                // package target (measured, spike ed055db); only an
                // xcodebuild COMMAND-LINE override did, which the Xcode UI
                // has no way to supply. Defining it here, in the manifest
                // itself, is unconditional for every consumer of this
                // package regardless of how it's invoked — Xcode UI
                // included. See CLAUDE.md "Study builds" for what this
                // takes with it (the casual Debug/Release configuration
                // can no longer link at all) and scripts/build_study.sh's
                // header for the mechanics.
                .define("STUDY_BUILD"),
            ]
        ),
        .testTarget(
            name: "PrimaeNativeTests",
            dependencies: ["PrimaeNative"],
            path: "PrimaeNativeTests",
            swiftSettings: [
                // XCTest subclasses with @MainActor members hit a Swift 6 limitation:
                // inherited nonisolated initialisers (init(invocation:) etc.) conflict
                // with the inferred @MainActor isolation. Minimal concurrency checking
                // in the test target avoids this without affecting production code.
                .swiftLanguageMode(.v5),
                // Must match the PrimaeNative target above: `#if STUDY_BUILD`
                // inside a test file is evaluated against THIS target's own
                // flags, not inherited from the module it imports. Without
                // this, a test referencing a symbol STUDY_BUILD compiles out
                // of PrimaeNative (see the SURFACES list in
                // .github/workflows/ios-build.yml) would fail to resolve it,
                // and a test with its own `#if STUDY_BUILD` branch would take
                // the wrong one relative to the production code it's testing.
                .define("STUDY_BUILD"),
            ]
        )
    ]
)
