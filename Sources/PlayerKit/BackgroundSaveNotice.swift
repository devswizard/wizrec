import Foundation
import TSCProjKit

/// Save-time notice for projects that use WizRec's own shader backgrounds.
///
/// Camtasia opens only vendor-signed `.tscshadervid` files; it reports an unsigned one as "not
/// supported" and shows the rest of the project normally (`docs/specs/shader-backgrounds.md`
/// §10). WizRec's backgrounds carry no `signature`, so saving a project that uses one shows a
/// short, non-blocking notice: once per document session, never in scripted runs, and not at
/// all after the user turns it off in Settings (`AppPreferences.Key.warnUnsignedBackgrounds`).
@MainActor
public final class BackgroundSaveNotice {
    /// The notice text.
    public static let text = String(localized: "Camtasia won't show WizRec backgrounds; the rest of the project opens normally.")

    /// The notice was shown for this document.
    public private(set) var wasShown = false

    public init() {}

    /// Whether to show the notice now; marks it shown when true. `unsignedBackgrounds`: the
    /// result of `unsignedBackgrounds(in:)`. `enabled`: the Settings preference.
    public func shouldShow(unsignedBackgrounds: [String], scripted: Bool, enabled: Bool) -> Bool {
        guard !wasShown, !scripted, enabled, !unsignedBackgrounds.isEmpty else { return false }
        wasShown = true
        return true
    }

    /// File names of the project's `.tscshadervid` sources that carry no `signature`, i.e. that
    /// Camtasia will not show. Missing or unreadable files are left out (nothing is known about
    /// them; Missing Media covers the missing ones).
    public nonisolated static func unsignedBackgrounds(in bundle: ProjectBundle) -> [String] {
        var names: [String] = []
        for source in bundle.project.sourceBin {
            let url = bundle.resolve(source)
            guard url.pathExtension.lowercased() == "tscshadervid",
                  let data = try? Data(contentsOf: url),
                  isSigned(shaderVid: data) == false else { continue }
            names.append(url.lastPathComponent)
        }
        return names
    }

    /// Whether a `.tscshadervid` file carries a non-empty top-level `signature`; nil when the
    /// data is not a JSON object. (A shader-video file, not a project: plain JSON parsing is fine.)
    public nonisolated static func isSigned(shaderVid data: Data) -> Bool? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        switch object["signature"] {
        case let s as String: return !s.isEmpty
        case nil, is NSNull: return false
        default: return true
        }
    }
}
