import SwiftUI
import UIKit
import CoreText

struct TracingCanvasView: View {
    @Environment(TracingViewModel.self) private var vm
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    @ViewBuilder
    private func tracingCanvas(geo: GeometryProxy) -> some View {
        Canvas { context, size in
            // Background: PBM letter bitmap (cached in VM, loaded once per letter change)
            if let img = vm.currentLetterImage {
                context.draw(Image(uiImage: img), in: CGRect(origin: .zero, size: size))
            }

            // Ghost scaffolding: phase drives default visibility (observe/guided = on,
            // freeWrite = off). User's showGhost toggle can ADD ghost in observe/guided,
            // but cannot re-enable it in freeWrite (scaffolding is withdrawn per GRRM).
            if (vm.showGhostForPhase || (vm.showGhost && vm.learningPhase != .freeWrite)),
               let rawStrokes = vm.glyphRelativeStrokes,
               !rawStrokes.strokes.isEmpty,
               let gr = PrimaeLetterRenderer.normalizedGlyphRect(for: vm.currentLetterName, canvasSize: size, schriftArt: vm.schriftArt) {
                // Ghost lines from stroke JSON — same data as dots, guaranteed alignment.
                for stroke in rawStrokes.strokes {
                    guard stroke.checkpoints.count >= 2 else { continue }
                    var ghostPath = Path()
                    let first = stroke.checkpoints[0]
                    ghostPath.move(to: CGPoint(
                        x: (gr.minX + first.x * gr.width) * size.width,
                        y: (gr.minY + first.y * gr.height) * size.height))
                    for cp in stroke.checkpoints.dropFirst() {
                        ghostPath.addLine(to: CGPoint(
                            x: (gr.minX + cp.x * gr.width) * size.width,
                            y: (gr.minY + cp.y * gr.height) * size.height))
                    }
                    context.stroke(ghostPath, with: .color(.blue.opacity(0.35)),
                                   style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                }
            }

            // Stroke start dots — use phaseController.showCheckpoints (single source
            // of truth for phase scaffolding) instead of duplicating the rule here.
            if vm.showCheckpoints,
               let rawStrokes = vm.rawGlyphStrokes,
               !rawStrokes.strokes.isEmpty,
               let gr = PrimaeLetterRenderer.normalizedGlyphRect(
                   for: vm.currentLetterName, canvasSize: size, schriftArt: vm.schriftArt) {
                for (idx, stroke) in rawStrokes.strokes.enumerated() {
                    guard let first = stroke.checkpoints.first else { continue }
                    let isComplete = vm.isStrokeCompleted(idx)
                    let isActive = vm.activeStrokeIndex == idx
                    let screenX = (gr.minX + first.x * gr.width) * size.width
                    let screenY = (gr.minY + first.y * gr.height) * size.height
                    let pt = CGPoint(x: screenX, y: screenY)
                    let r: CGFloat = isActive ? 18 : 14
                    let dotRect = CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)
                    let dot = Path(ellipseIn: dotRect)
                    let color: Color = isComplete ? .green : (isActive ? .blue : .gray)
                    context.fill(dot, with: .color(color.opacity(0.75)))
                }
            }

            if vm.activePath.count > 1 {
                var path = Path()
                path.addLines(vm.activePath)
                let inkWidth: CGFloat = vm.pencilPressure.map { 4 + $0 * 10 } ?? 8
                context.stroke(path, with: .color(.green),
                               style: StrokeStyle(lineWidth: inkWidth, lineCap: .round, lineJoin: .round))
            }

            // Animation guide dot — glyph-relative coords mapped to screen
            if let point = vm.animationGuidePoint,
               let gr = PrimaeLetterRenderer.normalizedGlyphRect(for: vm.currentLetterName, canvasSize: size, schriftArt: vm.schriftArt) {
                let screenPt = CGPoint(
                    x: (gr.minX + point.x * gr.width) * size.width,
                    y: (gr.minY + point.y * gr.height) * size.height)
                let r: CGFloat = 22
                let dotRect   = CGRect(x: screenPt.x - r, y: screenPt.y - r, width: r * 2, height: r * 2)
                let dot       = Path(ellipseIn: dotRect)
                context.fill(dot,   with: .color(.blue.opacity(0.75)))
                context.stroke(dot, with: .color(.white.opacity(0.60)), lineWidth: 2)
            }

            // Directional arrow — direct phase: shown briefly after a correct dot tap
            if let arrowIdx = vm.directArrowStrokeIndex,
               let rawStrokes = vm.rawGlyphStrokes,
               arrowIdx < rawStrokes.strokes.count,
               rawStrokes.strokes[arrowIdx].checkpoints.count >= 2,
               let gr = PrimaeLetterRenderer.normalizedGlyphRect(
                   for: vm.currentLetterName, canvasSize: size, schriftArt: vm.schriftArt) {
                let stroke = rawStrokes.strokes[arrowIdx]
                let c0 = stroke.checkpoints[0]
                let c1 = stroke.checkpoints[1]
                let from = CGPoint(x: (gr.minX + c0.x * gr.width) * size.width,
                                   y: (gr.minY + c0.y * gr.height) * size.height)
                let to   = CGPoint(x: (gr.minX + c1.x * gr.width) * size.width,
                                   y: (gr.minY + c1.y * gr.height) * size.height)
                var linePath = Path()
                linePath.move(to: from)
                linePath.addLine(to: to)
                context.stroke(linePath, with: .color(.orange.opacity(0.9)),
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
                context.stroke(headPath, with: .color(.orange.opacity(0.9)),
                               style: StrokeStyle(lineWidth: 5, lineCap: .round))
            }

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
                    context.stroke(refPath, with: .color(.blue.opacity(0.4)),
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
                context.stroke(childPath, with: .color(.green),
                               style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
        }
        .background(.black.opacity(0.15))
        .contentShape(Rectangle())
        .onTapGesture { vm.showFreeWriteOverlay = false }
        .task {
            try? await Task.sleep(for: .seconds(3))
            vm.showFreeWriteOverlay = false
        }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                tracingCanvas(geo: geo)
                    .modifier(TracingCanvasAccessibility(vm: vm))

                ProgressPill(progress: vm.progress,
                             differentiateWithoutColor: differentiateWithoutColor)
                    .padding(.leading, 12)
                    .padding(.bottom, 16)
            }
            .onAppear { vm.canvasSize = geo.size }
            .onChange(of: geo.size) { _, newSize in vm.canvasSize = newSize }
            .overlay(
                PencilAwareCanvasOverlay(
                    canvasSize: geo.size,
                    onBegan:  { pt, t in vm.beginTouch(at: pt, t: t) },
                    onMoved:  { pt, t, pressure, azimuth, size in
                        vm.pencilPressure = pressure
                        vm.pencilAzimuth  = azimuth
                        vm.updateTouch(at: pt, t: t, canvasSize: size)
                    },
                    onEnded:  { vm.endTouch() }
                )
            )
            .overlay(
                // Finger tracing only: 1-finger → trace. Letter / audio / ghost
                // navigation routed through visible dock buttons in ContentView
                // to avoid accidental palm-rest triggers for 5-year-olds.
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
                    onSingleTouchBegan:  { pt, t in vm.beginTouch(at: pt, t: t) },
                    onSingleTouchMoved:  { pt, t, size in vm.updateTouch(at: pt, t: t, canvasSize: size) },
                    onSingleTouchEnded:  { vm.endTouch() }
                )
                .allowsHitTesting(vm.learningPhase != .direct)
            )
            .overlay(
                Group {
                    if vm.learningPhase == .direct {
                        DirectPhaseDotsOverlay()
                    }
                }
            )
            .overlay(
                Group {
                    if vm.showFreeWriteOverlay {
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

private struct ProgressPill: View {
    let progress: CGFloat
    let differentiateWithoutColor: Bool

    var body: some View {
        Text("Fortschritt \(Int(max(0, min(1, progress)) * 100))%")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .stroke((differentiateWithoutColor ? Color.blue : Color.green).opacity(0.5), lineWidth: 1)
            )
            .accessibilityHidden(true)
    }
}

// MARK: - Direct phase dot overlay

/// Renders numbered start-dot circles for the direct phase and routes taps to the VM.
/// Sits above the touch overlays so SwiftUI tap gestures win over the tracing handler.
private struct DirectPhaseDotsOverlay: View {
    @Environment(TracingViewModel.self) private var vm
    @State private var pulseToggle = false

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
                if let rawStrokes = vm.rawGlyphStrokes,
                   !rawStrokes.strokes.isEmpty,
                   vm.directNextExpectedDotIndex < rawStrokes.strokes.count,
                   let gr = PrimaeLetterRenderer.normalizedGlyphRect(
                       for: vm.currentLetterName,
                       canvasSize: geo.size,
                       schriftArt: vm.schriftArt) {
                    let idx = vm.directNextExpectedDotIndex
                    dotView(idx: idx, stroke: rawStrokes.strokes[idx], gr: gr, size: geo.size)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: vm.directPulsingDot) { _, isPulsing in
            guard isPulsing else { pulseToggle = false; return }
            withAnimation(.easeInOut(duration: 0.25).repeatCount(3, autoreverses: true)) {
                pulseToggle = true
            }
            Task {
                try? await Task.sleep(for: .milliseconds(800))
                pulseToggle = false
            }
        }
    }

    @ViewBuilder
    private func dotView(idx: Int, stroke: StrokeDefinition, gr: CGRect, size: CGSize) -> some View {
        if let first = stroke.checkpoints.first {
            let screenX = (gr.minX + first.x * gr.width) * size.width
            let screenY = (gr.minY + first.y * gr.height) * size.height
            let isTapped = vm.directTappedDots.contains(idx)
            let isNext   = !isTapped && idx == vm.directNextExpectedDotIndex
            let r: CGFloat = isNext ? 22 : 18
            // `.onTapGesture` must sit BEFORE `.position` — `.position` expands the
            // modified view to the full parent frame, so a gesture attached after
            // would hit-test the entire canvas. With multiple dots stacked via
            // ForEach, only the top-most (last) dot's handler would then fire for
            // every tap, leaving multi-stroke letters unable to advance.
            ZStack {
                Circle()
                    .fill(isTapped ? Color.green : (isNext ? Color.blue : Color.gray))
                    .opacity(isTapped ? 0.85 : 0.80)
                    .scaleEffect(isNext && pulseToggle ? 1.3 : 1.0)
                    .animation(.spring(response: 0.25, dampingFraction: 0.5), value: pulseToggle)
                Text("\(idx + 1)")
                    .font(.system(size: r * 0.85, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: r * 2, height: r * 2)
            .contentShape(Circle())
            .onTapGesture { vm.tapDirectDot(index: idx) }
            .position(x: screenX, y: screenY)
            .accessibilityLabel("Startpunkt \(idx + 1)")
            .accessibilityAddTraits(.isButton)
        }
    }
}

// MARK: - Unified touch overlay
// 1-finger tracing only. Letter/audio/ghost navigation moved to the visible
// control dock in ContentView — 2-finger pan / tap / 3-finger tap caused too
// many accidental triggers for 5-year-olds resting a palm on the iPad.

private struct UnifiedTouchOverlay: UIViewRepresentable {
    let canvasSize: CGSize
    let onSingleTouchBegan: (CGPoint, CFTimeInterval) -> Void
    let onSingleTouchMoved: (CGPoint, CFTimeInterval, CGSize) -> Void
    let onSingleTouchEnded: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            canvasSize:         canvasSize,
            onSingleTouchBegan: onSingleTouchBegan,
            onSingleTouchMoved: onSingleTouchMoved,
            onSingleTouchEnded: onSingleTouchEnded
        )
    }

    func makeUIView(context: Context) -> TouchView {
        let view = TouchView(coordinator: context.coordinator)
        view.backgroundColor        = .clear
        view.isMultipleTouchEnabled = false
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

    final class Coordinator: NSObject {
        var canvasSize: CGSize
        private let onSingleTouchBegan: (CGPoint, CFTimeInterval) -> Void
        private let onSingleTouchMoved: (CGPoint, CFTimeInterval, CGSize) -> Void
        private let onSingleTouchEnded: () -> Void

        private weak var trackedTouch: UITouch?

        init(canvasSize: CGSize,
             onSingleTouchBegan: @escaping (CGPoint, CFTimeInterval) -> Void,
             onSingleTouchMoved: @escaping (CGPoint, CFTimeInterval, CGSize) -> Void,
             onSingleTouchEnded: @escaping () -> Void) {
            self.canvasSize         = canvasSize
            self.onSingleTouchBegan = onSingleTouchBegan
            self.onSingleTouchMoved = onSingleTouchMoved
            self.onSingleTouchEnded = onSingleTouchEnded
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
    }
}

// MARK: - Apple Pencil overlay

private struct PencilAwareCanvasOverlay: UIViewRepresentable {
    let canvasSize: CGSize
    let onBegan:  (CGPoint, CFTimeInterval) -> Void
    let onMoved:  (CGPoint, CFTimeInterval, CGFloat, CGFloat, CGSize) -> Void
    let onEnded:  () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onBegan: onBegan, onMoved: onMoved, onEnded: onEnded)
    }

    func makeUIView(context: Context) -> TouchTrackingView {
        let v = TouchTrackingView()
        v.backgroundColor = .clear
        v.coordinator     = context.coordinator
        return v
    }

    func updateUIView(_ uiView: TouchTrackingView, context: Context) {
        uiView.coordinator = context.coordinator
        uiView.canvasSize  = canvasSize
    }

    final class Coordinator {
        let onBegan: (CGPoint, CFTimeInterval) -> Void
        let onMoved: (CGPoint, CFTimeInterval, CGFloat, CGFloat, CGSize) -> Void
        let onEnded: () -> Void
        init(onBegan: @escaping (CGPoint, CFTimeInterval) -> Void,
             onMoved: @escaping (CGPoint, CFTimeInterval, CGFloat, CGFloat, CGSize) -> Void,
             onEnded: @escaping () -> Void) {
            self.onBegan = onBegan
            self.onMoved = onMoved
            self.onEnded = onEnded
        }
    }

    final class TouchTrackingView: UIView {
        var coordinator: Coordinator?
        var canvasSize: CGSize = .zero

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
