import UIKit
import CoreGraphics

/// Loads a PBM (Portable Bitmap) file and returns a UIImage.
/// Supports P1 (ASCII) and P4 (binary) formats.
/// Black pixels (1 in P1, set bit in P4) become opaque dark, white (0) become clear.
enum PBMLoader {
    static func load(named relativePath: String, bundle: Bundle = .main) -> UIImage? {
        guard let url = resourceURL(for: relativePath, bundle: bundle) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return decode(data: data)
    }

    private static func resourceURL(for relativePath: String, bundle: Bundle) -> URL? {
        // Try Bundle.main resourceURL + relative path
        if let root = bundle.resourceURL {
            let candidate = root.appendingPathComponent(relativePath)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        // Fallback: bundle URL lookup
        let ns = relativePath as NSString
        return bundle.url(forResource: ns.deletingPathExtension, withExtension: ns.pathExtension.isEmpty ? nil : ns.pathExtension)
    }

    static func decode(data: Data) -> UIImage? {
        // Parse PBM header
        var pos = 0
        func skipWhitespaceAndComments() {
            while pos < data.count {
                let c = data[pos]
                if c == UInt8(ascii: "#") {
                    while pos < data.count && data[pos] != UInt8(ascii: "\n") { pos += 1 }
                } else if c == UInt8(ascii: " ") || c == UInt8(ascii: "\t") ||
                          c == UInt8(ascii: "\n") || c == UInt8(ascii: "\r") {
                    pos += 1
                } else { break }
            }
        }
        func readToken() -> String {
            skipWhitespaceAndComments()
            var token = [UInt8]()
            while pos < data.count {
                let c = data[pos]
                if c == UInt8(ascii: " ") || c == UInt8(ascii: "\t") ||
                   c == UInt8(ascii: "\n") || c == UInt8(ascii: "\r") { break }
                token.append(c); pos += 1
            }
            return String(bytes: token, encoding: .ascii) ?? ""
        }

        let magic = readToken()
        guard magic == "P1" || magic == "P4" else { return nil }
        guard let width = Int(readToken()), let height = Int(readToken()),
              width > 0, height > 0 else { return nil }

        // Skip single whitespace after header (required by P4 spec)
        if magic == "P4" && pos < data.count { pos += 1 }

        // Build RGBA bitmap: black pixel → dark gray opaque, white → transparent
        var pixels = [UInt8](repeating: 0, count: width * height * 4)

        if magic == "P1" {
            // ASCII: '1' = black, '0' = white
            var pixIdx = 0
            while pixIdx < width * height && pos < data.count {
                let c = data[pos]; pos += 1
                if c == UInt8(ascii: "1") {
                    let base = pixIdx * 4
                    pixels[base] = 30; pixels[base+1] = 30; pixels[base+2] = 30; pixels[base+3] = 200
                    pixIdx += 1
                } else if c == UInt8(ascii: "0") {
                    pixIdx += 1  // transparent
                }
            }
        } else {
            // P4 binary: each row is ceil(width/8) bytes, MSB first, 1 = black
            let rowBytes = (width + 7) / 8
            for row in 0..<height {
                for col in 0..<width {
                    let byteIdx = pos + row * rowBytes + col / 8
                    guard byteIdx < data.count else { continue }
                    let bit = (data[byteIdx] >> (7 - (col % 8))) & 1
                    if bit == 1 {
                        let base = (row * width + col) * 4
                        pixels[base] = 30; pixels[base+1] = 30; pixels[base+2] = 30; pixels[base+3] = 200
                    }
                }
            }
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let cgImage = CGImage(
                width: width, height: height,
                bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil, shouldInterpolate: true,
                intent: .defaultIntent
              ) else { return nil }

        return UIImage(cgImage: cgImage)
    }
}
