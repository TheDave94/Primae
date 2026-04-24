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
                            .font(.subheadline).foregroundStyle(.secondary)
                        Text(target.word)
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .foregroundStyle(.primary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Zielwort \(target.word)")
                } else {
                    Text("Schreibe einen Buchstaben mit dem Finger oder dem Stift")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
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
                            .font(.system(.headline, design: .rounded))
                            .foregroundStyle(isSelected ? Color.white : Color.primary)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(
                                isSelected ? Color.purple : Color.purple.opacity(0.12),
                                in: Capsule()
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
                .font(.subheadline).foregroundStyle(.secondary)
        } else {
            Text("Hebe den Finger, um deinen Buchstaben erkennen zu lassen.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
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
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title + ". " + subtitle)
    }

    private func letterResultPanel(result: RecognitionResult) -> some View {
        let raw = result.confidence
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
                    Text("Sicherheit: \(Int((raw * 100).rounded())) %")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }

            // Top-3 alternatives. Shown always so the child sees the
            // runner-up guesses — especially useful when the top-1 is
            // a confident mis-classification of a confusable pair.
            if !result.topThree.isEmpty {
                HStack(spacing: 10) {
                    Text("Vorschläge:")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(result.topThree.enumerated()), id: \.offset) { _, cand in
                        HStack(spacing: 4) {
                            Text(cand.letter)
                                .font(.subheadline.weight(.semibold))
                            Text("\(Int((cand.confidence * 100).rounded())) %")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.gray.opacity(0.12), in: Capsule())
                    }
                    Spacer()
                }
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
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
        } else if !vm.freeformWordResults.isEmpty {
            wordResultPanel
        } else {
            HStack(spacing: 12) {
                Text(vm.freeformPoints.isEmpty
                     ? "Schreibe das Wort Buchstabe für Buchstabe."
                     : "Wenn du fertig bist, tippe auf Fertig.")
                    .font(.subheadline).foregroundStyle(.secondary)
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
        let results = vm.freeformWordResults
        let recognized = results.map(\.predictedLetter).joined()
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                ForEach(Array(targetChars.enumerated()), id: \.offset) { idx, ch in
                    letterChip(expected: String(ch),
                               result: idx < results.count ? results[idx] : nil)
                }
            }
            Text("Erkannt: \(recognized.isEmpty ? "—" : recognized)")
                .font(.headline)
                .foregroundStyle(.primary)
            Text(recognized.uppercased() == target.uppercased()
                 ? "🎉 Super, du hast das Wort richtig geschrieben!"
                 : "Gut versucht! Vergleiche mit dem Zielwort oben.")
                .font(.subheadline).foregroundStyle(.secondary)
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
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    @ViewBuilder
    private func letterChip(expected: String, result: RecognitionResult?) -> some View {
        let correct = result?.predictedLetter.caseInsensitiveCompare(expected) == .orderedSame
        let shown = result?.predictedLetter ?? "·"
        let tint: Color = result == nil ? .gray : (correct ? .green : .orange)
        VStack(spacing: 2) {
            Text(expected).font(.caption).foregroundStyle(.secondary)
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
