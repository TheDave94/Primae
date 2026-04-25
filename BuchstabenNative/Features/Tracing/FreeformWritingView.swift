// FreeformWritingView.swift
// BuchstabenNative
//
// Blank-canvas writing mode. No reference letter outline, no checkpoints,
// no phases. The child writes whatever they want; once they lift the
// pen (letter sub-mode) or tap "Fertig" (word sub-mode) the CoreML
// recognizer reports what it saw.
//
// Keeps AudioEngine.swift untouched — freeform mode is deliberately
// silent so the recognition badge is the only feedback signal.

import SwiftUI
import UIKit

// MARK: - Surface palette
//
// Solid colours used for the freeform UI panels. Replaces the previous
// `.ultraThinMaterial` cards, which read as light gray over the white
// canvas and crushed the contrast of `.secondary` labels and tinted
// chips (see IMG_0337–0340 — "Schreibe einen Buchstaben…", the
// "Vorschläge:" row, and the Klarheit / Form pills were almost
// invisible). These tones give every label and chip a predictable
// background to sit on regardless of system colour scheme.
private enum FreeformSurface {
    /// Toolbar and prompt strip behind Zurück / mode picker / Nochmal.
    static let header   = Color(red: 0.94, green: 0.94, blue: 0.97)
    /// Result and status cards under the canvas.
    static let card     = Color(red: 0.97, green: 0.97, blue: 0.99)
    /// Hairline border around cards so they read as a unit on white.
    static let cardEdge = Color(red: 0.78, green: 0.78, blue: 0.84)
    /// Word-picker pill backgrounds for unselected items — strong
    /// enough that the dark label remains legible (purple.opacity(0.12)
    /// rendered as near-pink and dropped contrast below WCAG AA).
    static let pillIdle = Color(red: 0.91, green: 0.85, blue: 0.97)
    /// Dark text for the unselected word-picker pills. Hand-picked dark
    /// purple paired against `pillIdle` — measured ≈ 7:1 contrast.
    static let pillIdleText = Color(red: 0.30, green: 0.13, blue: 0.45)
    /// Body label for prompts that used to be `.secondary` — solid dark
    /// grey is legible on both the header and the canvas.
    static let prompt = Color(red: 0.20, green: 0.20, blue: 0.25)
}

struct FreeformWritingView: View {
    @Environment(TracingViewModel.self) private var vm

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.white
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    header
                    if vm.freeformSubMode == .word {
                        wordPickerStrip
                    }
                    freeformCanvas(size: geo.size)
                    footer
                }
            }
        }
        // Canvas is hard-coded `Color.white`, so pin the rest of the
        // view to light mode too — otherwise `.primary`/`.secondary`
        // resolve to white-ish in dark mode and disappear into the
        // canvas, exactly the white-on-white symptom in IMG_0337–0340.
        .preferredColorScheme(.light)
    }

    // MARK: - Header (two rows: nav + prompt)

    private var header: some View {
        VStack(spacing: 8) {
            // Row 1: Zurück / mode picker / Nochmal. Fixed layout so
            // buttons can never crash into each other (see IMG_0334).
            HStack(alignment: .center, spacing: 12) {
                Button {
                    vm.exitFreeformMode()
                } label: {
                    Label("Zurück", systemImage: "chevron.left")
                        .font(.headline)
                }
                .buttonStyle(.bordered)
                .tint(.gray)
                .accessibilityHint("Zurück zum geführten Modus")

                Spacer()

                Picker("Modus", selection: Binding(
                    get: { vm.freeformSubMode },
                    set: { newValue in
                        if newValue == .word, vm.freeformTargetWord == nil {
                            vm.selectFreeformWord(FreeformWordList.all.first ?? FreeformWord(word: "OMA", difficulty: 1))
                        } else {
                            vm.freeformSubMode = newValue
                            vm.clearFreeformCanvas()
                        }
                    }
                )) {
                    Text("Buchstabe").tag(FreeformSubMode.letter)
                    Text("Wort").tag(FreeformSubMode.word)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)

                Spacer()

                Button {
                    vm.clearFreeformCanvas()
                } label: {
                    Label("Nochmal", systemImage: "arrow.counterclockwise")
                        .font(.headline)
                }
                .buttonStyle(.bordered)
                .tint(.orange)
                .accessibilityHint("Leert das Blatt, damit du es nochmal versuchen kannst")
            }

            // Row 2: target prompt. Occupies its own horizontal band so
            // it never collides with the nav buttons above.
            HStack {
                Spacer()
                if vm.freeformSubMode == .word, let target = vm.freeformTargetWord {
                    HStack(spacing: 8) {
                        Text("Schreibe:")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(FreeformSurface.prompt)
                        Text(target.word)
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Zielwort \(target.word)")
                } else {
                    Text("Schreibe einen Buchstaben mit dem Finger oder dem Stift")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(FreeformSurface.prompt)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(FreeformSurface.header)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(FreeformSurface.cardEdge.opacity(0.5))
                .frame(height: 1)
        }
    }

    // MARK: - Word picker strip

    private var wordPickerStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(FreeformWordList.all, id: \.self) { word in
                    let isSelected = vm.freeformTargetWord == word
                    Button {
                        vm.selectFreeformWord(word)
                    } label: {
                        Text(word.word)
                            .font(.system(.headline, design: .rounded).weight(.semibold))
                            .foregroundStyle(isSelected
                                             ? Color.white
                                             : FreeformSurface.pillIdleText)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(
                                isSelected
                                    ? Color.purple
                                    : FreeformSurface.pillIdle,
                                in: Capsule()
                            )
                            .overlay(
                                Capsule()
                                    .stroke(isSelected
                                            ? Color.clear
                                            : FreeformSurface.pillIdleText.opacity(0.35),
                                            lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Zielwort \(word.word)")
                    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
    }

    // MARK: - Blank canvas

    @ViewBuilder
    private func freeformCanvas(size: CGSize) -> some View {
        let canvasSize = CGSize(width: size.width, height: size.height * 0.65)
        ZStack {
            Canvas { context, canvasDrawSize in
                drawSegmentationGuides(context: context, size: canvasDrawSize)
                drawCommittedPoints(context: context, size: canvasDrawSize)
                drawActivePath(context: context, size: canvasDrawSize)
            }
            .frame(width: canvasSize.width, height: canvasSize.height)
            .background(Color(white: 0.97))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.gray.opacity(0.2), lineWidth: 1)
            )
            .accessibilityLabel("Schreibfläche für freies Schreiben")
            .accessibilityHint("Ziehe mit einem Finger, um einen Buchstaben zu schreiben")
        }
        .overlay(
            FreeformTouchOverlay(
                canvasSize: canvasSize,
                onBegan: { p in vm.beginFreeformTouch(at: p) },
                onMoved: { p in vm.updateFreeformTouch(at: p, canvasSize: canvasSize) },
                onEnded: { vm.endFreeformTouch() }
            )
        )
        .frame(height: canvasSize.height)
    }

    private func drawCommittedPoints(context: GraphicsContext, size: CGSize) {
        // Reconstruct per-stroke polylines from freeformStrokeSizes so
        // pen lifts stay visible as gaps rather than being bridged with
        // a spurious line segment across the canvas.
        let all = vm.freeformPoints
        guard !all.isEmpty else { return }
        var cursor = 0
        for strokeLen in vm.freeformStrokeSizes {
            let endIdx = min(cursor + strokeLen, all.count)
            guard endIdx - cursor >= 2 else { cursor = endIdx; continue }
            var path = Path()
            path.addLines(Array(all[cursor..<endIdx]))
            context.stroke(path, with: .color(.black),
                           style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
            cursor = endIdx
        }
    }

    private func drawActivePath(context: GraphicsContext, size: CGSize) {
        let pts = vm.freeformActivePath
        guard pts.count >= 2 else { return }
        var path = Path()
        path.addLines(pts)
        context.stroke(path, with: .color(.green),
                       style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
    }

    private func drawSegmentationGuides(context: GraphicsContext, size: CGSize) {
        guard vm.freeformSubMode == .word,
              let target = vm.freeformTargetWord else { return }
        let letterCount = max(target.word.count, 1)
        let step = size.width / CGFloat(letterCount)
        for i in 1..<letterCount {
            let x = step * CGFloat(i)
            var line = Path()
            line.move(to: CGPoint(x: x, y: 8))
            line.addLine(to: CGPoint(x: x, y: size.height - 8))
            context.stroke(line, with: .color(.gray.opacity(0.25)),
                           style: StrokeStyle(lineWidth: 1, dash: [3, 6]))
        }
    }

    // MARK: - Footer (feedback + submit)

    @ViewBuilder
    private var footer: some View {
        VStack(spacing: 10) {
            if vm.freeformSubMode == .word {
                wordFooter
            } else {
                letterFooter
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 20)
    }

    @ViewBuilder
    private var letterFooter: some View {
        if vm.isRecognitionModelAvailable == false {
            statusBanner(
                icon: "exclamationmark.triangle.fill",
                tint: .red,
                title: "KI-Modell nicht verfügbar",
                subtitle: "Die Buchstaben-Erkennung wurde nicht gefunden. Freies Schreiben funktioniert, aber die Rückmeldung fehlt."
            )
        } else if vm.isRecognizing {
            statusBanner(
                icon: "sparkles",
                tint: .blue,
                title: "Erkenne…",
                subtitle: "Ich schaue mir deinen Buchstaben an."
            )
        } else if vm.isWaitingForRecognition {
            // Visible debounce window — child just lifted the pen, we're
            // holding recognition for a moment so multi-stroke letters
            // can finish. Makes the delay feel intentional instead of
            // laggy.
            statusBanner(
                icon: "hourglass",
                tint: Color(red: 0.40, green: 0.30, blue: 0.80),
                title: "Fertig mit dem Buchstaben?",
                subtitle: "Einen kleinen Moment — oder mach noch einen Strich, wenn du willst."
            )
        } else if let r = vm.lastRecognitionResult {
            letterResultPanel(result: r)
        } else if vm.hasRecognitionCompleted, !vm.freeformPoints.isEmpty {
            statusBanner(
                icon: "questionmark.circle.fill",
                tint: .orange,
                title: "Ich konnte nichts erkennen",
                subtitle: "Probiere es noch einmal — schreibe den Buchstaben groß und deutlich."
            )
        } else if vm.freeformPoints.isEmpty {
            Text("Schreibe einen Buchstaben mit dem Finger oder dem Stift.")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(FreeformSurface.prompt)
        } else {
            Text("Hebe den Finger, um deinen Buchstaben erkennen zu lassen.")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(FreeformSurface.prompt)
        }
    }

    private func metricPill(label: String,
                            value: CGFloat,
                            accent: Color) -> some View {
        let percent = Int((max(0, min(1, value)) * 100).rounded())
        return HStack(spacing: 6) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
            Text("\(percent) %")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(accent, in: Capsule())
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(accent.opacity(0.22), in: Capsule())
        .overlay(Capsule().stroke(accent.opacity(0.55), lineWidth: 1))
        .accessibilityLabel("\(label) \(percent) Prozent")
    }

    private func statusBanner(icon: String,
                              tint: Color,
                              title: String,
                              subtitle: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).foregroundStyle(.primary)
                Text(subtitle)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(FreeformSurface.prompt)
            }
            Spacer()
        }
        .padding(12)
        .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(tint.opacity(0.55), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title + ". " + subtitle)
    }

    private func letterResultPanel(result: RecognitionResult) -> some View {
        let raw = result.confidence
        let formScore = vm.lastFreeformFormScore
        let tint: Color = raw >= 0.7 ? .green : (raw >= 0.4 ? .yellow : .orange)
        let headline: String
        if raw >= 0.7 {
            headline = "Du hast ein \(result.predictedLetter) geschrieben!"
        } else if raw >= 0.4 {
            headline = "Das sieht aus wie ein \(result.predictedLetter)."
        } else {
            headline = "Vielleicht ein \(result.predictedLetter) — ich bin nicht sicher."
        }

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                Text(result.predictedLetter)
                    .font(.system(size: 76, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .frame(width: 92, height: 92)
                    .background(tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 6) {
                    Text(headline)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    HStack(spacing: 10) {
                        metricPill(label: "Klarheit",
                                   value: raw,
                                   accent: tint)
                        if let fs = formScore {
                            metricPill(label: "Form",
                                       value: fs,
                                       accent: fs >= 0.7 ? .green
                                              : (fs >= 0.4 ? .yellow : .orange))
                        }
                    }
                }
                Spacer()
            }

            // Top-3 alternatives. Shown always so the child sees the
            // runner-up guesses — especially useful when the top-1 is
            // a confident mis-classification of a confusable pair.
            if !result.topThree.isEmpty {
                HStack(spacing: 10) {
                    Text("Vorschläge:")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(FreeformSurface.prompt)
                    ForEach(Array(result.topThree.enumerated()), id: \.offset) { _, cand in
                        HStack(spacing: 4) {
                            Text(cand.letter)
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.primary)
                            Text("\(Int((cand.confidence * 100).rounded())) %")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(FreeformSurface.prompt)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.gray.opacity(0.22), in: Capsule())
                        .overlay(Capsule().stroke(Color.gray.opacity(0.5), lineWidth: 1))
                    }
                    Spacer()
                }
            }
        }
        .padding(14)
        .background(FreeformSurface.card, in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(FreeformSurface.cardEdge, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(headline)
    }

    @ViewBuilder
    private var wordFooter: some View {
        if vm.isRecognitionModelAvailable == false {
            statusBanner(
                icon: "exclamationmark.triangle.fill",
                tint: .red,
                title: "KI-Modell nicht verfügbar",
                subtitle: "Die Buchstaben-Erkennung wurde nicht gefunden. Du kannst trotzdem das Wort schreiben."
            )
        } else if vm.isRecognizing {
            statusBanner(
                icon: "sparkles",
                tint: .blue,
                title: "Erkenne das Wort…",
                subtitle: "Ich schaue mir deine Buchstaben an."
            )
        } else if !vm.freeformWordResultSlots.isEmpty {
            wordResultPanel
        } else {
            HStack(spacing: 12) {
                Text(vm.freeformPoints.isEmpty
                     ? "Schreibe das Wort Buchstabe für Buchstabe."
                     : "Wenn du fertig bist, tippe auf Fertig.")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(FreeformSurface.prompt)
                Spacer()
                Button {
                    vm.submitFreeformWord()
                } label: {
                    Label("Fertig", systemImage: "checkmark.seal.fill")
                        .font(.headline)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(vm.freeformPoints.count < 2)
                .accessibilityHint("Lässt alle geschriebenen Buchstaben erkennen und zeigt dir das Ergebnis")
            }
        }
    }

    @ViewBuilder
    private var wordResultPanel: some View {
        let target = vm.freeformTargetWord?.word ?? ""
        let targetChars = Array(target)
        // Slot-aligned so missing letters show as grey placeholder chips
        // rather than collapsing the row to just the recognized ones.
        let slots = vm.freeformWordResultSlots
        let recognized = slots.map { $0?.predictedLetter ?? "·" }.joined()
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                ForEach(Array(targetChars.enumerated()), id: \.offset) { idx, ch in
                    letterChip(expected: String(ch),
                               result: idx < slots.count ? slots[idx] : nil)
                }
            }
            Text("Erkannt: \(recognized.isEmpty ? "—" : recognized)")
                .font(.headline)
                .foregroundStyle(.primary)
            Text(recognized.uppercased() == target.uppercased()
                 ? "🎉 Super, du hast das Wort richtig geschrieben!"
                 : "Gut versucht! Vergleiche mit dem Zielwort oben.")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(FreeformSurface.prompt)
            HStack(spacing: 12) {
                Button {
                    vm.clearFreeformCanvas()
                } label: {
                    Label("Nochmal", systemImage: "arrow.counterclockwise")
                        .font(.headline)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)

                Button {
                    vm.exitFreeformMode()
                } label: {
                    Label("Zurück", systemImage: "chevron.left")
                        .font(.headline)
                }
                .buttonStyle(.bordered)
                .tint(.gray)
                Spacer()
            }
        }
        .padding(14)
        .background(FreeformSurface.card, in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(FreeformSurface.cardEdge, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
    }

    @ViewBuilder
    private func letterChip(expected: String, result: RecognitionResult?) -> some View {
        let correct = result?.predictedLetter.caseInsensitiveCompare(expected) == .orderedSame
        let shown = result?.predictedLetter ?? "·"
        let tint: Color = result == nil ? .gray : (correct ? .green : .orange)
        VStack(spacing: 2) {
            Text(expected).font(.caption.weight(.semibold)).foregroundStyle(.primary)
            Text(shown)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(tint, in: RoundedRectangle(cornerRadius: 8))
        }
        .accessibilityLabel("\(expected) wurde als \(shown) erkannt — \(correct ? "richtig" : "noch nicht richtig")")
    }

}

// MARK: - Freeform touch overlay (finger + pencil, no audio hookup)

private struct FreeformTouchOverlay: UIViewRepresentable {
    let canvasSize: CGSize
    let onBegan: (CGPoint) -> Void
    let onMoved: (CGPoint) -> Void
    let onEnded: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onBegan: onBegan, onMoved: onMoved, onEnded: onEnded)
    }

    func makeUIView(context: Context) -> TouchView {
        let v = TouchView(coordinator: context.coordinator)
        v.backgroundColor = .clear
        v.isMultipleTouchEnabled = false
        return v
    }

    func updateUIView(_ uiView: TouchView, context: Context) {
        uiView.coordinator = context.coordinator
    }

    final class TouchView: UIView {
        var coordinator: Coordinator
        init(coordinator: Coordinator) {
            self.coordinator = coordinator
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let t = touches.first else { return }
            coordinator.onBegan(t.location(in: self))
        }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let t = touches.first else { return }
            coordinator.onMoved(t.location(in: self))
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            coordinator.onEnded()
        }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            coordinator.onEnded()
        }
    }

    final class Coordinator {
        let onBegan: (CGPoint) -> Void
        let onMoved: (CGPoint) -> Void
        let onEnded: () -> Void
        init(onBegan: @escaping (CGPoint) -> Void,
             onMoved: @escaping (CGPoint) -> Void,
             onEnded: @escaping () -> Void) {
            self.onBegan = onBegan
            self.onMoved = onMoved
            self.onEnded = onEnded
        }
    }
}
