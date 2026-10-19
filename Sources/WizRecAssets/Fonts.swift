import CoreText
import Foundation
import os

/// A bundled font file: an unmodified upstream copy of an SIL Open Font License 1.1 family
/// (google/fonts `ofl/`), shipped with its licence. Hashes are in `THIRD_PARTY_NOTICES.md`.
public struct FontAsset: Sendable, Hashable, Identifiable {
    /// Family name as callouts store it in `def.font.name`, e.g. `Montserrat`.
    public var family: String
    /// Styles in the file, e.g. `["Regular", "Bold"]` (a variable font covers a weight range).
    public var styles: [String]
    /// File name inside the resource bundle's `Fonts/` folder.
    public var fileName: String
    /// Licence file name inside `Fonts/`.
    public var licenseFileName: String
    public var id: String { fileName }

    /// The font file, or nil when the resource bundle is not installed next to the binary.
    public var url: URL? { AssetResources.url(fileName, in: "Fonts") }

    /// The licence text file.
    public var licenseURL: URL? { AssetResources.url(licenseFileName, in: "Fonts") }
}

enum BuiltInFonts {
    static let all: [FontAsset] = [
        FontAsset(family: "Montserrat", styles: ["Thin", "Light", "Regular", "Medium", "SemiBold", "Bold", "Black"],
                  fileName: "Montserrat-wght.ttf", licenseFileName: "Montserrat-OFL.txt"),
        FontAsset(family: "Lato", styles: ["Regular"], fileName: "Lato-Regular.ttf", licenseFileName: "Lato-OFL.txt"),
        FontAsset(family: "Lato", styles: ["Bold"], fileName: "Lato-Bold.ttf", licenseFileName: "Lato-OFL.txt"),
        FontAsset(family: "Bebas Neue", styles: ["Regular"], fileName: "BebasNeue-Regular.ttf",
                  licenseFileName: "BebasNeue-OFL.txt"),
        FontAsset(family: "Caveat", styles: ["Regular", "Medium", "SemiBold", "Bold"], fileName: "Caveat-wght.ttf",
                  licenseFileName: "Caveat-OFL.txt"),
    ]
}

/// Registers the bundled fonts with Core Text for this process, so `CTFont`/`NSFont` lookups by
/// family name (callout text, captions) find them. Idempotent; safe from any thread.
public enum AssetFonts {
    private static let registered = OSAllocatedUnfairLock<[String]?>(initialState: nil)

    /// Registers every bundled font once. Returns the families now available; fonts whose file
    /// is missing are skipped (the app falls back to a system font with the same family name).
    @discardableResult
    public static func registerAll() -> [String] {
        registered.withLock { state in
            if let state { return state }
            var out: Set<String> = []
            for f in AssetCatalog.fonts {
                guard let url = f.url else { continue }
                var error: Unmanaged<CFError>?
                if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                    out.insert(f.family)
                } else if let e = error?.takeRetainedValue(),
                          CFErrorGetCode(e) == CTFontManagerError.alreadyRegistered.rawValue {
                    out.insert(f.family)
                }
            }
            let families = out.sorted()
            state = families
            return families
        }
    }
}

/// Finds `WizRec_WizRecAssets.bundle` without SwiftPM's generated `Bundle.module`, which
/// traps when the bundle is missing and looks beside the `.app` (outside `Contents/`), where a
/// signed app cannot keep it. Looks in `Contents/Resources` first, then beside the binary
/// (`swift run`, `swift test`).
enum AssetResources {
    static let bundleName = "WizRec_WizRecAssets.bundle"

    private final class Marker {}

    static let bundle: Bundle? = {
        var dirs: [URL] = []
        for b in [Bundle.main, Bundle(for: Marker.self)] {
            if let r = b.resourceURL { dirs.append(r) }
            dirs.append(b.bundleURL)
            dirs.append(b.bundleURL.deletingLastPathComponent())
            if let exe = b.executableURL { dirs.append(exe.deletingLastPathComponent()) }
        }
        for d in dirs {
            let u = d.appendingPathComponent(bundleName)
            if let b = Bundle(url: u) { return b }
        }
        return nil
    }()

    static func url(_ name: String, in folder: String) -> URL? {
        guard let base = bundle?.resourceURL ?? bundle?.bundleURL else { return nil }
        let u = base.appendingPathComponent(folder).appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }
}
