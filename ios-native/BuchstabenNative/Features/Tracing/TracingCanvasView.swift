import SwiftUI
import UIKit

struct TracingCanvasView: View {
    @EnvironmentObject private var vm: TracingViewModel

    var body: some View {
        GeometryReader { geo in
            ZStack {
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
                        context.stroke(path, with: .color(.green), lineWidth: 8)
                    }

                    let bar = CGRect(x: 0,
                                     y: geo.size.height - 8,
                                     width: geo.size.width * vm.progress,
                                     height: 8)
                    context.fill(Path(bar), with: .color(.green))
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
            }
        }
    }
}

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
