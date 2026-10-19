import CoreGraphics
import Foundation
import ImageIO
import TSCProjKit

/// The bundle's `docPrefs` plist (UI state Camtasia saves next to `project.tscproj`).
/// Only `DocPrefPlayheadTime` matters to us: the playhead, in project ticks as a
/// decimal string [obs: demo "8537760000" = 12.1 s at 705600000, the time of its
/// `ProjectThumbnail`].
public enum DocPrefs {
    public static let playheadKey = "DocPrefPlayheadTime"

    /// Writes a minimal `docPrefs` that parks the playhead at `ticks`. Replaces any existing file.
    public static func write(playhead ticks: Int64, to bundle: URL) throws {
        let plist: [String: Any] = [playheadKey: String(ticks)]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: bundle.appendingPathComponent("docPrefs"), options: .atomic)
    }

    /// The saved playhead in ticks, or nil when the bundle has no readable `docPrefs`.
    public static func playhead(in bundle: URL) -> Int64? {
        guard let data = try? Data(contentsOf: bundle.appendingPathComponent("docPrefs")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        switch plist[playheadKey] {
        case let s as String: return Int64(s) ?? Double(s).map { Int64($0.rounded()) }
        case let n as NSNumber: return n.int64Value
        default: return nil
        }
    }
}

/// `metadata.ProjectThumbnail`: a base64 PNG that Camtasia renders at the playhead
/// when it saves (640×360 for a 1920×1080 canvas [obs, demo]). It is a Camtasia
/// render of the project, so it serves as a golden reference when no exported
/// frame exists.
public enum ProjectThumbnail {
    /// The decoded thumbnail, or nil when the project has none (projects WizRec writes never do).
    public static func image(in project: Project) -> RGBAImage? {
        guard let b64 = project.root["metadata"]?.object?["ProjectThumbnail"]?.string,
              let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else { return nil }
        return decodePNG(data)
    }

    /// The raw PNG bytes, for saving.
    public static func pngData(in project: Project) -> Data? {
        project.root["metadata"]?.object?["ProjectThumbnail"]?.string
            .flatMap { Data(base64Encoded: $0, options: .ignoreUnknownCharacters) }
    }

    /// Integer downsampling factor from a `canvas` render to a `thumbnail` of the same
    /// aspect ratio (3 for 1920×1080 → 640×360), or nil when the sizes are not an exact multiple.
    public static func factor(canvas: (width: Int, height: Int), thumbnail: (width: Int, height: Int)) -> Int? {
        guard thumbnail.width > 0, thumbnail.height > 0, canvas.width % thumbnail.width == 0,
              canvas.height % thumbnail.height == 0 else { return nil }
        let k = canvas.width / thumbnail.width
        return k >= 1 && canvas.height / thumbnail.height == k ? k : nil
    }
}

/// Decodes PNG (or any ImageIO format) bytes into straight 8-bit RGBA.
public func decodePNG(_ data: Data) -> RGBAImage? {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil),
          let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    return RGBAImage(cg)
}

/// Loads an image file into straight 8-bit RGBA.
public func loadImage(_ url: URL) -> RGBAImage? {
    (try? Data(contentsOf: url)).flatMap(decodePNG)
}

extension RGBAImage {
    /// `k×k` box average (each output pixel = mean of a `k×k` block, rounded), as a
    /// thumbnail is made from a full-size render. Trailing rows/columns that do not fill a block are dropped.
    public func boxDownsampled(by k: Int) -> RGBAImage {
        guard k > 1 else { return self }
        let w = width / k, h = height / k
        var out = [UInt8](repeating: 0, count: w * h * 4)
        let n = k * k
        for oy in 0..<h {
            for ox in 0..<w {
                var s = (0, 0, 0, 0)
                for dy in 0..<k {
                    var o = 4 * ((oy * k + dy) * width + ox * k)
                    for _ in 0..<k {
                        s.0 += Int(pixels[o]); s.1 += Int(pixels[o + 1]); s.2 += Int(pixels[o + 2]); s.3 += Int(pixels[o + 3])
                        o += 4
                    }
                }
                let d = 4 * (oy * w + ox)
                out[d] = UInt8((s.0 + n / 2) / n); out[d + 1] = UInt8((s.1 + n / 2) / n)
                out[d + 2] = UInt8((s.2 + n / 2) / n); out[d + 3] = UInt8((s.3 + n / 2) / n)
            }
        }
        return RGBAImage(width: w, height: h, pixels: out)
    }

    /// The sub-image `x..<x+w`, `y..<y+h` (top-left origin), clamped to the image.
    public func cropped(x: Int, y: Int, width w: Int, height h: Int) -> RGBAImage {
        let x0 = max(0, min(width, x)), y0 = max(0, min(height, y))
        let x1 = max(x0, min(width, x + w)), y1 = max(y0, min(height, y + h))
        let cw = x1 - x0, ch = y1 - y0
        var out = [UInt8](repeating: 0, count: cw * ch * 4)
        for row in 0..<ch {
            let src = 4 * ((y0 + row) * width + x0)
            out.replaceSubrange((4 * row * cw)..<(4 * (row + 1) * cw), with: pixels[src..<(src + 4 * cw)])
        }
        return RGBAImage(width: cw, height: ch, pixels: out)
    }

    /// Composites over an opaque `background` (straight alpha), so a PNG with alpha compares
    /// against an opaque render.
    public func flattened(over background: (UInt8, UInt8, UInt8)) -> RGBAImage {
        var out = pixels
        let bg = [Int(background.0), Int(background.1), Int(background.2)]
        for i in stride(from: 0, to: out.count, by: 4) {
            let a = Int(out[i + 3])
            guard a < 255 else { continue }
            for c in 0..<3 { out[i + c] = UInt8((Int(out[i + c]) * a + bg[c] * (255 - a) + 127) / 255) }
            out[i + 3] = 255
        }
        return RGBAImage(width: width, height: height, pixels: out)
    }
}
