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
            .overlay(alignment: .center) {
                if vm.isRecognizing {
                    recognitionSpinner
                }
            }
        }
    }

    // MARK: - Header (target prompt + exit)

    private var header: some View {
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

            if vm.freeformSubMode == .word, let target = vm.freeformTargetWord {
                VStack(spacing: 2) {
                    Text("Schreibe:")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(target.word)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Zielwort \(target.word)")
            } else {
                Text("Schreibe einen Buchstaben")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }

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
        if let r = vm.lastRecognitionResult {
            letterResultPanel(result: r)
        } else if vm.freeformPoints.isEmpty {
            Text("Schreibe einen Buchstaben mit dem Finger oder dem Stift.")
                .font(.subheadline).foregroundStyle(.secondary)
        } else {
            Text("Hebe den Finger, um deinen Buchstaben erkennen zu lassen.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private func letterResultPanel(result: RecognitionResult) -> some View {
        let raw = result.confidence
        let message = raw < 0.4
            ? "Hmm, das konnte ich nicht erkennen — versuche es nochmal!"
            : "Du hast ein \(result.predictedLetter) geschrieben!"
        let tint: Color = raw < 0.4 ? .orange : .green
        return VStack(spacing: 12) {
            HStack(spacing: 16) {
                Text(result.predictedLetter)
                    .font(.system(size: 76, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .frame(width: 92, height: 92)
                    .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 6) {
                    Text(message)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    if raw >= 0.4 {
                        Text("Sicherheit: \(Int((raw * 100).rounded())) %")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
    }

    @ViewBuilder
    private var wordFooter: some View {
        if vm.freeformWordResults.isEmpty {
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
        } else {
            wordResultPanel
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

    private var recognitionSpinner: some View {
        VStack(spacing: 10) {
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(1.4)
            Text("Einen Moment…").font(.subheadline)
        }
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityLabel("Erkenne deine Schrift…")
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
