// TurnDevicePromptView.swift
// PrimaeNative
//
// The turn prompt (protocol r30; docs/DECISIONS.md "Landscape without
// UIRequiresFullScreen: runtime lock and turn prompt"). Shown over the whole
// screen while `TracingViewModel.orientationHold` is not `.none`: the scene is
// portrait (the iPad was held in portrait at launch) or does not fill the
// screen (a window). Icons and animation only, no text and no sound: the
// study's speech is a fixed recorded set, and a 5-6 year old does not read.
// It swallows every touch, so the letter under it cannot be traced, and it
// disappears as soon as the scene is landscape and full screen.

import SwiftUI

struct TurnDevicePromptView: View {
    let hold: StudyOrientationGate.Hold
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The accessibility identifier UI tests look for.
    static let accessibilityID = "turnDevicePrompt"

    var body: some View {
        ZStack {
            Color.paperDeep
            switch hold {
            case .turnToLandscape, .none:
                turnIcon
            case .fillScreen:
                fillScreenIcon
            }
        }
        .ignoresSafeArea()
        // Every touch lands here, never on the letter underneath.
        .contentShape(Rectangle())
        .onTapGesture {}
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier(Self.accessibilityID)
        .accessibilityValue(hold.rawValue)
        // For the proctor's VoiceOver only; nothing is shown as text.
        .accessibilityLabel(hold == .fillScreen ? "Vollbild" : "iPad quer drehen")
    }

    /// An iPad that turns from portrait to landscape, with a turning arrow.
    /// Reduce Motion: the end state, still.
    private var turnIcon: some View {
        HStack(spacing: 40) {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 90, weight: .semibold))
                .foregroundStyle(Color.brand)
            if reduceMotion {
                Image(systemName: "ipad.landscape")
                    .font(.system(size: 220, weight: .regular))
                    .foregroundStyle(Color.ink)
            } else {
                Image(systemName: "ipad")
                    .font(.system(size: 220, weight: .regular))
                    .foregroundStyle(Color.ink)
                    .phaseAnimator([0.0, -90.0, -90.0]) { icon, angle in
                        icon.rotationEffect(.degrees(angle))
                    } animation: { angle in
                        angle == -90 ? .easeInOut(duration: 1.2) : .easeInOut(duration: 0.6).delay(0.9)
                    }
            }
        }
    }

    /// The window should fill the screen: the expand arrows, pulsing.
    private var fillScreenIcon: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 200, weight: .semibold))
            .foregroundStyle(Color.ink)
            .phaseAnimator(reduceMotion ? [1.0] : [0.85, 1.1]) { icon, scale in
                icon.scaleEffect(scale)
            } animation: { _ in .easeInOut(duration: 0.9) }
    }
}
