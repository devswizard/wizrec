import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A cursor image rendered at the capture's pixel scale: RGBA8 premultiplied pixels plus the
/// hot spot, both in captured pixels.
struct CursorBitmap: Hashable, Sendable {
    var width: Int
    var height: Int
    /// Hot spot from the top-left, captured pixels.
    var hotspotX: Double
    var hotspotY: Double
    /// `width * height * 4` bytes, RGBA premultiplied, rows top to bottom.
    var pixels: Data

    func cgImage() -> CGImage? {
        guard width > 0, height > 0, pixels.count == width * height * 4,
              let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    /// Draws `image` (size in points) at `scale` pixels per point into a bitmap.
    static func render(_ image: CGImage, pointSize: CGSize, hotspot: CGPoint, scale: Double) -> CursorBitmap? {
        let w = Int((Double(pointSize.width) * scale).rounded(.up)), h = Int((Double(pointSize.height) * scale).rounded(.up))
        guard w > 0, h > 0, w <= 1024, h <= 1024 else { return nil }
        var data = Data(count: w * h * 4)
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        return CursorBitmap(width: w, height: h, hotspotX: round2(Double(hotspot.x) * scale),
                            hotspotY: round2(Double(hotspot.y) * scale), pixels: data)
    }

    /// The system cursor currently on screen, rendered at `scale`. Main thread (AppKit).
    @MainActor static func currentSystemCursor(scale: Double) -> CursorBitmap? {
        guard let cursor = NSCursor.currentSystem else { return nil }
        let image = cursor.image
        let size = image.size
        var rect = CGRect(x: 0, y: 0, width: Double(size.width) * scale, height: Double(size.height) * scale)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        return render(cg, pointSize: size, hotspot: cursor.hotSpot, scale: scale)
    }
}

/// Assigns ids to distinct cursor bitmaps and writes each one once as
/// `<directory>/cursors/cursor-<id>.png`.
struct CursorImageRegistry {
    let directory: URL
    private var ids: [CursorBitmap: Int] = [:]
    private(set) var images: [CursorImage] = []
    private(set) var writeErrors = 0

    init(directory: URL) { self.directory = directory }

    /// Id of `bitmap`, registering (and writing) it when new.
    mutating func id(for bitmap: CursorBitmap) -> Int {
        if let id = ids[bitmap] { return id }
        let id = images.count
        let file = "cursors/cursor-\(id).png"
        ids[bitmap] = id
        images.append(CursorImage(id: id, file: file, width: bitmap.width, height: bitmap.height,
                                  hotspotX: bitmap.hotspotX, hotspotY: bitmap.hotspotY))
        if !Self.writePNG(bitmap, to: directory.appendingPathComponent(file)) { writeErrors += 1 }
        return id
    }

    static func writePNG(_ bitmap: CursorBitmap, to url: URL) -> Bool {
        guard let image = bitmap.cgImage() else { return false }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }
}
