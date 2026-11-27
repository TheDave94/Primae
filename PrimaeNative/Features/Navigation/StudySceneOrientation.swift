// StudySceneOrientation.swift
// PrimaeNative
//
// Landscape at runtime, without UIRequiresFullScreen (protocol r30, David's
// ruling 2026-11-26, "Real fix + turn prompt"; docs/DECISIONS.md "Landscape
// without UIRequiresFullScreen: runtime lock and turn prompt").
//
// The key is deprecated (Apple TN3192) and every Xcode 27 build warned about
// it. The study build now declares every iPad orientation, as iOS 27 asks,
// and keeps the session landscape itself:
//
// 1. A landscape scene LOCKS its orientation (`prefersInterfaceOrientationLocked`,
//    iOS 26+): turning the iPad to portrait leaves the session landscape.
// 2. A portrait scene (an iPad held in portrait at launch: the system does
//    not honour a landscape geometry request there, measured on iPadOS 27.3)
//    or a scene that does not fill the screen (a window, when the iPad's
//    multitasking mode allows windows) is HELD: the session is suspended
//    like any other interruption and the child sees the turn prompt
//    (`TurnDevicePromptView`), icons and animation only. Turning the iPad to
//    landscape lifts the hold, and the lock (1) engages.
//
// The decisions are plain functions (`StudyOrientationGate`), unit-tested on
// their own; the UIKit side below only reads the scene and applies them.

import SwiftUI
import UIKit
import os
import ObjectiveC

/// What the scene's shape means for the session. Pure; no UIKit state.
enum StudyOrientationGate {

    /// Why the session is held, if it is.
    enum Hold: String, Equatable, Sendable {
        /// The scene is landscape and fills the screen: the session runs.
        case none
        /// The scene is portrait: the child is asked to turn the iPad.
        case turnToLandscape
        /// The scene is landscape but smaller than the screen (a window):
        /// the session waits until it fills the screen again.
        case fillScreen
    }

    /// The hold for a scene of this shape. Portrait wins over a window:
    /// turning the iPad is the one thing a child can do about it.
    nonisolated static func hold(sceneIsLandscape: Bool, sceneFillsScreen: Bool) -> Hold {
        if !sceneIsLandscape { return .turnToLandscape }
        if !sceneFillsScreen { return .fillScreen }
        return .none
    }

    /// Whether the scene should lock its orientation now. The lock keeps the
    /// CURRENT orientation, so it may only engage once the scene is
    /// landscape: engaging it on a portrait launch would lock the session in
    /// portrait.
    nonisolated static func locksOrientation(sceneIsLandscape: Bool) -> Bool {
        sceneIsLandscape
    }

    /// Whether a scene of `sceneSize` fills a screen of `screenSize`, in
    /// either orientation, within half a point (rounding of the geometry).
    nonisolated static func fills(sceneSize: CGSize, screenSize: CGSize) -> Bool {
        let scene = (max(sceneSize.width, sceneSize.height), min(sceneSize.width, sceneSize.height))
        let screen = (max(screenSize.width, screenSize.height), min(screenSize.width, screenSize.height))
        return abs(scene.0 - screen.0) < 0.5 && abs(scene.1 - screen.1) < 0.5
    }
}

/// The UIKit side: reads the window scene, installs the lock preference and
/// reports the scene's shape to the view model.
enum StudySceneOrientation {

    private static let log = Logger(subsystem: "de.flamingistan.primae", category: "SceneGeometry")

    /// The physical screen's size in points, independent of any virtual
    /// screen a windowed scene may be moved to (TN3192, discrete resizing).
    static func physicalScreenSize(of scene: UIWindowScene) -> CGSize {
        let screen = scene.screen
        let native = screen.nativeBounds.size
        let scale = screen.nativeScale
        guard scale > 0 else { return screen.bounds.size }
        return CGSize(width: native.width / scale, height: native.height / scale)
    }

    /// The scene's shape now.
    static func shape(of scene: UIWindowScene) -> (isLandscape: Bool, fillsScreen: Bool, size: CGSize) {
        let geometry = scene.effectiveGeometry
        let size = geometry.coordinateSpace.bounds.size
        let isLandscape = geometry.interfaceOrientation.isLandscape
        let fills = StudyOrientationGate.fills(sceneSize: size, screenSize: physicalScreenSize(of: scene))
        return (isLandscape, fills, size)
    }

    /// SwiftUI's hosting controller cannot be subclassed from an `App`, and
    /// SwiftUI offers no modifier for the lock. So the preference getter is
    /// ADDED to the root controller's own class (`class_addMethod` adds a
    /// method only when that class does not implement it itself; it never
    /// replaces SwiftUI's code), and the system is told to re-read it.
    @discardableResult
    static func installOrientationLockPreference(on root: UIViewController) -> Bool {
        let cls: AnyClass = type(of: root)
        let selector = #selector(getter: UIViewController.prefersInterfaceOrientationLocked)
        let getter: @convention(block) (AnyObject) -> Bool = { controller in
            // UIKit reads controller preferences on the main thread.
            MainActor.assumeIsolated {
                guard let controller = controller as? UIViewController,
                      let scene = controller.viewIfLoaded?.window?.windowScene else { return false }
                return StudyOrientationGate.locksOrientation(
                    sceneIsLandscape: scene.effectiveGeometry.interfaceOrientation.isLandscape)
            }
        }
        let added = class_addMethod(cls, selector, imp_implementationWithBlock(getter), "B@:")
        root.setNeedsUpdateOfPrefersInterfaceOrientationLocked()
        log.notice("orientation-lock preference on \(NSStringFromClass(cls), privacy: .public): added=\(added)")
        return added
    }

    /// The scene connected: install the lock and ask for landscape. The
    /// request is best effort (not honoured for a portrait-held launch on
    /// iPadOS 27.3); the turn prompt covers that case.
    static func connect(_ scene: UIWindowScene, root: UIViewController?) {
        if let root { installOrientationLockPreference(on: root) }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape)) { error in
            log.notice("landscape request declined: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func logShape(of scene: UIWindowScene, reason: String) {
        let s = shape(of: scene)
        let g = scene.effectiveGeometry
        let physical = physicalScreenSize(of: scene)
        log.notice("""
            scene \(reason, privacy: .public): \(Int(s.size.width))x\(Int(s.size.height)) pt \
            (screen \(Int(scene.screen.bounds.width))x\(Int(scene.screen.bounds.height)), \
            physical \(Int(physical.width))x\(Int(physical.height))), \
            orientation \(g.interfaceOrientation.rawValue), locked \(g.isInterfaceOrientationLocked), \
            fills \(s.fillsScreen)
            """)
    }
}

/// Attaches `StudySceneOrientation` to the scene the root view lives in: a
/// non-interactive UIView laid out BEHIND the root view, so every scene size
/// change (a rotation, a window resize) lays it out and it reports the
/// scene's new shape.
struct StudySceneOrientationAttacher: UIViewRepresentable {
    /// Called with the scene's shape whenever it may have changed.
    let onShape: @MainActor (_ isLandscape: Bool, _ fillsScreen: Bool) -> Void

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onShape = onShape
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {
        uiView.onShape = onShape
    }

    final class ProbeView: UIView {
        var onShape: (@MainActor (Bool, Bool) -> Void)?
        private var lastSize: CGSize = .zero
        private var lastOrientation: UIInterfaceOrientation = .unknown

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let scene = window?.windowScene else { return }
            StudySceneOrientation.connect(scene, root: window?.rootViewController)
            report(scene, reason: "connect", force: true)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let scene = window?.windowScene else { return }
            report(scene, reason: "layout", force: false)
        }

        private func report(_ scene: UIWindowScene, reason: String, force: Bool) {
            let size = scene.effectiveGeometry.coordinateSpace.bounds.size
            let orientation = scene.effectiveGeometry.interfaceOrientation
            guard force || size != lastSize || orientation != lastOrientation else { return }
            lastSize = size
            lastOrientation = orientation
            // The lock engages once the scene is landscape: have the system
            // re-read it whenever the shape may have changed.
            window?.rootViewController?.setNeedsUpdateOfPrefersInterfaceOrientationLocked()
            StudySceneOrientation.logShape(of: scene, reason: reason)
            let shape = StudySceneOrientation.shape(of: scene)
            onShape?(shape.isLandscape, shape.fillsScreen)
        }
    }
}
