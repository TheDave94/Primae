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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// "Details" disclosure inside the result popup. When false the
    /// child sees only the predicted letter + the written evaluation;
    /// flipping it reveals Klarheit / Form pills and Vorschläge so
    /// adults watching can sanity-check the recogniser.
    @State private var showDetails = false
    /// IDs of recognition results we've already shown the popup for.
    /// Without this, dismissing the popup would just bring it back on
    /// the next render. Reset whenever the canvas is cleared.
    @State private var dismissedResultLetter: String? = nil

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.white
                    .ignoresSafeArea()

                // Anchor to the top + push the footer down with an
                // inert spacer. Without this the ZStack-default centring
                // made the canvas slide vertically every time the
                // footer's content changed height (idle prompt → "Erkenne…"
                // banner → result row), and a child mid-stroke saw their
                // letter jump several points up or down between pen
                // lifts. The footer reserves a stable `minHeight` (see
                // `footer` below) so its expansion never eats the spacer.
                VStack(spacing: 0) {
                    header
                    if vm.freeformSubMode == .word {
                        wordPickerStrip
                    }
                    freeformCanvas(size: geo.size)
                    Spacer(minLength: 0)
                    footer
                }
                .frame(maxWidth: .infinity,
                       maxHeight: .infinity,
                       alignment: .top)

                if shouldShowResultPopup, let r = vm.lastRecognitionResult {
                    resultPopup(result: r)
                        .transition(reduceMotion
                                    ? .opacity
                                    : .scale(scale: 0.92).combined(with: .opacity))
                        .zIndex(20)
                }
            }
        }
        // Canvas is hard-coded `Color.white`, so pin the rest of the
        // view to light mode too — otherwise `.primary`/`.secondary`
        // resolve to white-ish in dark mode and disappear into the
        // canvas, exactly the white-on-white symptom in IMG_0337–0340.
        .preferredColorScheme(.light)
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.82),
                   value: shouldShowResultPopup)
        .onChange(of: vm.freeformPoints.count) { _, newValue in
            // New stroke after a dismissed result → re-arm the popup
            // for the next recognition. Without this the popup would
            // never come back unless the user left and re-entered the
            // mode.
            if newValue == 0 { dismissedResultLetter = nil }
        }
    }

    /// Show the popup only for letter mode, only when the recogniser
    /// has produced a result, and only if the child hasn't already
    /// dismissed THIS particular result. Word-mode keeps its inline
    /// slot-aligned chip row; the popup is letter-mode-only.
    private var shouldShowResultPopup: Bool {
        guard vm.freeformSubMode == .letter,
              let r = vm.lastRecognitionResult else { return false }
        return dismissedResultLetter != popupKey(for: r)
    }

    private func popupKey(for r: RecognitionResult) -> String {
        // Per-result key: predicted letter + confidence to two decimals.
        // Same letter shown twice in a row should pop again because the
        // form score / stroke count likely changed.
        "\(r.predictedLetter)-\(Int((r.confidence * 100).rounded()))-\(vm.freeformStrokeSizes.count)"
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
        // `minHeight` reserves enough vertical space for the tallest
        // letterFooter state (post-popup result row, ≈ 92 pt) so the
        // footer never grows or shrinks during a writing session.
        // Word mode's wordResultPanel is taller, but it only appears
        // after the explicit "Fertig" button — never mid-stroke — so
        // a temporary expansion there is acceptable. Top alignment
        // keeps short prompts from drifting toward the centre.
        .frame(maxWidth: .infinity,
               minHeight: 130,
               alignment: .top)
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

    /// Tiny inline stub shown under the canvas after the popup has
    /// been dismissed. Just the predicted letter + the headline — no
    /// Vorschläge, no Klarheit/Form pills. Detail breakdown lives in
    /// the popup's "Details" disclosure.
    private func letterResultPanel(result: RecognitionResult) -> some View {
        let raw = result.confidence
        let tint: Color = raw >= 0.7 ? .green : (raw >= 0.4 ? .yellow : .orange)
        let headline = headline(for: result)
        return HStack(spacing: 14) {
            Text(result.predictedLetter)
                .font(.system(size: 56, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .frame(width: 72, height: 72)
                .background(tint.opacity(0.20), in: RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(tint.opacity(0.55), lineWidth: 1)
                )
            Text(headline)
                .font(.headline)
                .foregroundStyle(.primary)
            Spacer()
            // Re-open the popup so the child can see the written
            // evaluation again on demand.
            Button {
                dismissedResultLetter = nil
            } label: {
                Image(systemName: "info.circle.fill")
                    .font(.title2)
                    .foregroundStyle(tint)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Bewertung erneut anzeigen")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(FreeformSurface.card, in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(FreeformSurface.cardEdge, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(headline)
    }

    private func headline(for result: RecognitionResult) -> String {
        let raw = result.confidence
        if raw >= 0.7 {
            return "Du hast ein \(result.predictedLetter) geschrieben!"
        } else if raw >= 0.4 {
            return "Das sieht aus wie ein \(result.predictedLetter)."
        } else {
            return "Vielleicht ein \(result.predictedLetter) — ich bin nicht sicher."
        }
    }

    // MARK: - Result popup (child-facing written evaluation)

    /// Modal-style popup centred over the canvas. Drives off the form
    /// score (FreeWriteScorer.formAccuracyShape) so the message rewards
    /// well-shaped letters even when CoreML's confusable-pair penalty
    /// drops Klarheit. Falls back to a Klarheit-only message when no
    /// reference glyph is bundled for the recognised letter.
    private func resultPopup(result: RecognitionResult) -> some View {
        let formScore = vm.lastFreeformFormScore
        let scoreForMessage = formScore ?? result.confidence
        let tint: Color = scoreForMessage >= 0.7 ? .green
                       : (scoreForMessage >= 0.45 ? .yellow : .orange)
        let evaluation = formEvaluation(score: scoreForMessage,
                                        letter: result.predictedLetter,
                                        hasFormScore: formScore != nil)
        let stars = formStars(for: scoreForMessage)

        return ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { dismissPopup(for: result) }
                .accessibilityHidden(true)

            VStack(spacing: 18) {
                Text(result.predictedLetter)
                    .font(.system(size: 96, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .frame(width: 132, height: 132)
                    .background(tint.opacity(0.22),
                                in: RoundedRectangle(cornerRadius: 26))
                    .overlay(
                        RoundedRectangle(cornerRadius: 26)
                            .stroke(tint.opacity(0.55), lineWidth: 2)
                    )

                Text(headline(for: result))
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)

                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { idx in
                        let filled = idx < stars
                        Image(systemName: filled ? "star.fill" : "star")
                            .font(.system(size: 26))
                            .foregroundStyle(filled ? Color.orange : Color.gray.opacity(0.45))
                    }
                }
                .accessibilityLabel("\(stars) von 3 Sternen für die Form")

                Text(evaluation)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(FreeformSurface.prompt)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)

                HStack(spacing: 14) {
                    Button {
                        vm.clearFreeformCanvas()
                        dismissPopup(for: result)
                    } label: {
                        Label("Nochmal", systemImage: "arrow.counterclockwise")
                            .font(.headline)
                            .padding(.horizontal, 12)
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)

                    Button {
                        dismissPopup(for: result)
                    } label: {
                        Label("Weiter", systemImage: "checkmark")
                            .font(.headline)
                            .padding(.horizontal, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                }

                DisclosureGroup(isExpanded: $showDetails) {
                    detailsRow(result: result, formScore: formScore, tint: tint)
                        .padding(.top, 10)
                } label: {
                    Text(showDetails ? "Weniger anzeigen" : "Details anzeigen")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(FreeformSurface.prompt)
                }
                .accentColor(FreeformSurface.prompt)
                .padding(.top, 4)
            }
            .padding(28)
            .frame(maxWidth: 460)
            .background(FreeformSurface.card,
                        in: RoundedRectangle(cornerRadius: 28))
            .overlay(
                RoundedRectangle(cornerRadius: 28)
                    .stroke(FreeformSurface.cardEdge, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
            .padding(24)
        }
    }

    private func dismissPopup(for result: RecognitionResult) {
        dismissedResultLetter = popupKey(for: result)
        showDetails = false
    }

    /// Klarheit + Form pills + Vorschläge — moved from the always-on
    /// inline panel to the popup's "Details anzeigen" disclosure so
    /// the child's default view stays uncluttered.
    @ViewBuilder
    private func detailsRow(result: RecognitionResult,
                             formScore: CGFloat?,
                             tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                metricPill(label: "Klarheit",
                           value: result.confidence,
                           accent: tint)
                if let fs = formScore {
                    metricPill(label: "Form",
                               value: fs,
                               accent: fs >= 0.7 ? .green
                                      : (fs >= 0.45 ? .yellow : .orange))
                }
                Spacer()
            }
            if !result.topThree.isEmpty {
                HStack(spacing: 8) {
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
    }

    /// Stars 0–3 from the form (or fallback) score. Bands mirror the
    /// celebration overlay's tiering so a "3 stars in the popup" lines
    /// up with what the child sees on phase completion.
    private func formStars(for score: CGFloat) -> Int {
        switch score {
        case 0.85...:   return 3
        case 0.65..<0.85: return 2
        case 0.40..<0.65: return 1
        default:        return 0
        }
    }

    /// Child-friendly written evaluation. Distinct messages per band
    /// rather than a single template so the kid sees variety, and
    /// `hasFormScore == false` (letter has no bundled reference)
    /// rephrases to avoid telling the child their shape is "great"
    /// when we couldn't actually measure shape.
    private func formEvaluation(score: CGFloat,
                                 letter: String,
                                 hasFormScore: Bool) -> String {
        if !hasFormScore {
            // No reference glyph for this letter — speak only to what
            // the recogniser saw, not to shape we didn't measure.
            return score >= 0.7
                ? "Super, ich erkenne dein \(letter) ganz klar!"
                : "Ich glaube, das ist ein \(letter). Probier es nochmal größer und deutlicher."
        }
        switch score {
        case 0.85...:
            return "Wunderschön! Dein \(letter) sieht fast aus wie im Buch. ⭐️"
        case 0.70..<0.85:
            return "Toll gemacht! Dein \(letter) ist sehr gut geworden."
        case 0.55..<0.70:
            return "Gut! Mit ein bisschen Übung wird dein \(letter) noch schöner."
        case 0.35..<0.55:
            return "Nicht schlecht! Probier dein \(letter) etwas größer und langsamer."
        default:
            return "Übe dein \(letter) noch ein bisschen — du schaffst das!"
        }
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
