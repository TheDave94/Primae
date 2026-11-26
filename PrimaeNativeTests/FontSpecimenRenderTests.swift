// FontSpecimenRenderTests.swift
// PrimaeNativeTests: SDK27 (2026-11-24)
//
// R-099 moved font registration to `CTFontManagerRegisterFontURLs` behind an
// async gate. A wrong move degrades every UI glyph to the system font while
// every name-based check could still be fooled by a face that resolves but
// draws nothing distinct, so this RENDERS: the same German specimen in the
// bundled Primae / PrimaeText faces and in the system font of the same size,
// and requires the pixels to differ. The PNGs are written to the app
// container (Documents/sdk27-fonts/) so a device run can be pulled with
// `xcrun devicectl device copy from` and looked at.

import Testing
import UIKit
@testable import PrimaeNative

@Suite @MainActor struct FontSpecimenRenderTests {

    static let specimen = "Aa Ff Ii Ll Mm Ää Öö Üü ß"

    static func render(_ font: UIFont) -> UIImage {
        let size = CGSize(width: 900, height: 120)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
            (specimen as NSString).draw(at: CGPoint(x: 10, y: 20),
                                        withAttributes: [.font: font, .foregroundColor: UIColor.black])
        }
    }

    /// Dark pixels per image, and how many pixels differ between the two.
    static func compare(_ a: UIImage, _ b: UIImage) -> (inkA: Int, inkB: Int, differing: Int) {
        func gray(_ img: UIImage) -> [UInt8] {
            let cg = img.cgImage!
            let w = cg.width, h = cg.height
            var px = [UInt8](repeating: 0, count: w * h)
            let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return px
        }
        let x = gray(a), y = gray(b)
        return (x.filter { $0 < 128 }.count, y.filter { $0 < 128 }.count,
                zip(x, y).filter { abs(Int($0) - Int($1)) > 64 }.count)
    }

    @Test("the registered Primae faces draw their own glyphs, not the system font's")
    func primaeFacesRenderDistinctly() async throws {
        await PrimaeFonts.registerAll()
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sdk27-fonts", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let system = UIFont.systemFont(ofSize: 64)
        try Self.render(system).pngData()?.write(to: dir.appendingPathComponent("system.png"))
        for name in ["Primae", "PrimaeText", "Primae-Cursive", "PlaywriteAT-Regular"] {
            let font = try #require(UIFont(name: name, size: 64), "\(name) did not resolve after registerAll()")
            #expect(font.fontName == name, "\(name) resolved to \(font.fontName)")
            let img = Self.render(font)
            try img.pngData()?.write(to: dir.appendingPathComponent("\(name).png"))
            let c = Self.compare(img, Self.render(system))
            print("SDK27 FONT \(name): ink=\(c.inkA) systemInk=\(c.inkB) differing=\(c.differing) dir=\(dir.path)")
            #expect(c.inkA > 1000, "\(name) drew (almost) nothing")
            #expect(c.differing > 1000, "\(name) renders like the system font")
        }
    }
}
