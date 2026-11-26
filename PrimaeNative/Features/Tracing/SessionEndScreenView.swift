// SessionEndScreenView.swift
// PrimaeNative
//
// The study's end-of-session screen (David, 2026-11-04): shown once, full
// screen, after the child has finished all letters of the set and, from
// protocol r27, the final test that follows them. Icons and
// animation only - nothing to read - and NO sound (a sound would be a new
// stimulus that could differ between arms). It carries no score, no star
// count and no per-letter difference, so it is identical in every arm and
// for every performance; that is what separates it from the reward-class
// UI the study build compiles out (C1/C2).
//
// MOTION. About 4.5 s of calm celebration (letters pop in one after the
// other, a star swells behind them, soft confetti drifts down), then a
// still resting state. With Reduce Motion on, the resting state is shown
// at once with a plain fade. The confetti is a pure function of time
// (`SessionEndConfetti`), so it is deterministic and costs nothing once
// the animation window has passed.
//
// The proctor's way on is unchanged and lives outside this view: a
// double-tap on the rail, "Naechstes Kind".

import SwiftUI

/// Deterministic confetti: particle `i` at time `t`. No randomness at draw
/// time, so a frame is a value of (i, t) and the resting state is exact.
nonisolated enum SessionEndConfetti {
    static let count = 46
    /// The main animation window, seconds. After this nothing moves.
    static let duration: Double = 4.5

    nonisolated struct Particle: Equatable {
        let x: Double        // 0...1 across the width
        let y: Double        // 0...1 down the height (may be above 0 early on)
        let size: Double     // points
        let spin: Double     // radians
        let colourIndex: Int
        let opacity: Double
    }

    /// A tiny fixed-seed generator (SplitMix64) so the layout never changes.
    private static func unit(_ i: Int, _ salt: UInt64) -> Double {
        var z = UInt64(i + 1) &* 0x9E37_79B9_7F4A_7C15 &+ salt &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z % 10_000) / 10_000
    }

    static func particle(_ i: Int, at t: Double) -> Particle? {
        guard t >= 0, t < duration else { return nil }
        let delay = unit(i, 1) * 1.6
        let fall = 2.6 + unit(i, 2) * 1.2
        let local = (t - delay) / fall
        guard local >= 0, local <= 1 else { return nil }
        let x0 = unit(i, 3)
        let sway = sin(local * .pi * 2 * (1 + unit(i, 4))) * 0.03
        // Fade in quickly, fade out over the last third so nothing pops.
        let fadeIn = min(1, local * 8)
        let fadeOut = local > 0.66 ? max(0, (1 - local) / 0.34) : 1
        return Particle(x: x0 + sway,
                        y: -0.05 + local * 1.1,
                        size: 9 + unit(i, 5) * 9,
                        spin: local * .pi * (2 + unit(i, 6) * 4),
                        colourIndex: Int(unit(i, 7) * 5) % 5,
                        opacity: fadeIn * fadeOut)
    }
}

/// The end screen's composition size and how far it must shrink to fit a
/// scene (defence in depth, docs/DECISIONS.md "Rotation and
/// UIRequiresFullScreen": an iPadOS that ignores the deprecated key could
/// give the scene less than a full landscape screen). A value, so the decision is
/// testable without rendering.
nonisolated enum SessionEndLayout {
    static let cardSide: CGFloat = 168
    static let cardSpacing: CGFloat = 36
    static let starHeight: CGFloat = 250
    static let stackSpacing: CGFloat = 56
    /// Kept free around the composition on every side.
    static let margin: CGFloat = 32

    static func naturalSize(letterCount: Int) -> CGSize {
        let n = CGFloat(max(letterCount, 1))
        // The rays image (250 pt) is the widest piece when there is one card.
        let cards = n * cardSide + (n - 1) * cardSpacing
        return CGSize(width: max(cards, starHeight), height: starHeight + stackSpacing + cardSide)
    }

    /// 1 when the composition fits with its margin; otherwise the largest
    /// uniform scale that fits. Never above 1, never zero.
    static func fitScale(letterCount: Int, available: CGSize) -> CGFloat {
        let natural = naturalSize(letterCount: letterCount)
        let w = available.width - 2 * margin
        let h = available.height - 2 * margin
        guard w > 0, h > 0 else { return 0.1 }
        return max(0.1, min(1, w / natural.width, h / natural.height))
    }
}

struct SessionEndScreenView: View {
    /// The child's letters, in the study order. Shown identically for all.
    let letters: [String]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var started: Date?
    @State private var confettiActive = false
    @State private var revealedLetters = 0
    @State private var starScale: CGFloat = 0.2
    @State private var starRotation: Double = -18
    @State private var raysOpacity: Double = 0
    @State private var backgroundOpacity: Double = 0
    @State private var restOpacity: Double = 0

    /// Seconds the child keeps looking at the letter just written (and the
    /// spoken "Super gemacht!" finishes) before the screen takes over.
    static let lead: Double = 1.2

    private let palette: [Color] = [.star, .brand, .success, .info, .danger]

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.schuleSoft, Color.paper],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .opacity(backgroundOpacity)

            if !reduceMotion, confettiActive, let started {
                confetti(since: started)
            }

            GeometryReader { geo in
                VStack(spacing: 56) {
                    bigStar
                    HStack(spacing: 36) {
                        ForEach(Array(letters.enumerated()), id: \.offset) { index, letter in
                            letterCard(letter, shown: index < revealedLetters)
                        }
                    }
                }
                // Fixed point sizes, scaled down as a whole when the scene
                // is smaller than the composition (iOS 27 resizing):
                // nothing is cropped, nothing is rearranged.
                .scaleEffect(SessionEndLayout.fitScale(letterCount: letters.count,
                                                       available: geo.size))
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .opacity(reduceMotion ? restOpacity : 1)
        }
        // Covers the canvas and the chevrons completely; the rail lives
        // outside this view and stays reachable.
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Geschafft! Alle Buchstaben sind fertig.")
        .accessibilityIdentifier("sessionEndScreen")
        .onAppear(perform: play)
    }

    // MARK: - Pieces

    private var bigStar: some View {
        ZStack {
            Image(systemName: "sun.max.fill")
                .font(.system(size: 250))
                .foregroundStyle(Color.star.opacity(0.28))
                .opacity(raysOpacity)
                .scaleEffect(starScale * 1.08)
            Image(systemName: "star.fill")
                .font(.system(size: 190))
                .foregroundStyle(Color.star)
                .shadow(color: Color.ink.opacity(0.14), radius: 14, y: 6)
                .rotationEffect(.degrees(starRotation))
                .scaleEffect(starScale)
        }
        .accessibilityHidden(true)
    }

    private func letterCard(_ letter: String, shown: Bool) -> some View {
        ZStack(alignment: .topTrailing) {
            Text(letter)
                .font(.display(FontSize.xxxxl, weight: .bold))
                .foregroundStyle(Color.ink)
                .frame(width: 168, height: 168)
                .background(Color.paper, in: RoundedRectangle(cornerRadius: Radii.xl, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radii.xl, style: .continuous)
                    .stroke(Color.paperEdge, lineWidth: 1))
                .shadow(color: Color.ink.opacity(0.10), radius: 10, y: 4)
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(Color.success, Color.paper)
                .offset(x: 12, y: -12)
        }
        .scaleEffect(shown ? 1 : 0.2)
        .opacity(shown ? 1 : 0)
        .accessibilityHidden(true)
    }

    private func confetti(since start: Date) -> some View {
        // Removed from the tree once the window has passed (`play`): no
        // timeline and no draw calls at rest.
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            Canvas { gc, size in
                let t = context.date.timeIntervalSince(start)
                for i in 0..<SessionEndConfetti.count {
                    guard let p = SessionEndConfetti.particle(i, at: t) else { continue }
                    var layer = gc
                    layer.opacity = p.opacity
                    layer.translateBy(x: p.x * size.width, y: p.y * size.height)
                    layer.rotate(by: .radians(p.spin))
                    let rect = CGRect(x: -p.size / 2, y: -p.size / 2, width: p.size, height: p.size * 0.6)
                    layer.fill(Path(roundedRect: rect, cornerRadius: 2),
                               with: .color(palette[p.colourIndex]))
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - Choreography

    private func play() {
        if reduceMotion {
            // Resting state at once; a plain fade is the only motion.
            revealedLetters = letters.count
            starScale = 1
            starRotation = 0
            raysOpacity = 1
            withAnimation(.easeIn(duration: 0.3).delay(Self.lead)) {
                backgroundOpacity = 1
                restOpacity = 1
            }
            return
        }
        Task {
            try? await Task.sleep(for: .seconds(Self.lead))
            started = Date()
            confettiActive = true
            try? await Task.sleep(for: .seconds(SessionEndConfetti.duration + 0.3))
            confettiActive = false
        }
        let lead = Self.lead
        withAnimation(.easeOut(duration: 0.5).delay(lead)) { backgroundOpacity = 1 }
        withAnimation(.spring(response: 0.9, dampingFraction: 0.55).delay(lead + 0.2)) {
            starScale = 1
            starRotation = 0
        }
        withAnimation(.easeInOut(duration: 1.2).delay(lead + 0.4)) { raysOpacity = 1 }
        for index in 0..<letters.count {
            let delay = lead + 1.0 + Double(index) * 0.7
            withAnimation(.spring(response: 0.6, dampingFraction: 0.6).delay(delay)) {
                revealedLetters = max(revealedLetters, index + 1)
            }
        }
    }
}
