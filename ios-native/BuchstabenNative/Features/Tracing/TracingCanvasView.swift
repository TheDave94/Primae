import SwiftUI

struct TracingCanvasView: View {
    @EnvironmentObject private var vm: TracingViewModel

    var body: some View {
        GeometryReader { geo in
            Canvas { context, _ in
                if vm.showGhost {
                    let ghost = Path { p in
                        p.addRoundedRect(in: CGRect(x: geo.size.width * 0.25,
                                                    y: geo.size.height * 0.15,
                                                    width: geo.size.width * 0.5,
                                                    height: geo.size.height * 0.7),
                                         cornerSize: CGSize(width: 18, height: 18))
                    }
                    context.stroke(ghost, with: .color(.blue.opacity(0.18)), lineWidth: 10)
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
            .simultaneousGesture(
                MagnificationGesture(minimumScaleDelta: 0.01)
                    .onEnded { _ in vm.randomLetter() }
            )
        }
    }
}
