// TestWindow.swift
// PrimaeNativeTests: SDK27 (2026-11-24)
//
// `UIWindow(frame:)` is deprecated since iOS 26 ("Use init(windowScene:)").
// The test bundle is hosted in the app, so the app's window scene is there to
// attach to; the window is then sized as the frame initialiser sized it.

import UIKit

@MainActor
enum TestWindow {
    static func make(_ frame: CGRect) -> UIWindow {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        precondition(scene != nil, "hosted tests need the app's window scene")
        let window = UIWindow(windowScene: scene!)
        window.frame = frame
        return window
    }
}
