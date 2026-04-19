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

    private struct RectCacheKey: Hashable {
        let letter:     String
        let width:      Int
        let height:     Int
        let schriftArt: SchriftArt
    }

    private static var cache: [CacheKey: UIImage] = [:]
    private static var rectCache: [RectCacheKey: CGRect] = [:]
    private static let cacheLimit = 52

    // MARK: - Public API

    public static func render(letter: String, size: CGSize, schriftArt: SchriftArt = .druckschrift) -> UIImage? {
        guard size.width > 0, size.height > 0, !letter.isEmpty else { return nil }
        // Skip font rendering in test environments to avoid CGDataProvider hangs
        guard !isRunningTests else { return nil }
        let key = CacheKey(letter: letter, width: Int(size.width), height: Int(size.height))
        if let cached = cache[key] { return cached }
        guard let image = draw(letter: letter, size: size, fontName: schriftArt.fontFileName) else { return nil }
        // Evict entire cache when full rather than an LRU walk — letters rarely
        // change and the next render repopulates the one entry that matters.
        if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
        cache[key] = image
        return image
    }

    public static func clearCache() {
        cache.removeAll()
        rectCache.removeAll()
    }
    /// Returns the normalized ink bounding rect (0–1 in each axis) for the given letter
    /// as rendered by PrimaeLetterRenderer at the given canvas size.
    /// Used by LetterGuideGeometry to transform ghost coordinates from calibrated (PBM)
    /// space to actual rendered space.
    ///
    /// Memoized by (letter, canvasSize, schriftArt) — TracingCanvasView calls this
    /// up to 3× per frame on the 60 fps render loop, and each call previously ran a
    /// CTFontGetBoundingRectsForGlyphs CoreText roundtrip.
    public static func normalizedGlyphRect(for letter: String, canvasSize: CGSize, schriftArt: SchriftArt = .druckschrift) -> CGRect? {
        guard !isRunningTests, !letter.isEmpty,
              canvasSize.width > 0, canvasSize.height > 0 else { return nil }
        let key = RectCacheKey(letter: letter,
                               width: Int(canvasSize.width),
                               height: Int(canvasSize.height),
                               schriftArt: schriftArt)
        if let cached = rectCache[key] { return cached }
        let probe: CGFloat = 800
        guard let font = makeFont(size: probe, fontName: schriftArt.fontFileName),
              var glyph = getGlyph(for: letter, in: font) else { return nil }
        let bbox = CTFontGetBoundingRectsForGlyphs(font, .default, &glyph, nil, 1)
        guard bbox.width > 0, bbox.height > 0 else { return nil }
        let pad: CGFloat = 0.10
        let px = CGSize(width: canvasSize.width * 2, height: canvasSize.height * 2)
        let availW = px.width  * (1 - 2 * pad)
        let availH = px.height * (1 - 2 * pad)
        let ratio  = min(availW / bbox.width, availH / bbox.height)
        let scaledW = bbox.width  * ratio
        let scaledH = bbox.height * ratio
        let rect = CGRect(
            x:      0.5 - scaledW / (2 * px.width),
            y:      0.5 - scaledH / (2 * px.height),
            width:  scaledW / px.width,
            height: scaledH / px.height
        )
        if rectCache.count >= cacheLimit { rectCache.removeAll(keepingCapacity: true) }
        rectCache[key] = rect
        return rect
    }

    // MARK: - Private

    private static var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil
    }

    static func makeFont(size: CGFloat, fontName: String = "Primae-Regular") -> CTFont? {
        let bundles: [Bundle] = [.module, .main]
        // Try root, then SPM .copy("Resources") nested paths, then flat Fonts/
        let subdirs: [String?] = [nil, "Resources/Fonts", "Fonts"]
        for bundle in bundles {
            for subdir in subdirs {
                let url: URL?
                if let subdir {
                    url = bundle.url(forResource: fontName, withExtension: "otf", subdirectory: subdir)
                } else {
                    url = bundle.url(forResource: fontName, withExtension: "otf")
                }
                guard let url,
                      let dataProvider = CGDataProvider(url: url as CFURL),
                      let cgFont       = CGFont(dataProvider) else { continue }
                return CTFontCreateWithGraphicsFont(cgFont, size, nil, nil)
            }
        }
        return nil
    }

    static func getGlyph(for letter: String, in font: CTFont) -> CGGlyph? {
        guard let first = letter.unicodeScalars.first else { return nil }
        var c = UniChar(first.value & 0xFFFF)
        var g = CGGlyph(0)
        guard CTFontGetGlyphsForCharacters(font, &c, &g, 1), g != 0 else { return nil }
        return g
    }

    private static func draw(letter: String, size: CGSize, fontName: String = "Primae-Regular") -> UIImage? {
        let scale: CGFloat = 2.0
        let px = CGSize(width: size.width * scale, height: size.height * scale)

        // Probe at large size to compute scale factor
        let probe: CGFloat = 800
        guard let probeFont = makeFont(size: probe, fontName: fontName),
              var probeGlyph = getGlyph(for: letter, in: probeFont) else { return nil }

        let probeBBox = CTFontGetBoundingRectsForGlyphs(probeFont, .default, &probeGlyph, nil, 1)
        guard probeBBox.width > 0, probeBBox.height > 0 else { return nil }

        let pad: CGFloat = 0.10
        let availW    = px.width  * (1 - 2 * pad)
        let availH    = px.height * (1 - 2 * pad)
        let finalSize = probe * min(availW / probeBBox.width, availH / probeBBox.height)

        guard let font = makeFont(size: finalSize, fontName: fontName),
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
