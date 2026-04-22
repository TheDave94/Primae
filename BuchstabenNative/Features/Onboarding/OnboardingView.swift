// OnboardingView.swift
// BuchstabenNative
//
// First-run flow. One step per learning phase (observe → direct →
// guided → freeWrite) plus a welcome and a reward intro, so the
// onboarding mirrors the four-phase model the child will see in the
// app rather than skipping the middle phases.

import SwiftUI

// MARK: - Main container

struct OnboardingView: View {
    @Environment(TracingViewModel.self) private var vm

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.93, green: 0.95, blue: 1.0),
                         Color(red: 0.98, green: 0.94, blue: 0.96)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                OnboardingProgressBar(progress: vm.onboardingProgress)
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
                    .accessibilityLabel("Einführung")
                    .accessibilityValue("\(Int((vm.onboardingProgress * 100).rounded())) Prozent")

                Spacer()

                stepContent

                Spacer()

                Text("Für Eltern: gedrückt halten zum Überspringen")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 24)
                    .contentShape(Rectangle())
                    .onLongPressGesture(minimumDuration: 1.5) { vm.skipOnboarding() }
                    .accessibilityLabel("Einführung überspringen")
                    .accessibilityHint("Gedrückt halten, nur für Erwachsene")
            }
        }
        .preferredColorScheme(.light)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch vm.onboardingStep {
        case .welcome:
            WelcomeStepView(onNext: { vm.advanceOnboarding() })
        case .traceDemo:
            TraceDemoStepView(onNext: { vm.advanceOnboarding() })
        case .directDemo:
            DirectDemoStepView(onNext: { vm.advanceOnboarding() })
        case .guidedDemo:
            GuidedDemoStepView(onNext: { vm.advanceOnboarding() })
        case .freeWriteDemo:
            FreeWriteDemoStepView(onNext: { vm.advanceOnboarding() })
        case .rewardIntro:
            RewardIntroStepView(onNext: { vm.advanceOnboarding() })
        case .complete:
            EmptyView()
        }
    }
}

// MARK: - Progress bar

private struct OnboardingProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.black.opacity(0.08))
                    .frame(height: 6)
                Capsule()
                    .fill(Color.blue)
                    .frame(width: geo.size.width * max(0, min(1, progress)), height: 6)
                    .animation(.easeInOut(duration: 0.3), value: progress)
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

// MARK: - Shared A-letter stroke geometry
//
// All four phase demos draw the same three strokes of an "A" in a
// 1x1 unit box so the child sees a consistent glyph across the
// onboarding and can focus on what each phase adds on top of it.

private struct ADemoStroke {
    let from: CGPoint
    let to: CGPoint
}

private let aDemoStrokes: [ADemoStroke] = [
    ADemoStroke(from: CGPoint(x: 0.50, y: 0.00), to: CGPoint(x: 0.05, y: 1.00)),  // left leg
    ADemoStroke(from: CGPoint(x: 0.50, y: 0.00), to: CGPoint(x: 0.95, y: 1.00)),  // right leg
    ADemoStroke(from: CGPoint(x: 0.22, y: 0.62), to: CGPoint(x: 0.78, y: 0.62))   // crossbar
]

private func scaled(_ pt: CGPoint, in size: CGSize) -> CGPoint {
    // Pad inside the Canvas so dots drawn at the stroke endpoints (which sit
    // at glyph-relative 0 / 1) don't get clipped by the Canvas frame — the
    // largest dot is ~14pt radius in the direct demo.
    let pad: CGFloat = 16
    return CGPoint(
        x: pad + pt.x * (size.width  - 2 * pad),
        y: pad + pt.y * (size.height - 2 * pad)
    )
}

// MARK: - Step 1: Welcome

private struct WelcomeStepView: View {
    let onNext: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Text("✏️")
                .font(.system(size: 80))

            Text("Willkommen!")
                .font(.largeTitle.bold())
                .foregroundStyle(.primary)

            Text("Lerne Buchstaben zu schreiben")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button(action: onNext) {
                Text("Los geht's!")
                    .font(.headline)
                    .frame(maxWidth: 240)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(32)
    }
}

// MARK: - Step 2: Anschauen (observe)

private struct TraceDemoStepView: View {
    let onNext: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Text("👁️")
                .font(.system(size: 64))

            Text("Anschauen")
                .font(.title.bold())
                .foregroundStyle(.primary)

            Text("Schau, wie der Buchstabe\ngeschrieben wird!")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            TimelineView(.animation) { timeline in
                let elapsed = timeline.date.timeIntervalSinceReferenceDate
                let cycle = 3.0
                let progress = CGFloat((elapsed.truncatingRemainder(dividingBy: cycle)) / cycle)

                ZStack {
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color.white.opacity(0.6))
                        .frame(width: 200, height: 200)

                    Text("A")
                        .font(.system(size: 100, weight: .bold, design: .rounded))
                        .foregroundStyle(.gray.opacity(0.15))

                    ObserveDemoLayer(progress: progress)
                        .frame(width: 160, height: 160)
                }
            }

            Button("Weiter", action: onNext)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(32)
    }
}

private struct ObserveDemoLayer: View {
    let progress: CGFloat

    var body: some View {
        Canvas { context, size in
            for stroke in aDemoStrokes {
                var p = Path()
                p.move(to: scaled(stroke.from, in: size))
                p.addLine(to: scaled(stroke.to, in: size))
                context.stroke(p, with: .color(.gray.opacity(0.15)), lineWidth: 4)
            }

            let seg = progress * CGFloat(aDemoStrokes.count)
            for (idx, stroke) in aDemoStrokes.enumerated() {
                let t = max(0, min(1, seg - CGFloat(idx)))
                guard t > 0 else { continue }
                var p = Path()
                p.move(to: scaled(stroke.from, in: size))
                p.addLine(to: scaled(stroke.to, in: size))
                context.stroke(p.trimmedPath(from: 0, to: t),
                               with: .color(.blue),
                               style: StrokeStyle(lineWidth: 5, lineCap: .round))
            }

            let currentIdx = min(Int(seg), aDemoStrokes.count - 1)
            let stroke = aDemoStrokes[currentIdx]
            let t = max(0, min(1, seg - CGFloat(currentIdx)))
            let pt = CGPoint(
                x: (stroke.from.x + (stroke.to.x - stroke.from.x) * t) * size.width,
                y: (stroke.from.y + (stroke.to.y - stroke.from.y) * t) * size.height
            )
            let r: CGFloat = 7
            context.fill(
                Circle().path(in: CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)),
                with: .color(.orange))
        }
    }
}

// MARK: - Step 3: Richtung lernen (direct)

private struct DirectDemoStepView: View {
    let onNext: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Text("☝️")
                .font(.system(size: 64))

            Text("Richtung lernen")
                .font(.title.bold())
                .foregroundStyle(.primary)

            Text("Tippe die Punkte\nder Reihe nach an!")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            TimelineView(.animation) { timeline in
                let elapsed = timeline.date.timeIntervalSinceReferenceDate
                let cycle = 4.5
                let progress = CGFloat((elapsed.truncatingRemainder(dividingBy: cycle)) / cycle)

                ZStack {
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color.white.opacity(0.6))
                        .frame(width: 200, height: 200)

                    Text("A")
                        .font(.system(size: 100, weight: .bold, design: .rounded))
                        .foregroundStyle(.gray.opacity(0.15))

                    DirectDemoLayer(progress: progress)
                        .frame(width: 160, height: 160)
                }
            }

            Button("Weiter", action: onNext)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(32)
    }
}

/// Cycles through each stroke: pulse the numbered dot, simulate a tap,
/// then draw an orange arrow along the stroke. Mirrors the real direct
/// phase's pulse → tap → arrow feedback loop.
private struct DirectDemoLayer: View {
    let progress: CGFloat

    var body: some View {
        Canvas { context, size in
            for stroke in aDemoStrokes {
                var p = Path()
                p.move(to: scaled(stroke.from, in: size))
                p.addLine(to: scaled(stroke.to, in: size))
                context.stroke(p, with: .color(.gray.opacity(0.15)), lineWidth: 4)
            }

            let seg = progress * CGFloat(aDemoStrokes.count)
            let currentIdx = min(Int(seg), aDemoStrokes.count - 1)
            let sub = seg - CGFloat(currentIdx)

            // Per-stroke sub-phase thresholds. Pulse for the first ~third,
            // "tap" press-down in the middle, then draw the arrow.
            let pulseEnd: CGFloat = 0.35
            let tapEnd: CGFloat = 0.5

            for (idx, stroke) in aDemoStrokes.enumerated() {
                let start = scaled(stroke.from, in: size)
                let end = scaled(stroke.to, in: size)

                if idx < currentIdx {
                    drawGreenDot(context: context, at: start, number: idx + 1)
                    drawArrow(context: context, from: start, to: end)
                } else if idx == currentIdx {
                    if sub < pulseEnd {
                        let pulse = 1.0 + 0.25 * sin(sub / pulseEnd * .pi * 3)
                        drawBlueDot(context: context, at: start, number: idx + 1, scale: pulse)
                    } else if sub < tapEnd {
                        let t = (sub - pulseEnd) / (tapEnd - pulseEnd)
                        let scale = 1.0 - 0.35 * t
                        drawBlueDot(context: context, at: start, number: idx + 1, scale: scale)
                    } else {
                        let t = (sub - tapEnd) / (1.0 - tapEnd)
                        drawGreenDot(context: context, at: start, number: idx + 1)
                        let tip = CGPoint(
                            x: start.x + (end.x - start.x) * t,
                            y: start.y + (end.y - start.y) * t
                        )
                        drawArrow(context: context, from: start, to: tip)
                    }
                } else {
                    drawGrayDot(context: context, at: start, number: idx + 1)
                }
            }
        }
    }

    private func drawNumbered(context: GraphicsContext, at pt: CGPoint, color: Color,
                              number: Int, scale: CGFloat = 1.0) {
        let r: CGFloat = 13 * scale
        context.fill(
            Circle().path(in: CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)),
            with: .color(color))
        let label = Text("\(number)")
            .font(.system(size: 13 * scale, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
        context.draw(label, at: pt, anchor: .center)
    }

    private func drawBlueDot(context: GraphicsContext, at pt: CGPoint,
                             number: Int, scale: CGFloat = 1.0) {
        drawNumbered(context: context, at: pt, color: .blue, number: number, scale: scale)
    }

    private func drawGreenDot(context: GraphicsContext, at pt: CGPoint, number: Int) {
        drawNumbered(context: context, at: pt, color: .green, number: number)
    }

    private func drawGrayDot(context: GraphicsContext, at pt: CGPoint, number: Int) {
        drawNumbered(context: context, at: pt, color: .gray.opacity(0.4), number: number)
    }

    private func drawArrow(context: GraphicsContext, from: CGPoint, to: CGPoint) {
        let dx = to.x - from.x, dy = to.y - from.y
        let length = sqrt(dx * dx + dy * dy)
        guard length > 3 else { return }
        var line = Path()
        line.move(to: from)
        line.addLine(to: to)
        context.stroke(line, with: .color(.orange),
                       style: StrokeStyle(lineWidth: 5, lineCap: .round))
        let angle = atan2(dy, dx)
        let tipLen: CGFloat = 11
        let spread: CGFloat = .pi / 5
        let b1 = CGPoint(x: to.x - tipLen * cos(angle - spread),
                         y: to.y - tipLen * sin(angle - spread))
        let b2 = CGPoint(x: to.x - tipLen * cos(angle + spread),
                         y: to.y - tipLen * sin(angle + spread))
        var head = Path()
        head.move(to: to); head.addLine(to: b1)
        head.move(to: to); head.addLine(to: b2)
        context.stroke(head, with: .color(.orange),
                       style: StrokeStyle(lineWidth: 5, lineCap: .round))
    }
}

// MARK: - Step 4: Nachspuren (guided)

private struct GuidedDemoStepView: View {
    let onNext: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Text("✏️")
                .font(.system(size: 64))

            Text("Nachspuren")
                .font(.title.bold())
                .foregroundStyle(.primary)

            Text("Fahre mit dem Finger\nüber die Linie!")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            TimelineView(.animation) { timeline in
                let elapsed = timeline.date.timeIntervalSinceReferenceDate
                let cycle = 4.5
                let progress = CGFloat((elapsed.truncatingRemainder(dividingBy: cycle)) / cycle)

                ZStack {
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color.white.opacity(0.6))
                        .frame(width: 200, height: 200)

                    Text("A")
                        .font(.system(size: 100, weight: .bold, design: .rounded))
                        .foregroundStyle(.gray.opacity(0.15))

                    GuidedDemoLayer(progress: progress)
                        .frame(width: 160, height: 160)
                }
            }

            Button("Weiter", action: onNext)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(32)
    }
}

/// Finger emoji follows each stroke in turn, leaving a green ink trail
/// behind it — the visual analog of the guided phase's checkpoint-rail
/// tracing experience.
private struct GuidedDemoLayer: View {
    let progress: CGFloat

    var body: some View {
        Canvas { context, size in
            for stroke in aDemoStrokes {
                var p = Path()
                p.move(to: scaled(stroke.from, in: size))
                p.addLine(to: scaled(stroke.to, in: size))
                context.stroke(p, with: .color(.gray.opacity(0.18)),
                               style: StrokeStyle(lineWidth: 8, lineCap: .round))
            }

            let seg = progress * CGFloat(aDemoStrokes.count)
            let currentIdx = min(Int(seg), aDemoStrokes.count - 1)
            let sub = seg - CGFloat(currentIdx)

            for idx in 0..<currentIdx {
                let stroke = aDemoStrokes[idx]
                var p = Path()
                p.move(to: scaled(stroke.from, in: size))
                p.addLine(to: scaled(stroke.to, in: size))
                context.stroke(p, with: .color(.green),
                               style: StrokeStyle(lineWidth: 6, lineCap: .round))
            }

            let stroke = aDemoStrokes[currentIdx]
            let start = scaled(stroke.from, in: size)
            let end = scaled(stroke.to, in: size)
            let fingerPt = CGPoint(
                x: start.x + (end.x - start.x) * sub,
                y: start.y + (end.y - start.y) * sub
            )
            var partial = Path()
            partial.move(to: start)
            partial.addLine(to: fingerPt)
            context.stroke(partial, with: .color(.green),
                           style: StrokeStyle(lineWidth: 6, lineCap: .round))

            let finger = Text("👆").font(.system(size: 34))
            context.draw(finger, at: CGPoint(x: fingerPt.x, y: fingerPt.y + 6),
                         anchor: .center)
        }
    }
}

// MARK: - Step 5: Selbst schreiben (freeWrite)

private struct FreeWriteDemoStepView: View {
    let onNext: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Text("🖊️")
                .font(.system(size: 64))

            Text("Selbst schreiben")
                .font(.title.bold())
                .foregroundStyle(.primary)

            Text("Zum Schluss schreibst du\nden Buchstaben alleine!")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            ZStack {
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color.white.opacity(0.6))
                    .frame(width: 200, height: 200)

                Text("A")
                    .font(.system(size: 100, weight: .bold, design: .rounded))
                    .foregroundStyle(.green.opacity(0.85))
            }

            Button("Weiter", action: onNext)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(32)
    }
}

// MARK: - Step 6: Reward Intro

private struct RewardIntroStepView: View {
    let onNext: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Text("⭐")
                .font(.system(size: 64))

            Text("Sammle Sterne!")
                .font(.title.bold())
                .foregroundStyle(.primary)

            Text("Für jeden Buchstaben bekommst du\nbis zu 4 Sterne!")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                ForEach(LearningPhase.allCases, id: \.self) { phase in
                    VStack(spacing: 6) {
                        Text(phase.icon)
                            .font(.title)
                        Text(phase.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 8)

            Button("Fertig!", action: onNext)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(32)
    }
}
