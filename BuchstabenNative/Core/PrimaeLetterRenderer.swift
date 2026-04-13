import UIKit
import CoreText
import CoreGraphics

/// Renders a single letter using the Primae-Regular OTF font into a UIImage.
/// Produces the same dark-gray-on-transparent style as PBMLoader.
/// Results are cached by letter+size to avoid redundant renders.
/// Cache is capped at 52 entries (26 letters × 2 common display sizes) to
/// prevent unbounded memory growth across letter/layout changes.
@MainActor
public enum PrimaeLetterRenderer {

    // MARK: - Cache

    private struct CacheKey: Hashable {
        let letter: String
        let width:  Int
        let height: Int
    }

    private static var cache: [CacheKey: UIImage] = [:]
    private static let cacheLimit = 52

    // MARK: - Public API

    public static func render(letter: String, size: CGSize) -> UIImage? {
        guard size.width > 0, size.height > 0, !letter.isEmpty else { return nil }
        // Skip font rendering in test environments to avoid CGDataProvider hangs
        guard !isRunningTests else { return nil }
        let key = CacheKey(letter: letter, width: Int(size.width), height: Int(size.height))
        if let cached = cache[key] { return cached }
        guard let image = draw(letter: letter, size: size) else { return nil }
        // Evict entire cache when full rather than an LRU walk — letters rarely
        // change and the next render repopulates the one entry that matters.
        if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
        cache[key] = image
        return image
    }

    public static func clearCache() {
        cache.removeAll()
    }

    // MARK: - Private

    private static var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil
    }

    private static func makeFont(size: CGFloat) -> CTFont? {
        let bundles: [Bundle] = [.module, .main]
        for bundle in bundles {
            guard let url          = bundle.url(forResource: "Primae-Regular", withExtension: "otf"),
                  let dataProvider = CGDataProvider(url: url as CFURL),
                  let cgFont       = CGFont(dataProvider) else { continue }
            return CTFontCreateWithGraphicsFont(cgFont, size, nil, nil)
        }
        return nil
    }

    private static func getGlyph(for letter: String, in font: CTFont) -> CGGlyph? {
        guard let first = letter.unicodeScalars.first else { return nil }
        var c = UniChar(first.value & 0xFFFF)
        var g = CGGlyph(0)
        guard CTFontGetGlyphsForCharacters(font, &c, &g, 1), g != 0 else { return nil }
        return g
    }

    private static func draw(letter: String, size: CGSize) -> UIImage? {
        let scale: CGFloat = 2.0
        let px = CGSize(width: size.width * scale, height: size.height * scale)

        // Probe at large size to compute scale factor
        let probe: CGFloat = 800
        guard let probeFont = makeFont(size: probe),
              var probeGlyph = getGlyph(for: letter, in: probeFont) else { return nil }

        let probeBBox = CTFontGetBoundingRectsForGlyphs(probeFont, .default, &probeGlyph, nil, 1)
        guard probeBBox.width > 0, probeBBox.height > 0 else { return nil }

        let pad: CGFloat = 0.10
        let availW    = px.width  * (1 - 2 * pad)
        let availH    = px.height * (1 - 2 * pad)
        let finalSize = probe * min(availW / probeBBox.width, availH / probeBBox.height)

        guard let font = makeFont(size: finalSize),
              var glyph = getGlyph(for: letter, in: font) else { return nil }

        let bbox = CTFontGetBoundingRectsForGlyphs(font, .default, &glyph, nil, 1)
        guard bbox.width > 0, bbox.height > 0 else { return nil }

        let offsetX = (px.width  - bbox.width)  / 2 - bbox.minX
        let offsetY = (px.height - bbox.height) / 2 - bbox.minY

        guard let ctx = CGContext(
            data: nil,
            width: Int(px.width), height: Int(px.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).rawValue
        ) else { return nil }

        ctx.clear(CGRect(origin: .zero, size: px))
        ctx.setFillColor(UIColor(red: 30/255, green: 30/255, blue: 30/255, alpha: 200/255).cgColor)
        ctx.translateBy(x: offsetX, y: offsetY)

        guard let path = CTFontCreatePathForGlyph(font, glyph, nil) else { return nil }
        ctx.addPath(path)
        ctx.fillPath()

        guard let cgImage = ctx.makeImage() else { return nil }
        return UIImage(cgImage: cgImage, scale: scale, orientation: .up)
    }
}
