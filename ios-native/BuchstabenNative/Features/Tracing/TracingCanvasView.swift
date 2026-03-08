import SwiftUI
import UIKit

struct TracingCanvasView: View {
    @EnvironmentObject private var vm: TracingViewModel
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                Canvas { context, _ in
                    if vm.showGhost {
                        let guideRect = CGRect(x: geo.size.width * 0.14,
                                               y: geo.size.height * 0.1,
                                               width: geo.size.width * 0.72,
                                               height: geo.size.height * 0.8)
                        if let ghost = LetterGuideRenderer.guidePath(for: vm.currentLetterName, in: guideRect) {
                            context.stroke(ghost, with: .color(.blue.opacity(0.22)), style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round))
                        }
                    }

                    if vm.activePath.count > 1 {
                        var path = Path()
                        path.addLines(vm.activePath)
                        // Pencil pressure maps linearly: 4 pt @ 0.0 … 14 pt @ 1.0; finger defaults to 8 pt
                        let inkWidth: CGFloat
                        if let pressure = vm.pencilPressure {
                            inkWidth = 4 + pressure * 10
                        } else {
                            inkWidth = 8
                        }
                        context.stroke(path, with: .color(.green), style: StrokeStyle(lineWidth: inkWidth, lineCap: .round, lineJoin: .round))
                    }

                    let clampedProgress = max(0, min(1, vm.progress))
                    let trackRect = CGRect(x: 0, y: geo.size.height - 8, width: geo.size.width, height: 8)
                    let fillRect = CGRect(x: 0, y: geo.size.height - 8, width: geo.size.width * clampedProgress, height: 8)

                    context.fill(Path(trackRect), with: .color(.black.opacity(0.1)))
                    context.fill(Path(fillRect), with: .color(differentiateWithoutColor ? .blue : .green))
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if vm.activePath.isEmpty {
                                vm.beginTouch(at: value.location, t: CACurrentMediaTime())
                            }
                            vm.updateTouch(at: value.location,
                                           t: CACurrentMediaTime(),
                                           canvasSize: geo.size)
                        }
                        .onEnded { _ in vm.endTouch() }
                )
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(vm.accessibilityCanvasLabel)
                .accessibilityValue(vm.accessibilityCanvasValue)
                .accessibilityHint("Double-tap and drag to trace. Use custom actions to navigate letters or replay audio.")
                .accessibilityCustomAction(named: "Play letter sound") {
                    vm.replayAudio()
                    return true
                }
                .accessibilityCustomAction(named: "Next letter") {
                    vm.nextLetter()
                    return true
                }
                .accessibilityCustomAction(named: "Previous letter") {
                    vm.previousLetter()
                    return true
                }
                .accessibilityCustomAction(named: "Random letter") {
                    vm.randomLetter()
                    return true
                }
                .accessibilityCustomAction(named: "Reset tracing") {
                    vm.resetLetter()
                    return true
                }
                .accessibilityCustomAction(named: "Toggle guide overlay") {
                    vm.toggleGhost()
                    return true
                }

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
                .allowsHitTesting(true)
            )
            .overlay(
                MultiTouchGestureOverlay(
                    onTwoFingerPanBegan: { vm.beginMultiTouchNavigation() },
                    onTwoFingerPanEnded: { dx, dy in
                        defer { vm.endMultiTouchNavigation() }
                        let absX = abs(dx)
                        let absY = abs(dy)
                        let threshold: CGFloat = 40

                        guard max(absX, absY) > threshold else { return }
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
                .allowsHitTesting(true)
            )
        }
    }
}

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

// MARK: - Apple Pencil overlay

/// Transparent UIView overlay that intercepts Apple Pencil touches and
/// forwards force/tilt via callbacks. Finger touches are ignored here so
/// SwiftUI's DragGesture handles them unmodified.
private struct PencilAwareCanvasOverlay: UIViewRepresentable {
    let canvasSize: CGSize
    let onBegan: @MainActor (CGPoint, CFTimeInterval) -> Void
    let onMoved: @MainActor (CGPoint, CFTimeInterval, CGFloat, CGFloat, CGSize) -> Void
    let onEnded: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onBegan: onBegan, onMoved: onMoved, onEnded: onEnded)
    }

    func makeUIView(context: Context) -> TouchTrackingView {
        let view = TouchTrackingView()
        view.backgroundColor = .clear
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: TouchTrackingView, context: Context) {
        uiView.coordinator = context.coordinator
        uiView.canvasSize = canvasSize
    }

    final class Coordinator {
        let onBegan: @MainActor (CGPoint, CFTimeInterval) -> Void
        let onMoved: @MainActor (CGPoint, CFTimeInterval, CGFloat, CGFloat, CGSize) -> Void
        let onEnded: @MainActor () -> Void
        init(
            onBegan: @escaping @MainActor (CGPoint, CFTimeInterval) -> Void,
            onMoved: @escaping @MainActor (CGPoint, CFTimeInterval, CGFloat, CGFloat, CGSize) -> Void,
            onEnded: @escaping @MainActor () -> Void
        ) {
            self.onBegan = onBegan
            self.onMoved = onMoved
            self.onEnded = onEnded
        }
    }

    final class TouchTrackingView: UIView {
        var coordinator: Coordinator?
        var canvasSize: CGSize = .zero

        // Only intercept Apple Pencil touches; let fingers fall through to SwiftUI
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            guard let touch = event?.allTouches?.first else { return nil }
            return touch.type == .pencil ? self : nil
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let touch = touches.first, touch.type == .pencil else { return }
            let loc = touch.location(in: self); let ts = touch.timestamp
            let cb = coordinator?.onBegan
            Task { @MainActor in cb?(loc, ts) }
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let touch = touches.first, touch.type == .pencil else { return }
            let loc = touch.location(in: self); let ts = touch.timestamp
            let pressure = touch.force / max(touch.maximumPossibleForce, 1)
            let azimuth = touch.azimuthAngle(in: self)
            let size = canvasSize
            let cb = coordinator?.onMoved
            Task { @MainActor in cb?(loc, ts, pressure, azimuth, size) }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard touches.first?.type == .pencil else { return }
            let cb = coordinator?.onEnded
            Task { @MainActor in cb?() }
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard touches.first?.type == .pencil else { return }
            let cb = coordinator?.onEnded
            Task { @MainActor in cb?() }
        }
    }
}

// MARK: - Multi-touch gesture overlay

private struct MultiTouchGestureOverlay: UIViewRepresentable {
    let onTwoFingerPanBegan: () -> Void
    let onTwoFingerPanEnded: (CGFloat, CGFloat) -> Void
    let onTwoFingerTap: () -> Void
    let onThreeFingerTap: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onTwoFingerPanBegan: onTwoFingerPanBegan,
            onTwoFingerPanEnded: onTwoFingerPanEnded,
            onTwoFingerTap: onTwoFingerTap,
            onThreeFingerTap: onThreeFingerTap
        )
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear

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

    func updateUIView(_ uiView: UIView, context: Context) {}

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private let onTwoFingerPanBegan: () -> Void
        private let onTwoFingerPanEnded: (CGFloat, CGFloat) -> Void
        private let onTwoFingerTap: () -> Void
        private let onThreeFingerTap: () -> Void

        init(
            onTwoFingerPanBegan: @escaping () -> Void,
            onTwoFingerPanEnded: @escaping (CGFloat, CGFloat) -> Void,
            onTwoFingerTap: @escaping () -> Void,
            onThreeFingerTap: @escaping () -> Void
        ) {
            self.onTwoFingerPanBegan = onTwoFingerPanBegan
            self.onTwoFingerPanEnded = onTwoFingerPanEnded
            self.onTwoFingerTap = onTwoFingerTap
            self.onThreeFingerTap = onThreeFingerTap
        }

        @objc func handleTwoFingerPan(_ recognizer: UIPanGestureRecognizer) {
            switch recognizer.state {
            case .began:
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

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

