import SwiftUI
import UIKit
import CoreText

struct TracingCanvasView: View {
    @Environment(TracingViewModel.self) private var vm
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    @ViewBuilder
    private func tracingCanvas(geo: GeometryProxy) -> some View {
        Canvas { context, size in
            // Frame source: for singleLetter / repetition sequences the
            // cells are evenly-spaced, so we compute fresh from the live
            // Canvas `size` to avoid any first-render staleness. For word
            // sequences the layout depends on CoreText character advances,
            // so we use the stored cell frames — recomputing a CoreText
            // run per redraw would thrash the frame budget.
            let wordRendering = vm.gridWordRendering
            let frames: [CGRect]
            if wordRendering != nil {
                frames = vm.gridCells.map(\.frame)
            } else {
                frames = GridLayoutCalculator.cellFrames(
                    canvasSize: size, preset: vm.gridPreset)
            }
            let cellCount = min(frames.count, vm.gridCells.count)
            let activeIndex = vm.gridActiveCellIndex

            // Whole-word image (word mode only): drawn once at full canvas
            // size so the cursive connectors between letters flow across
            // cell boundaries instead of getting cropped per glyph.
            if let wr = wordRendering {
                context.draw(Image(uiImage: wr.image),
                             in: CGRect(origin: .zero, size: size))
            }
            for i in 0..<cellCount {
                let cellFrame = frames[i]
                let cellSize  = cellFrame.size
                let ox        = cellFrame.minX
                let oy        = cellFrame.minY
                // Per-cell letter — for single-letter sessions every cell has
                // the same letter (repetition or length-1), for word mode
                // each cell has its own character.
                let cellLetter = vm.gridCellLetter(at: i) ?? vm.currentLetterName
                let isActiveCell = (i == activeIndex)

                // Background: render the cell's own letter at cell size.
                // Skipped in word mode — the whole-word image was already
                // drawn above so the ligatures connect across cells.
                // Falls back to the VM's shared currentLetterImage when
                // rendering fails (missing font glyph) so the single-letter
                // path still shows its PBM backup.
                if wordRendering == nil {
                    if let img = PrimaeLetterRenderer.render(
                        letter: cellLetter, size: cellSize, schriftArt: vm.schriftArt) {
                        context.draw(Image(uiImage: img), in: cellFrame)
                    } else if let img = vm.currentLetterImage, cellLetter == vm.currentLetterName {
                        context.draw(Image(uiImage: img), in: cellFrame)
                    }
                }

                // Ghost scaffolding: phase drives default visibility (observe/guided = on,
                // freeWrite = off). User's showGhost toggle can ADD ghost in observe/guided,
                // but cannot re-enable it in freeWrite (scaffolding is withdrawn per GRRM).
                // Suppressed while calibrating — these are fat (lineWidth 6) blue paths
                // drawn for every stroke on the glyph and they were still covering the
                // letter even after the other phase overlays were hidden.
                if (vm.showGhostForPhase || (vm.showGhost && vm.learningPhase != .freeWrite)),
                   !vm.isCalibrating,
                   let rawStrokes = vm.gridCellStrokes(at: i),
                   !rawStrokes.strokes.isEmpty,
                   let gr = PrimaeLetterRenderer.normalizedGlyphRect(for: cellLetter, canvasSize: cellSize, schriftArt: vm.schriftArt) {
                    // Ghost lines from stroke JSON — same data as dots, guaranteed alignment.
                    for stroke in rawStrokes.strokes {
                        guard stroke.checkpoints.count >= 2 else { continue }
                        var ghostPath = Path()
                        let first = stroke.checkpoints[0]
                        ghostPath.move(to: CGPoint(
                            x: ox + (gr.minX + first.x * gr.width) * cellSize.width,
                            y: oy + (gr.minY + first.y * gr.height) * cellSize.height))
                        for cp in stroke.checkpoints.dropFirst() {
                            ghostPath.addLine(to: CGPoint(
                                x: ox + (gr.minX + cp.x * gr.width) * cellSize.width,
                                y: oy + (gr.minY + cp.y * gr.height) * cellSize.height))
                        }
                        context.stroke(ghostPath, with: .color(.canvasGhost.opacity(0.35)),
                                       style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                    }
                }

                // Stroke start dots — use phaseController.showCheckpoints (single source
                // of truth for phase scaffolding) instead of duplicating the rule here.
                // Suppressed while calibrating so the calibrator's own numbered dots
                // aren't doubled up by the phase's fat start-dot overlay.
                if vm.showCheckpoints, !vm.isCalibrating,
                   let rawStrokes = vm.gridCellStrokes(at: i),
                   !rawStrokes.strokes.isEmpty,
                   let gr = PrimaeLetterRenderer.normalizedGlyphRect(
                       for: cellLetter, canvasSize: cellSize, schriftArt: vm.schriftArt) {
                    for (idx, stroke) in rawStrokes.strokes.enumerated() {
                        guard let first = stroke.checkpoints.first else { continue }
                        let isComplete = vm.isStrokeCompleted(idx)
                        let isActive = vm.activeStrokeIndex == idx
                        let screenX = ox + (gr.minX + first.x * gr.width) * cellSize.width
                        let screenY = oy + (gr.minY + first.y * gr.height) * cellSize.height
                        let pt = CGPoint(x: screenX, y: screenY)
                        let r: CGFloat = isActive ? 18 : 14
                        let dotRect = CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)
                        let dot = Path(ellipseIn: dotRect)
                        let color: Color = isComplete ? .green : (isActive ? .blue : .gray)
                        context.fill(dot, with: .color(color.opacity(0.75)))
                    }
                }

                // Retained ink from previously-completed cells — stays on
                // screen so the child can see the letter they just wrote
                // even after the active cursor has moved on. Empty for
                // single-cell sessions (completion fires commit and the
                // load(letter:) reset clears on the next letter).
                let retainedInk = vm.gridCells[i].activePath
                if retainedInk.count > 1 {
                    var path = Path()
                    path.addLines(retainedInk)
                    context.stroke(path, with: .color(.canvasInkStroke.opacity(0.9)),
                                   style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                }

                // Active ink path — the child's in-progress stroke, in
                // absolute canvas coords. Drawn only on the active cell
                // pass: for single-cell that's the one iteration (identical
                // to pre-grid behavior); for multi-cell it avoids the same
                // pixels being stroked N times and keeps ink scoped to
                // the cell the child is currently tracing.
                if isActiveCell, vm.activePath.count > 1 {
                    var path = Path()
                    path.addLines(vm.activePath)
                    let inkWidth: CGFloat = vm.pencilPressure.map { 4 + $0 * 10 } ?? 8
                    context.stroke(path, with: .color(.canvasInkStroke),
                                   style: StrokeStyle(lineWidth: inkWidth, lineCap: .round, lineJoin: .round))
                }

                // Animation guide dot — ACTIVE cell only. Guide scans the
                // active letter's stroke path; rendering it in every cell
                // would show N dots scanning N letters in parallel.
                // Hidden while calibrating: the observe-phase animation would
                // otherwise scan across the calibrator's numbered dots and make
                // it impossible to tell what sits where on the glyph.
                if isActiveCell, let point = vm.animationGuidePoint, !vm.isCalibrating,
                   let gr = PrimaeLetterRenderer.normalizedGlyphRect(for: cellLetter, canvasSize: cellSize, schriftArt: vm.schriftArt) {
                    let screenPt = CGPoint(
                        x: ox + (gr.minX + point.x * gr.width) * cellSize.width,
                        y: oy + (gr.minY + point.y * gr.height) * cellSize.height)
                    let r: CGFloat = 22
                    let dotRect   = CGRect(x: screenPt.x - r, y: screenPt.y - r, width: r * 2, height: r * 2)
                    let dot       = Path(ellipseIn: dotRect)
                    // Animation guide dot — Primae design system pins
                    // this as amber (`--guide`), not blue. Renders as
                    // amber-500 in light, amber-400 in dark.
                    context.fill(dot,   with: .color(.canvasGuide.opacity(0.85)))
                    context.stroke(dot, with: .color(.canvasPaper.opacity(0.60)), lineWidth: 2)
                }

                // Directional arrow — ACTIVE cell only. Direct-phase cue
                // belongs to the cell the child is currently being asked
                // to tap; other cells are static scaffolding.
                if isActiveCell, let arrowIdx = vm.directArrowStrokeIndex, !vm.isCalibrating,
                   let rawStrokes = vm.gridCellStrokes(at: i),
                   arrowIdx < rawStrokes.strokes.count,
                   rawStrokes.strokes[arrowIdx].checkpoints.count >= 2,
                   let gr = PrimaeLetterRenderer.normalizedGlyphRect(
                       for: cellLetter, canvasSize: cellSize, schriftArt: vm.schriftArt) {
                    let stroke = rawStrokes.strokes[arrowIdx]
                    let c0 = stroke.checkpoints[0]
                    let c1 = stroke.checkpoints[1]
                    let from = CGPoint(x: ox + (gr.minX + c0.x * gr.width) * cellSize.width,
                                       y: oy + (gr.minY + c0.y * gr.height) * cellSize.height)
                    let to   = CGPoint(x: ox + (gr.minX + c1.x * gr.width) * cellSize.width,
                                       y: oy + (gr.minY + c1.y * gr.height) * cellSize.height)
                    var linePath = Path()
                    linePath.move(to: from)
                    linePath.addLine(to: to)
                    context.stroke(linePath, with: .color(.canvasGuide.opacity(0.9)),
                                   style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    let dx = to.x - from.x
                    let dy = to.y - from.y
                    let angle = atan2(dy, dx)
                    let tipLen: CGFloat = 18
                    let spread: CGFloat = .pi / 5
                    let b1 = CGPoint(x: to.x - tipLen * cos(angle - spread),
                                     y: to.y - tipLen * sin(angle - spread))
                    let b2 = CGPoint(x: to.x - tipLen * cos(angle + spread),
                                     y: to.y - tipLen * sin(angle + spread))
                    var headPath = Path()
                    headPath.move(to: to)
                    headPath.addLine(to: b1)
                    headPath.move(to: to)
                    headPath.addLine(to: b2)
                    context.stroke(headPath, with: .color(.canvasGuide.opacity(0.9)),
                                   style: StrokeStyle(lineWidth: 5, lineCap: .round))
                }
            }

            // Active-cell highlight: soft blue ring around the active cell
            // in multi-cell layouts. Skipped for single-cell (ring around
            // the whole canvas would be visual noise).
            if cellCount > 1, activeIndex < frames.count, !vm.isCalibrating {
                let activeFrame = frames[activeIndex].insetBy(dx: 2, dy: 2)
                let ringPath = Path(roundedRect: activeFrame,
                                    cornerSize: CGSize(width: 14, height: 14))
                context.stroke(ringPath, with: .color(.blue.opacity(0.55)),
                               style: StrokeStyle(lineWidth: 3))
            }

            // Progress bar: canvas-wide (one total for the whole sequence),
            // not per cell. Identical to pre-grid for length-1.
            let clampedProgress = max(0, min(1, vm.progress))
            let trackRect = CGRect(x: 0, y: size.height - 8, width: size.width,                    height: 8)
            let fillRect  = CGRect(x: 0, y: size.height - 8, width: size.width * clampedProgress, height: 8)

            context.fill(Path(trackRect), with: .color(.black.opacity(0.1)))
            context.fill(Path(fillRect),  with: .color(differentiateWithoutColor ? .blue : .green))
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func freeWriteKPOverlay() -> some View {
        Canvas { context, size in
            // Reference strokes in blue (opacity 0.4, lineWidth 8)
            if let rawStrokes = vm.glyphRelativeStrokes,
               !rawStrokes.strokes.isEmpty,
               let gr = PrimaeLetterRenderer.normalizedGlyphRect(
                   for: vm.currentLetterName, canvasSize: size, schriftArt: vm.schriftArt) {
                for stroke in rawStrokes.strokes {
                    guard stroke.checkpoints.count >= 2 else { continue }
                    var refPath = Path()
                    let first = stroke.checkpoints[0]
                    refPath.move(to: CGPoint(
                        x: (gr.minX + first.x * gr.width) * size.width,
                        y: (gr.minY + first.y * gr.height) * size.height))
                    for cp in stroke.checkpoints.dropFirst() {
                        refPath.addLine(to: CGPoint(
                            x: (gr.minX + cp.x * gr.width) * size.width,
                            y: (gr.minY + cp.y * gr.height) * size.height))
                    }
                    context.stroke(refPath, with: .color(.canvasGhost.opacity(0.4)),
                                   style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
                }
            }

            // Child's freeWrite path in green (lineWidth 4)
            let pts = vm.freeWritePath
            if pts.count > 1 {
                var childPath = Path()
                childPath.move(to: CGPoint(x: pts[0].x * size.width, y: pts[0].y * size.height))
                for pt in pts.dropFirst() {
                    childPath.addLine(to: CGPoint(x: pt.x * size.width, y: pt.y * size.height))
                }
                context.stroke(childPath, with: .color(.canvasInkStroke),
                               style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
        }
        .background(.black.opacity(0.15))
        .contentShape(Rectangle())
        .onTapGesture { vm.overlayQueue.dismiss() }
        // Auto-dismiss is owned by OverlayQueueManager (3 s default for
        // .kpOverlay). The queue advances itself, so no local timer here.
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                tracingCanvas(geo: geo)
                    .modifier(TracingCanvasAccessibility(vm: vm))

                ProgressPill(progress: vm.progress,
                             differentiateWithoutColor: differentiateWithoutColor)
                    .equatable()
                    .padding(.leading, 12)
                    .padding(.bottom, 16)
            }
            .onAppear { vm.canvasSize = geo.size }
            .onChange(of: geo.size) { _, newSize in vm.canvasSize = newSize }
            .overlay(
                PencilAwareCanvasOverlay(
                    canvasSize: geo.size,
                    onBegan:  { pt, t in
                        // Feed the input-mode detector first so a pencil
                        // session flips to the pencil preset before the
                        // touch kicks off any grid-preset-dependent work.
                        vm.pencilDidTouchDown()
                        vm.beginTouch(at: pt, t: t)
                    },
                    onMoved:  { pt, t, pressure, azimuth, size in
                        vm.pencilPressure = pressure
                        vm.pencilAzimuth  = azimuth
                        vm.updateTouch(at: pt, t: t, canvasSize: size)
                    },
                    onEnded:  { vm.endTouch() },
                    onPencilSqueeze: { vm.replayAudio() }
                )
                // Tracing input is suspended while calibrating so dragging a
                // dot doesn't also fire proximity audio / stroke progress on
                // the underlying tracker.
                .allowsHitTesting(!vm.isCalibrating)
            )
            .overlay(
                // Finger tracing only: 1-finger → trace. Letter / audio /
                // ghost navigation routed through the visible world-bar
                // controls (MainAppView / SchuleWorldView) to avoid
                // accidental palm-rest triggers for 5-year-olds.
                //
                // Disabled entirely in the direct phase: the VM's `beginTouch`
                // already no-ops for .direct, and because this is a
                // UIViewRepresentable its embedded UIView can swallow taps
                // before the SwiftUI dots overlay above gets a chance to
                // recognise them. `.allowsHitTesting(false)` removes it from
                // hit-testing for the duration of Richtung-lernen so the
                // numbered-dot tap gestures always win.
                UnifiedTouchOverlay(
                    canvasSize: geo.size,
                    onSingleTouchBegan:  { pt, t in
                        // Symmetrical with the pencil overlay — record
                        // the finger touch for the detector's hysteresis
                        // before routing into the tracing flow.
                        vm.fingerDidTouchDown()
                        vm.beginTouch(at: pt, t: t)
                    },
                    onSingleTouchMoved:  { pt, t, size in vm.updateTouch(at: pt, t: t, canvasSize: size) },
                    onSingleTouchEnded:  { vm.endTouch() },
                    // Two-finger vertical swipe cycles through the letter's
                    // audio variants — up = next, down = previous.
                    onTwoFingerSwipeUp:   { vm.nextAudioVariant() },
                    onTwoFingerSwipeDown: { vm.previousAudioVariant() }
                )
                .allowsHitTesting(vm.learningPhase != .direct && !vm.isCalibrating)
            )
            .overlay(
                Group {
                    // Calibrator owns the numbered-dot visualization while
                    // it's open; the direct-phase overlay would draw the
                    // next-expected tap dot on top of it otherwise.
                    if vm.learningPhase == .direct, !vm.isCalibrating {
                        DirectPhaseDotsOverlay()
                    }
                }
            )
            .overlay(
                Group {
                    if case .kpOverlay = vm.overlayQueue.currentOverlay {
                        freeWriteKPOverlay()
                    }
                }
            )
        }
    }
}

// MARK: - Accessibility modifier

private struct TracingCanvasAccessibility: ViewModifier {
    var vm: TracingViewModel

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(vm.accessibilityCanvasLabel)
            .accessibilityValue(vm.accessibilityCanvasValue)
            .accessibilityHint("Ziehe mit einem Finger, um den Buchstaben nachzufahren. Nutze die Aktionen, um Buchstaben zu wechseln oder den Ton abzuspielen.")
            .accessibilityActions {
                Button("Buchstaben-Ton abspielen") { vm.replayAudio() }
                Button("Nächster Buchstabe")      { vm.nextLetter() }
                Button("Vorheriger Buchstabe")    { vm.previousLetter() }
                Button("Zufälliger Buchstabe")    { vm.randomLetter() }
                Button("Zurücksetzen")            { vm.resetLetter() }
                Button("Hilfslinien umschalten")  { vm.toggleGhost() }
            }
    }
}

// MARK: - Progress pill

/// Verbal/visual progress capsule shown in the bottom-leading corner of
/// the tracing canvas. Children at age 5–6 don't read percentages, so
/// this renders a coloured fill bar (blue → yellow → green as progress
/// rises) with **no number visible**. The numeric figure remains
/// accessible to assistive tech and to engineering builds.
/// Equatable so callers can wrap in `.equatable()` and SwiftUI skips
/// body re-evaluation when neither `progress` nor
/// `differentiateWithoutColor` changed. The pill re-renders on every
/// `vm.*` change otherwise — most of which (audio state, recognition
/// result, overlay queue, …) don't affect this view at all.
private struct ProgressPill: View, Equatable {
    let progress: CGFloat
    let differentiateWithoutColor: Bool

    var body: some View {
        let p = max(0, min(1, progress))
        let tint: Color = p >= 0.99 ? .green : (p >= 0.5 ? .yellow : .blue)
        return ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.gray.opacity(0.18))
            GeometryReader { geo in
                Capsule()
                    .fill(tint)
                    .frame(width: geo.size.width * p)
            }
            .frame(height: 8)
            #if DEBUG
            // Engineering builds keep the numeric readout for tuning;
            // children never see it because Release strips this branch.
            Text("\(Int(p * 100))%")
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(.primary)
                .padding(.leading, 8)
            #endif
        }
        .frame(width: 88, height: 8)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .stroke((differentiateWithoutColor ? Color.blue : tint).opacity(0.55), lineWidth: 1)
        )
        // Status is communicated verbally through ChildSpeechLibrary on
        // phase transitions; the pill is decorative for the canvas.
        .accessibilityHidden(true)
    }
}

// MARK: - Direct phase dot overlay

/// Renders numbered start-dot circles for the direct phase and routes taps to the VM.
/// Sits above the touch overlays so SwiftUI tap gestures win over the tracing handler.
private struct DirectPhaseDotsOverlay: View {
    @Environment(TracingViewModel.self) private var vm
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Drives the wrong-tap "look here" emphasis pulse. Bound to
    /// `vm.directPulsingDot` (currently never raised in practice
    /// because the overlay only renders one dot at a time, but kept
    /// for Reduce-Motion / a11y parity if the rendering policy ever
    /// changes back to all-dots-at-once).
    @State private var pulseToggle = false
    /// Drives the continuous attention-pulse on the next-expected
    /// dot. Without it the dot just sits there static and a 5-yr-
    /// old can scan past it; the slow breathing scale (1.0 ↔ 1.18)
    /// reads as "tap me" without being distracting.
    @State private var idlePulse = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Render only the next-expected dot. Many letters have two
                // strokes that start at the same glyph-relative point (e.g. A's
                // two diagonals share the apex, F's vertical and horizontal
                // share the top-left), so drawing every stroke's start dot at
                // once stacks unreadable circles on top of each other. Showing
                // one at a time also matches the phase's pedagogy: tap the
                // current start → watch the direction arrow → the next start
                // appears, possibly at the exact same spot, which is correct.
                // W-24: in word mode the glyph rect must be computed
                // against the active *cell*, not the whole canvas — the
                // strokes are cell-local. Single-cell layouts (the default
                // for every letter session) keep using `geo.size` and the
                // canvas origin, so the path is unchanged for them.
                let cellFrame = vm.multiCellActiveFrame
                ?? CGRect(origin: .zero, size: geo.size)
                if let rawStrokes = vm.rawGlyphStrokes,
                   !rawStrokes.strokes.isEmpty,
                   vm.directNextExpectedDotIndex < rawStrokes.strokes.count,
                   let gr = PrimaeLetterRenderer.normalizedGlyphRect(
                       for: vm.currentLetterName,
                       canvasSize: cellFrame.size,
                       schriftArt: vm.schriftArt) {
                    let idx = vm.directNextExpectedDotIndex
                    dotView(idx: idx,
                            stroke: rawStrokes.strokes[idx],
                            gr: gr,
                            cellFrame: cellFrame)
                        // `.id(idx)` makes SwiftUI treat each
                        // next-expected dot as a distinct view, so
                        // the outgoing one runs the exit transition
                        // (scale up + fade) and the incoming one runs
                        // the entry transition. Visual confirmation
                        // of a registered tap that doesn't depend on
                        // haptic / audio (iPad lacks the Taptic Engine
                        // for impact haptics, and system sounds are
                        // silenced by the ringer switch).
                        .id(idx)
                        .transition(reduceMotion
                                    ? .opacity
                                    : .asymmetric(
                                        insertion: .scale(scale: 0.6).combined(with: .opacity),
                                        removal: .scale(scale: 1.6).combined(with: .opacity)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: vm.directPulsingDot) { _, isPulsing in
            // Respect Reduce Motion: skip the repeating pulse so users
            // who disabled motion don't see the dot animate. The wrong-
            // tap haptic + the on-screen dot still convey the prompt.
            guard isPulsing, !reduceMotion else { pulseToggle = false; return }
            withAnimation(.easeInOut(duration: 0.25).repeatCount(3, autoreverses: true)) {
                pulseToggle = true
            }
            Task {
                try? await Task.sleep(for: .milliseconds(800))
                pulseToggle = false
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            // Toggle the value so the .animation(_:value: idlePulse)
            // modifier on the dot picks up a state change. Without
            // wrapping in withAnimation here — the modifier carries
            // the curve, and the value change is what triggers it.
            idlePulse = true
        }
    }

    @ViewBuilder
    private func dotView(idx: Int, stroke: StrokeDefinition, gr: CGRect, cellFrame: CGRect) -> some View {
        if let first = stroke.checkpoints.first {
            // gr is normalised 0..1 relative to `cellFrame.size`; offset by
            // cellFrame origin so word-mode (multi-cell) draws the dot in
            // the active cell instead of the canvas origin (W-24).
            let screenX = cellFrame.minX + (gr.minX + first.x * gr.width) * cellFrame.width
            let screenY = cellFrame.minY + (gr.minY + first.y * gr.height) * cellFrame.height
            let isTapped = vm.directTappedDots.contains(idx)
            let isNext   = !isTapped && idx == vm.directNextExpectedDotIndex
            let r: CGFloat = isNext ? 22 : 18
            // `.onTapGesture` must sit BEFORE `.position` — `.position` expands the
            // modified view to the full parent frame, so a gesture attached after
            // would hit-test the entire canvas. With multiple dots stacked via
            // ForEach, only the top-most (last) dot's handler would then fire for
            // every tap, leaving multi-stroke letters unable to advance.
            // Idle breathing pulse on the next-expected dot draws
            // a 5-yr-old's eye. Wrong-tap pulse layers on top via
            // pulseToggle for the louder "look here" emphasis.
            let idleScale: CGFloat = isNext && idlePulse ? 1.18 : 1.0
            let emphasisScale: CGFloat = isNext && pulseToggle ? 1.3 : idleScale
            ZStack {
                Circle()
                    .fill(isTapped ? Color.green : (isNext ? Color.blue : Color.gray))
                    .opacity(isTapped ? 0.85 : 0.80)
                    .scaleEffect(emphasisScale)
                    // Two value-keyed animations layered: the slow
                    // breathing curve drives idlePulse; the wrong-tap
                    // emphasis snaps via pulseToggle. SwiftUI honours
                    // both because each `.animation(_:value:)` is
                    // scoped to its own state key.
                    .animation(reduceMotion
                                ? nil
                                : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                               value: idlePulse)
                    .animation(reduceMotion
                                ? nil
                                : .spring(response: 0.25, dampingFraction: 0.5),
                               value: pulseToggle)
                Text("\(idx + 1)")
                    .font(.system(size: r * 0.85, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: r * 2, height: r * 2)
            .contentShape(Circle())
            .onTapGesture {
                // Wrap so the .id(idx) transition above (outgoing
                // dot scales up + fades, incoming scales in) runs.
                // The VM doesn't import SwiftUI, so the animation
                // transaction lives here at the call site.
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.35)) {
                    vm.tapDirectDot(index: idx)
                }
            }
            .position(x: screenX, y: screenY)
            .accessibilityLabel("Startpunkt \(idx + 1)")
            .accessibilityAddTraits(.isButton)
        }
    }
}

// MARK: - Unified touch overlay
// 1-finger tracing only. Letter/audio/ghost navigation moved to the visible
// world-bar controls (MainAppView / SchuleWorldView) — 2-finger pan / tap
// / 3-finger tap caused too many accidental triggers for 5-year-olds
// resting a palm on the iPad.

private struct UnifiedTouchOverlay: UIViewRepresentable {
    let canvasSize: CGSize
    let onSingleTouchBegan: (CGPoint, CFTimeInterval) -> Void
    let onSingleTouchMoved: (CGPoint, CFTimeInterval, CGSize) -> Void
    let onSingleTouchEnded: () -> Void
    let onTwoFingerSwipeUp: () -> Void
    let onTwoFingerSwipeDown: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            canvasSize:           canvasSize,
            onSingleTouchBegan:   onSingleTouchBegan,
            onSingleTouchMoved:   onSingleTouchMoved,
            onSingleTouchEnded:   onSingleTouchEnded,
            onTwoFingerSwipeUp:   onTwoFingerSwipeUp,
            onTwoFingerSwipeDown: onTwoFingerSwipeDown
        )
    }

    func makeUIView(context: Context) -> TouchView {
        let view = TouchView(coordinator: context.coordinator)
        view.backgroundColor        = .clear
        // Multi-touch on so the pan-gesture recognizer below can see the
        // second finger. The touches* handlers still gate on single-finger
        // state so tracing isn't disturbed.
        view.isMultipleTouchEnabled = true
        let pan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTwoFingerPan(_:))
        )
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        // Don't eat the 1-finger trace that may already be in progress when
        // a 2-finger swipe begins.
        pan.cancelsTouchesInView = false
        pan.delegate = context.coordinator
        view.addGestureRecognizer(pan)
        return view
    }

    func updateUIView(_ uiView: TouchView, context: Context) {
        context.coordinator.canvasSize = canvasSize
    }

    final class TouchView: UIView {
        var coordinator: Coordinator
        init(coordinator: Coordinator) {
            self.coordinator = coordinator
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            coordinator.touchesBegan(touches, with: event, in: self)
        }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            coordinator.touchesMoved(touches, with: event, in: self)
        }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            coordinator.touchesEnded(touches, with: event)
        }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            coordinator.touchesEnded(touches, with: event)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var canvasSize: CGSize
        private let onSingleTouchBegan: (CGPoint, CFTimeInterval) -> Void
        private let onSingleTouchMoved: (CGPoint, CFTimeInterval, CGSize) -> Void
        private let onSingleTouchEnded: () -> Void
        private let onTwoFingerSwipeUp: () -> Void
        private let onTwoFingerSwipeDown: () -> Void

        private weak var trackedTouch: UITouch?
        private var twoFingerSwipeFired = false

        init(canvasSize: CGSize,
             onSingleTouchBegan: @escaping (CGPoint, CFTimeInterval) -> Void,
             onSingleTouchMoved: @escaping (CGPoint, CFTimeInterval, CGSize) -> Void,
             onSingleTouchEnded: @escaping () -> Void,
             onTwoFingerSwipeUp: @escaping () -> Void,
             onTwoFingerSwipeDown: @escaping () -> Void) {
            self.canvasSize           = canvasSize
            self.onSingleTouchBegan   = onSingleTouchBegan
            self.onSingleTouchMoved   = onSingleTouchMoved
            self.onSingleTouchEnded   = onSingleTouchEnded
            self.onTwoFingerSwipeUp   = onTwoFingerSwipeUp
            self.onTwoFingerSwipeDown = onTwoFingerSwipeDown
        }

        func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?, in view: UIView) {
            let allTouches    = event?.allTouches ?? touches
            let fingerTouches = allTouches.filter { $0.type != .pencil }
            guard fingerTouches.count == 1, trackedTouch == nil else { return }
            guard let t = fingerTouches.first else { return }
            trackedTouch = t
            onSingleTouchBegan(t.location(in: view), t.timestamp)
        }

        func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?, in view: UIView) {
            guard let tracked = trackedTouch, touches.contains(tracked) else { return }
            onSingleTouchMoved(tracked.location(in: view), tracked.timestamp, canvasSize)
        }

        func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let tracked = trackedTouch, touches.contains(tracked) else { return }
            trackedTouch = nil
            onSingleTouchEnded()
        }

        @objc func handleTwoFingerPan(_ gesture: UIPanGestureRecognizer) {
            switch gesture.state {
            case .began, .possible:
                twoFingerSwipeFired = false
            case .changed:
                // Fire once per gesture as soon as the translation crosses
                // the threshold so the user gets immediate feedback without
                // having to lift fingers first.
                guard !twoFingerSwipeFired, let view = gesture.view else { return }
                let dy = gesture.translation(in: view).y
                let threshold: CGFloat = 50
                if dy < -threshold {
                    twoFingerSwipeFired = true
                    onTwoFingerSwipeUp()
                } else if dy > threshold {
                    twoFingerSwipeFired = true
                    onTwoFingerSwipeDown()
                }
            case .ended, .cancelled, .failed:
                twoFingerSwipeFired = false
            @unknown default:
                break
            }
        }

        // Let the pan recognizer coexist with the single-touch event
        // pipeline; they operate on disjoint touch counts (1 vs 2) so
        // allowing simultaneous recognition can't introduce conflicts.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

// MARK: - Apple Pencil overlay

private struct PencilAwareCanvasOverlay: UIViewRepresentable {
    let canvasSize: CGSize
    let onBegan:  (CGPoint, CFTimeInterval) -> Void
    let onMoved:  (CGPoint, CFTimeInterval, CGFloat, CGFloat, CGSize) -> Void
    let onEnded:  () -> Void
    /// U5 (ROADMAP_V5): Apple Pencil 2 squeeze handler. Replays the
    /// letter audio so a child writing one-handed can hear it again
    /// without taking the pencil off the canvas. nil on devices that
    /// don't expose `UIPencilInteraction` (older iPad mini / iPad).
    let onPencilSqueeze: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(onBegan: onBegan, onMoved: onMoved, onEnded: onEnded,
                    onPencilSqueeze: onPencilSqueeze)
    }

    func makeUIView(context: Context) -> TouchTrackingView {
        let v = TouchTrackingView()
        v.backgroundColor = .clear
        v.coordinator     = context.coordinator
        v.installPencilInteraction()
        return v
    }

    func updateUIView(_ uiView: TouchTrackingView, context: Context) {
        uiView.coordinator = context.coordinator
        uiView.canvasSize  = canvasSize
    }

    final class Coordinator: NSObject, UIPencilInteractionDelegate {
        let onBegan: (CGPoint, CFTimeInterval) -> Void
        let onMoved: (CGPoint, CFTimeInterval, CGFloat, CGFloat, CGSize) -> Void
        let onEnded: () -> Void
        let onPencilSqueeze: (() -> Void)?
        init(onBegan: @escaping (CGPoint, CFTimeInterval) -> Void,
             onMoved: @escaping (CGPoint, CFTimeInterval, CGFloat, CGFloat, CGSize) -> Void,
             onEnded: @escaping () -> Void,
             onPencilSqueeze: (() -> Void)?) {
            self.onBegan = onBegan
            self.onMoved = onMoved
            self.onEnded = onEnded
            self.onPencilSqueeze = onPencilSqueeze
        }

        // U5: legacy double-tap callback (Pencil 2 default action).
        // Mapped to the same "replay audio" intent as squeeze so users
        // on either gesture get the same outcome.
        func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
            onPencilSqueeze?()
        }
    }

    final class TouchTrackingView: UIView {
        var coordinator: Coordinator?
        var canvasSize: CGSize = .zero
        private var pencilInteraction: UIPencilInteraction?

        /// U5: lazily install a UIPencilInteraction the first time the
        /// view appears in a window. Safe to call multiple times — only
        /// the first install actually adds the interaction.
        func installPencilInteraction() {
            guard pencilInteraction == nil else { return }
            let interaction = UIPencilInteraction()
            interaction.delegate = coordinator
            addInteraction(interaction)
            pencilInteraction = interaction
        }

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            guard let touch = event?.allTouches?.first else { return nil }
            return touch.type == .pencil ? self : nil
        }

        // UIKit pencil callbacks are delivered on the main thread.
        // Direct dispatch — no DispatchQueue.main.async hop needed or wanted.
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let t = touches.first, t.type == .pencil else { return }
            coordinator?.onBegan(t.location(in: self), t.timestamp)
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let t = touches.first, t.type == .pencil else { return }
            let pressure = t.force / max(t.maximumPossibleForce, 1)
            coordinator?.onMoved(t.location(in: self), t.timestamp, pressure,
                                  t.azimuthAngle(in: self), canvasSize)
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard touches.first?.type == .pencil else { return }
            coordinator?.onEnded()
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard touches.first?.type == .pencil else { return }
            coordinator?.onEnded()
        }
    }
}
