import Testing
import SwiftUI
import UIKit
@testable import PrimaeNative

/// Audit 2026-11-15 A-1: from protocol r23 every ink stroke sits on a
/// paper-coloured casing. Drawn stroke by stroke, a later stroke's casing
/// painted over the ink of an earlier one where the two met, so while a
/// child wrote a freeWrite stroke (drawn first, under the completed ones)
/// it vanished at A's crossbar, F's arms and L's foot until the pen lifted.
/// `TracingCanvasView.drawInk` draws every casing before any ink.
///
/// This renders the REAL function into a fixed-size `Canvas` with no
/// `GeometryReader` (CLAUDE.md, Test Infrastructure 4: the GeometryReader is
/// what kept `ImageRenderer` from drawing the whole canvas) and samples
/// pixels, with two controls so a blank or an all-dark raster cannot pass.
@MainActor
@Suite("ink layers: a casing never covers ink")
struct InkLayerOrderTests {

    private static let size = CGSize(width: 200, height: 200)
    private static let width: CGFloat = 10

    /// The live stroke first (horizontal), a completed stroke after it
    /// (vertical), the order the canvas collects them in.
    private static func crossingLayers() -> [TracingCanvasView.InkLayer] {
        var live = Path()
        live.move(to: CGPoint(x: 20, y: 100)); live.addLine(to: CGPoint(x: 180, y: 100))
        var done = Path()
        done.move(to: CGPoint(x: 100, y: 20)); done.addLine(to: CGPoint(x: 100, y: 180))
        return [.init(path: live, color: .black, width: width),
                .init(path: done, color: .black, width: width)]
    }

    private func render(_ layers: [TracingCanvasView.InkLayer],
                        dumpAs name: String) -> (Int, Int) -> (Int, Int, Int) {
        let view = Canvas { context, _ in
            TracingCanvasView.drawInk(layers, in: &context)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Color.white)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let cg = renderer.cgImage!
        // Kept for a human look: copy off the device from the app's tmp/.
        if let data = UIImage(cgImage: cg).pngData() {
            try? data.write(to: FileManager.default.temporaryDirectory.appendingPathComponent(name))
        }
        let w = cg.width, h = cg.height
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &buffer, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return { x, y in
            // A bitmap context's first row in memory is the image's top row.
            let i = (y * w + x) * 4
            return (Int(buffer[i]), Int(buffer[i + 1]), Int(buffer[i + 2]))
        }
    }

    private static func isInk(_ p: (Int, Int, Int)) -> Bool { p.0 < 80 && p.1 < 80 && p.2 < 80 }

    @Test("the earlier stroke keeps its ink inside the later stroke's casing band")
    func earlierInkSurvivesLaterCasing() {
        let pixel = render(Self.crossingLayers(), dumpAs: "ink-layer-order.png")
        // Controls: the earlier stroke's ink away from the crossing, and the
        // later stroke's casing band where no ink is (casing is drawn and
        // is not dark). Without both, a dark or a blank raster would pass.
        #expect(Self.isInk(pixel(40, 100)), "control: earlier ink away from the crossing \(pixel(40, 100))")
        #expect(!Self.isInk(pixel(107, 140)), "control: a casing band alone is not ink \(pixel(107, 140))")
        // x = 100 + 5 (half width) + 2: inside the vertical stroke's 3 pt
        // casing, on the horizontal stroke's ink.
        #expect(Self.isInk(pixel(107, 100)), "casing of the later stroke covered the earlier ink \(pixel(107, 100))")
        #expect(Self.isInk(pixel(93, 100)), "casing of the later stroke covered the earlier ink \(pixel(93, 100))")
    }
}
