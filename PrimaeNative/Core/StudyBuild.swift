// StudyBuild.swift
// PrimaeNative
//
// The one place that knows whether this binary is a study build.
//
// `STUDY_BUILD` is unconditional in `Package.swift` (2026-09-14) — every
// build of this package IS a study build, full stop; there is no
// non-study configuration of this SwiftPM target anymore. This was NOT
// always true: a project-level `SWIFT_ACTIVE_COMPILATION_CONDITIONS`
// used to reach the app target but never this package target (measured,
// spike ed055db — app=ON / package=OFF), so the flag could only arrive
// via an xcodebuild command-line override (`scripts/build_study.sh`),
// and pressing ⌘R in Xcode would compile the app half in and leave the
// package half out — a binary that looked like a study build and was
// not. That specific trap is gone with the mechanism that caused it,
// which is also why the casual (non-study) app configuration no longer
// exists as a scheme: see CLAUDE.md "STUDY_BUILD made unconditional."
//
// The build-identity symbols below are unrelated to any of that history
// and remain load-bearing on their own terms: they prove which of the
// two app-target configurations (Debug/Release-Study) produced a given
// binary, independent of how STUDY_BUILD itself reached the package.
//
// Exactly one of `primae_build_identity_study` /
// `primae_build_identity_normal` is compiled, and EVERY app build
// configuration names its own with `-u`. That makes the symbol a link
// ROOT: it is present because the link would otherwise have failed,
// not because something in the app happens to reference it. Two
// consequences worth stating, because the first attempt at this got
// both wrong:
//
//   1. The identity cannot be refactored away. Deleting the symbol, or
//      compiling the package's other half, breaks the build — in Xcode
//      and on CI, in BOTH directions. A string literal read only by a
//      view body carries no such guarantee; it attests to nothing the
//      linker had to agree with.
//   2. The check is `nm`, not `strings`. Symbol presence is a fact the
//      linker enforced; a literal's presence is an artefact of how the
//      compiler happened to emit and the linker happened to keep it.

import Foundation

public enum StudyBuild {
    /// Whether the non-study surfaces were compiled out of this binary.
    public static var isActive: Bool {
        #if STUDY_BUILD
        return true
        #else
        return false
        #endif
    }

    /// Human-readable build identity, for display only (the parent-area
    /// banner reads it).
    ///
    /// Do NOT attest to a binary's identity with this. It is a Swift
    /// string literal whose presence depends on emission and linking
    /// details rather than on anything the linker was required to
    /// enforce — a scan for it reported a study binary as "not a study
    /// build" while the link-time guard simultaneously proved the flag
    /// had arrived. The build-identity symbols at the bottom of this
    /// file are the attestable form.
    public static var marker: String {
        #if STUDY_BUILD
        return "PRIMAE_BUILD_STUDY"
        #else
        return "PRIMAE_BUILD_NORMAL"
        #endif
    }

    /// Default for `studyMode` when the device has no stored value.
    ///
    /// ON in a study build (B2): in a binary where the non-study
    /// surfaces do not exist there is no reason for it to be off, and
    /// a proctor who forgets the toggle would otherwise run an
    /// unconstrained session that looks fine. Since 2026-09-04 (ruling
    /// Q1) a study build does not merely DEFAULT to study mode — it
    /// cannot leave it: see `resolveStudyMode`.
    public static var studyModeDefault: Bool { isActive }

    /// UserDefaults key holding the device's stored `studyMode`. One
    /// declaration so the resolver, the proctor toggle, and the tests
    /// cannot drift apart on the string.
    public static let studyModeDefaultsKey = "de.flamingistan.primae.studyMode"

    /// Resolves the effective `studyMode` for a device.
    ///
    /// STUDY BUILD: always `true`, whatever is stored (supervisor ruling
    /// Q1, 2026-09-04). The point of compiling the non-study surfaces out
    /// is that the study binary cannot be configured into a non-study
    /// state — the binary either is the instrument or it is not. A
    /// stored OFF (from an earlier normal build on the same device, or a
    /// proctor's tap) is ignored, and the toggle that wrote it is
    /// compiled out of the research dashboard.
    ///
    /// NORMAL BUILD: a stored value wins, otherwise the build default
    /// (OFF) applies — device prep for a casual install is unchanged.
    ///
    /// Split out of `TracingDependencies`' default argument so it can
    /// be tested against a scratch `UserDefaults` — building a real
    /// `TracingDependencies` would construct a live `AudioEngine`,
    /// which is what the headless-simulator TestApp bypass exists to
    /// avoid (see docs/LESSONS.md).
    public static func resolveStudyMode(
        in defaults: UserDefaults = .standard,
        key: String = StudyBuild.studyModeDefaultsKey
    ) -> Bool {
        #if STUDY_BUILD
        return true
        #else
        guard defaults.object(forKey: key) != nil else { return studyModeDefault }
        return defaults.bool(forKey: key)
        #endif
    }
}

// MARK: - Build identity (link-enforced)

// `@_cdecl` gives these stable, unmangled symbol names for `-u` to
// reference. Neither is ever called; both exist to be found by the
// linker and then by `nm`. See the file header for why identity is
// carried as a symbol rather than as a string.
//
// Symmetry is the point. Naming only the study half would let a normal
// binary assert nothing about itself, which is exactly the hole that
// let a study binary fail its own identity check while the normal one
// passed.

#if STUDY_BUILD
@_cdecl("primae_build_identity_study")
public func primaeBuildIdentityStudy() {}
#else
@_cdecl("primae_build_identity_normal")
public func primaeBuildIdentityNormal() {}
#endif
