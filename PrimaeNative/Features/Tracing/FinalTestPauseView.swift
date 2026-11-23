// FinalTestPauseView.swift
// PrimaeNative
//
// The silent pause between the last training letter and the final test
// (protocol r27, David 2026-11-23): a full-screen field of bubbles that float
// up; touching one pops it. No sound, no letters, no text, no score and no
// count - a pop is a small animation and nothing else, so the screen is
// identical in every arm and for every performance (the same rule as the
// session end screen). It lasts `pauseSeconds` (a researcher setting), and the
// view model ends it by itself; this view only draws.
//
// A bubble is a pure function of (index, time since it was born), like the
// end screen's confetti, so a frame is a value and the layout is the same on
// every device. Hit-testing therefore follows the position that is drawn.

import SwiftUI

/// Deterministic bubbles: bubble `i` at age `t` seconds.
nonisolated enum PauseBubbles {

    /// New bubbles per second while the pause runs.
    static let spawnPerSecond: Double = 1.4
    /// Bubbles alive at once, at most (older ones have floated off).
    static let maxAlive = 14
    /// How long a popped bubble takes to disappear.
    static let popSeconds: Double = 0.28

    nonisolated struct Bubble: Equatable {
        /// 0...1 across the width (the bubble's centre).
        let x: Double
        /// 0...1 down the height; 1 is the bottom edge, below 0 is off the top.
        let y: Double
        /// Diameter in points.
        let diameter: Double
        let colourIndex: Int
    }

    /// A tiny fixed-seed generator (SplitMix64): the layout never changes.
    private static func unit(_ i: Int, _ salt: UInt64) -> Double {
        var z = UInt64(i + 1) &* 0x9E37_79B9_7F4A_7C15 &+ salt &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z % 10_000) / 10_000
    }

    /// Seconds bubble `i` takes to rise from below the bottom edge to above
    /// the top: slow enough for a 5-year-old's finger.
    static func riseSeconds(_ i: Int) -> Double { 7 + unit(i, 11) * 4 }

    /// The bubble's position at age `t`, or nil before it is born / after it
    /// has left the screen.
    static func bubble(_ i: Int, age t: Double) -> Bubble? {
        let rise = riseSeconds(i)
        guard t >= 0, t <= rise else { return nil }
        let local = t / rise
        let x0 = 0.08 + unit(i, 3) * 0.84
        let sway = sin(local * .pi * 2 * (1 + unit(i, 4))) * 0.025
        let diameter = 92 + unit(i, 5) * 84
        // From just below the bottom edge to just above the top.
        return Bubble(x: x0 + sway,
                      y: 1.12 - local * 1.28,
                      diameter: diameter,
                      colourIndex: Int(unit(i, 7) * 4) % 4)
    }

    /// When bubble `i` is born, seconds after the pause began.
    static func birth(_ i: Int) -> Double { Double(i) / spawnPerSecond }
}

struct FinalTestPauseView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var started = Date()
    /// Indices of popped bubbles, with the moment they were popped.
    @State private var popped: [Int: Date] = [:]

    private let palette: [Color] = [.brand, .info, .success, .star]

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.schuleSoft, Color.paper],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                GeometryReader { geo in
                    let now = context.date.timeIntervalSince(started)
                    ZStack {
                        ForEach(aliveIndices(at: now, date: context.date), id: \.self) { i in
                            bubbleView(i, now: now, size: geo.size, date: context.date)
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pause")
        .accessibilityIdentifier("finalTestPause")
    }

    /// The bubbles on screen now: the latest `maxAlive` that are born and not
    /// yet gone (a popped bubble stays for its pop animation).
    private func aliveIndices(at now: Double, date: Date) -> [Int] {
        let newest = Int(now * PauseBubbles.spawnPerSecond)
        let oldest = max(0, newest - PauseBubbles.maxAlive)
        return (oldest...max(oldest, newest)).filter { i in
            guard PauseBubbles.bubble(i, age: now - PauseBubbles.birth(i)) != nil else { return false }
            if let at = popped[i] { return date.timeIntervalSince(at) < PauseBubbles.popSeconds }
            return true
        }
    }

    @ViewBuilder
    private func bubbleView(_ i: Int, now: Double, size: CGSize, date: Date) -> some View {
        if let b = PauseBubbles.bubble(i, age: now - PauseBubbles.birth(i)) {
            let popAge = popped[i].map { date.timeIntervalSince($0) }
            let popProgress = popAge.map { min(1, $0 / PauseBubbles.popSeconds) } ?? 0
            let scale = reduceMotion ? 1 : 1 + 0.45 * popProgress
            let opacity = 1 - popProgress
            Circle()
                .fill(palette[b.colourIndex].opacity(0.22))
                .overlay(Circle().stroke(palette[b.colourIndex].opacity(0.55), lineWidth: 3))
                .overlay(alignment: .topLeading) {
                    Circle()
                        .fill(Color.white.opacity(0.55))
                        .frame(width: b.diameter * 0.18, height: b.diameter * 0.18)
                        .offset(x: b.diameter * 0.2, y: b.diameter * 0.18)
                }
                .frame(width: b.diameter, height: b.diameter)
                .scaleEffect(scale)
                .opacity(opacity)
                .position(x: b.x * size.width, y: b.y * size.height)
                .onTapGesture {
                    if popped[i] == nil { popped[i] = Date() }
                }
                .accessibilityHidden(true)
        }
    }
}
