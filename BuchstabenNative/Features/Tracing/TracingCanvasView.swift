import SwiftUI
import UIKit

struct TracingCanvasView: View {
    @Environment(TracingViewModel.self) private var vm
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    @ViewBuilder
    private func tracingCanvas(geo: GeometryProxy) -> some View {
        Canvas { context, size in
            // Background: PBM letter bitmap (cached in VM, loaded once per letter change)
            if let img = vm.currentLetterImage {
                let uiImage = Image(uiImage: img)
                context.draw(uiImage, in: CGRect(origin: .zero, size: size))
            }

            if vm.showGhost {
                // Use the full canvas rect so the guide overlays exactly on the PBM bitmap
                let guideRect = CGRect(origin: .zero, size: size)
                if let ghost = LetterGuideRenderer.guidePath(for: vm.currentLetterName, in: guideRect) {
                    context.stroke(ghost, with: .color(.blue.opacity(0.22)), style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round))
                }
            }

            if vm.activePath.count > 1 {
                var path = Path()
                path.addLines(vm.activePath)
                let inkWidth: CGFloat = vm.pencilPressure.map { 4 + $0 * 10 } ?? 8
                context.stroke(path, with: .color(.green), style: StrokeStyle(lineWidth: inkWidth, lineCap: .round, lineJoin: .round))
            }

            let clampedProgress = max(0, min(1, vm.progress))
            let trackRect = CGRect(x: 0, y: size.height - 8, width: size.width, height: 8)
            let fillRect = CGRect(x: 0, y: size.height - 8, width: size.width * clampedProgress, height: 8)

            context.fill(Path(trackRect), with: .color(.black.opacity(0.1)))
            context.fill(Path(fillRect), with: .color(differentiateWithoutColor ? .blue : .green))
        }
        .contentShape(Rectangle())
    }

    var body: some View {
        GeometryReader { geo in
            let _ = { vm.canvasSize = geo.size }()
            ZStack(alignment: .bottomLeading) {
                tracingCanvas(geo: geo)
                    .modifier(TracingCanvasAccessibility(vm: vm))

                ProgressPill(progress: vm.progress, differentiateWithoutColor: differentiateWithoutColor)
                    .padding(.leading, 12)
                    .padding(.bottom, 16)
            }
            .overlay(
                PencilAwareCanvasOverlay(
                    canvasSize: geo.size,
                    onBegan: { pt, t in vm.beginTouch(at: pt, t: t) },
                    onMoved: { pt, t, pressure, azimuth, size in
                        vm.pencilPressure = pressure
                        vm.pencilAzimuth = azimuth
                        vm.updateTouch(at: pt, t: t, canvasSize: size)
                    },
                    onEnded: { vm.endTouch() }
                )
            )
            .overlay(
                // Single UIView handles all finger touches: 1-finger → tracing,
                // 2-finger pan → letter/audio navigation, 2-finger tap → random,
                // 3-finger tap → ghost. Using UIKit directly avoids SwiftUI
                // DragGesture stealing touches before multi-touch recognizers fire.
                UnifiedTouchOverlay(
                    canvasSize: geo.size,
                    onSingleTouchBegan: { pt, t in vm.beginTouch(at: pt, t: t) },
                    onSingleTouchMoved: { pt, t, size in vm.updateTouch(at: pt, t: t, canvasSize: size) },
                    onSingleTouchEnded: { vm.endTouch() },
                    onTwoFingerPanBegan: { vm.beginMultiTouchNavigation() },
                    onTwoFingerPanEnded: { dx, dy in
                        defer { vm.endMultiTouchNavigation() }
                        let absX = abs(dx), absY = abs(dy)
                        guard max(absX, absY) > 40 else { return }
                        if absX > absY {
                            if dx < 0 { vm.nextLetter() } else { vm.previousLetter() }
                        } else {
                            if dy < 0 { vm.nextAudioVariant() } else { vm.previousAudioVariant() }
                        }
                    },
                    onTwoFingerTap: {
                        vm.beginMultiTouchNavigation()
                        vm.randomLetter()
                        vm.endMultiTouchNavigation()
                    },
                    onThreeFingerTap: { vm.toggleGhost() }
                )
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
            .accessibilityHint("Double-tap and drag to trace. Use custom actions to navigate letters or replay audio.")
            .accessibilityActions {
                Button("Play letter sound") { vm.replayAudio() }
                Button("Next letter") { vm.nextLetter() }
                Button("Previous letter") { vm.previousLetter() }
                Button("Random letter") { vm.randomLetter() }
                Button("Reset tracing") { vm.resetLetter() }
                Button("Toggle guide overlay") { vm.toggleGhost() }
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

// MARK: - Unified touch overlay
// Handles all finger input in one UIView: 1-finger tracing via touchesBegan/Moved/Ended,
// plus 2-finger pan/tap and 3-finger tap via UIGestureRecognizers.
// This avoids the fundamental conflict where SwiftUI's DragGesture intercepts all touches
// before UIKit gesture recognizers on sibling/child views can claim them.

private struct UnifiedTouchOverlay: UIViewRepresentable {
    let canvasSize: CGSize
    let onSingleTouchBegan: (CGPoint, CFTimeInterval) -> Void
    let onSingleTouchMoved: (CGPoint, CFTimeInterval, CGSize) -> Void
    let onSingleTouchEnded: () -> Void
    let onTwoFingerPanBegan: () -> Void
    let onTwoFingerPanEnded: (CGFloat, CGFloat) -> Void
    let onTwoFingerTap: () -> Void
    let onThreeFingerTap: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            canvasSize: canvasSize,
            onSingleTouchBegan: onSingleTouchBegan,
            onSingleTouchMoved: onSingleTouchMoved,
            onSingleTouchEnded: onSingleTouchEnded,
            onTwoFingerPanBegan: onTwoFingerPanBegan,
            onTwoFingerPanEnded: onTwoFingerPanEnded,
            onTwoFingerTap: onTwoFingerTap,
            onThreeFingerTap: onThreeFingerTap
        )
    }

    func makeUIView(context: Context) -> TouchView {
        let view = TouchView(coordinator: context.coordinator)
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTwoFingerPan(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        pan.delegate = context.coordinator
        pan.cancelsTouchesInView = false
        view.addGestureRecognizer(pan)

        let twoTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTwoFingerTap(_:)))
        twoTap.numberOfTouchesRequired = 2
        twoTap.numberOfTapsRequired = 1
        twoTap.delegate = context.coordinator
        twoTap.cancelsTouchesInView = false
        view.addGestureRecognizer(twoTap)

        let threeTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleThreeFingerTap(_:)))
        threeTap.numberOfTouchesRequired = 3
        threeTap.numberOfTapsRequired = 1
        threeTap.delegate = context.coordinator
        threeTap.cancelsTouchesInView = false
        view.addGestureRecognizer(threeTap)

        twoTap.require(toFail: pan)

        return view
    }

    func updateUIView(_ uiView: TouchView, context: Context) {
        context.coordinator.canvasSize = canvasSize
    }

    // Full-coverage UIView — owns all touches (finger + Apple Pencil exclusion handled in Coordinator)
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
        private let onTwoFingerPanBegan: () -> Void
        private let onTwoFingerPanEnded: (CGFloat, CGFloat) -> Void
        private let onTwoFingerTap: () -> Void
        private let onThreeFingerTap: () -> Void

        // Track active single-finger touch identity
        private weak var trackedTouch: UITouch?

        init(canvasSize: CGSize,
             onSingleTouchBegan: @escaping (CGPoint, CFTimeInterval) -> Void,
             onSingleTouchMoved: @escaping (CGPoint, CFTimeInterval, CGSize) -> Void,
             onSingleTouchEnded: @escaping () -> Void,
             onTwoFingerPanBegan: @escaping () -> Void,
             onTwoFingerPanEnded: @escaping (CGFloat, CGFloat) -> Void,
             onTwoFingerTap: @escaping () -> Void,
             onThreeFingerTap: @escaping () -> Void) {
            self.canvasSize = canvasSize
            self.onSingleTouchBegan = onSingleTouchBegan
            self.onSingleTouchMoved = onSingleTouchMoved
            self.onSingleTouchEnded = onSingleTouchEnded
            self.onTwoFingerPanBegan = onTwoFingerPanBegan
            self.onTwoFingerPanEnded = onTwoFingerPanEnded
            self.onTwoFingerTap = onTwoFingerTap
            self.onThreeFingerTap = onThreeFingerTap
        }

        func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?, in view: UIView) {
            let allTouches = event?.allTouches ?? touches
            // Ignore pencil — handled by PencilAwareCanvasOverlay
            let fingerTouches = allTouches.filter { $0.type != .pencil }
            guard fingerTouches.count == 1, trackedTouch == nil else { return }
            guard let t = fingerTouches.first else { return }
            trackedTouch = t
            let pt = t.location(in: view)
            onSingleTouchBegan(pt, t.timestamp)
        }

        func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?, in view: UIView) {
            guard let tracked = trackedTouch, touches.contains(tracked) else { return }
            let pt = tracked.location(in: view)
            onSingleTouchMoved(pt, tracked.timestamp, canvasSize)
        }

        func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let tracked = trackedTouch, touches.contains(tracked) else { return }
            trackedTouch = nil
            onSingleTouchEnded()
        }

        // MARK: Gesture recognizer handlers

        @objc func handleTwoFingerPan(_ recognizer: UIPanGestureRecognizer) {
            switch recognizer.state {
            case .began:
                trackedTouch = nil  // cancel any active single-touch tracing
                onSingleTouchEnded()
                onTwoFingerPanBegan()
            case .ended, .cancelled, .failed:
                let t = recognizer.translation(in: recognizer.view)
                onTwoFingerPanEnded(t.x, t.y)
            default:
                break
            }
        }

        @objc func handleTwoFingerTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            onTwoFingerTap()
        }

        @objc func handleThreeFingerTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            onThreeFingerTap()
        }

        // Allow simultaneous recognition so pan + tap failure requirement works cleanly
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}

// MARK: - Apple Pencil overlay

private struct PencilAwareCanvasOverlay: UIViewRepresentable {
    let canvasSize: CGSize
    let onBegan: (CGPoint, CFTimeInterval) -> Void
    let onMoved: (CGPoint, CFTimeInterval, CGFloat, CGFloat, CGSize) -> Void
    let onEnded: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onBegan: onBegan, onMoved: onMoved, onEnded: onEnded) }

    func makeUIView(context: Context) -> TouchTrackingView {
        let v = TouchTrackingView()
        v.backgroundColor = .clear
        v.coordinator = context.coordinator
        return v
    }

    func updateUIView(_ uiView: TouchTrackingView, context: Context) {
        uiView.coordinator = context.coordinator
        uiView.canvasSize = canvasSize
    }

    final class Coordinator {
        let onBegan: (CGPoint, CFTimeInterval) -> Void
        let onMoved: (CGPoint, CFTimeInterval, CGFloat, CGFloat, CGSize) -> Void
        let onEnded: () -> Void
        init(
            onBegan: @escaping (CGPoint, CFTimeInterval) -> Void,
            onMoved: @escaping (CGPoint, CFTimeInterval, CGFloat, CGFloat, CGSize) -> Void,
            onEnded: @escaping () -> Void
        ) { self.onBegan = onBegan; self.onMoved = onMoved; self.onEnded = onEnded }
    }

    final class TouchTrackingView: UIView {
        var coordinator: Coordinator?
        var canvasSize: CGSize = .zero

        // Only intercept pencil; fingers fall through to SwiftUI DragGesture
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            guard let touch = event?.allTouches?.first else { return nil }
            return touch.type == .pencil ? self : nil
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let t = touches.first, t.type == .pencil else { return }
            let loc = t.location(in: self); let ts = t.timestamp
            DispatchQueue.main.async { self.coordinator?.onBegan(loc, ts) }
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let t = touches.first, t.type == .pencil else { return }
            let loc = t.location(in: self); let ts = t.timestamp
            let pressure = t.force / max(t.maximumPossibleForce, 1)
            let azimuth = t.azimuthAngle(in: self)
            let size = canvasSize
            DispatchQueue.main.async { self.coordinator?.onMoved(loc, ts, pressure, azimuth, size) }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard touches.first?.type == .pencil else { return }
            DispatchQueue.main.async { self.coordinator?.onEnded() }
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard touches.first?.type == .pencil else { return }
            DispatchQueue.main.async { self.coordinator?.onEnded() }
        }
    }
}
