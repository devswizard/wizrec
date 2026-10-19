import Foundation

/// Locates the magenta test marker (`TestImages.marker`) in a frame.
public enum MarkerTracker {
    /// Centroid of the marker's magenta fill in image px (+y down, pixel centres at +0.5) and the
    /// number of matching pixels; nil when none match. The white cross is ignored; the test
    /// cards' 75 % magenta bar (191, 0, 191) stays below the red cut.
    ///
    /// `window` (x0, y0, x1, y1 exclusive, px) limits the search, e.g. around a known position so
    /// compression fringes elsewhere (magenta-ish card bars in H.264) cannot pull the centroid.
    public static func centroid(_ img: RGBAImage, window: (Int, Int, Int, Int)? = nil) -> (x: Double, y: Double, pixels: Int)? {
        var sx = 0.0, sy = 0.0, count = 0
        let (x0, y0, x1, y1) = window.map { (max(0, $0.0), max(0, $0.1), min(img.width, $0.2), min(img.height, $0.3)) }
            ?? (0, 0, img.width, img.height)
        guard x1 > x0, y1 > y0 else { return nil }
        img.pixels.withUnsafeBufferPointer { p in
            for y in y0..<y1 {
                var i = 4 * (y * img.width + x0)
                for x in x0..<x1 {
                    if p[i] > 215, p[i + 1] < 90, p[i + 2] > 180 { sx += Double(x); sy += Double(y); count += 1 }
                    i += 4
                }
            }
        }
        guard count > 0 else { return nil }
        return (sx / Double(count) + 0.5, sy / Double(count) + 0.5, count)
    }
}
