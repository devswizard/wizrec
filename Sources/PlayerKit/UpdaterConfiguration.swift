import Foundation

/// Whether the Sparkle updater may run, decided from the app bundle's Info.plist.
///
/// `scripts/make-app.sh` writes `SUFeedURL` and `SUPublicEDKey` only when the build-time
/// environment sets `WIZREC_SPARKLE_FEED` and `WIZREC_SPARKLE_PUBKEY`. Without both (or with
/// invalid values, or outside a `.app` bundle, e.g. `swift run`) the updater stays off: no
/// network access, and "Check for Updates…" is disabled. Only the public key is ever in the
/// bundle; the EdDSA private key stays in the maintainer's keychain.
public struct UpdaterConfiguration: Sendable, Equatable {
    /// Info.plist keys Sparkle reads (`SU…`) and the environment variables that fill them.
    public enum Key {
        public static let feedURL = "SUFeedURL"
        public static let publicKey = "SUPublicEDKey"
        public static let feedEnvironment = "WIZREC_SPARKLE_FEED"
        public static let publicKeyEnvironment = "WIZREC_SPARKLE_PUBKEY"
    }

    /// Why the updater is off.
    public enum DisabledReason: Sendable, Equatable, CustomStringConvertible {
        /// The executable does not run from a `.app` bundle.
        case notAnAppBundle
        /// `SUFeedURL` is missing or empty.
        case missingFeedURL
        /// `SUFeedURL` is not an absolute `https` URL (Sparkle refuses plain http feeds).
        case invalidFeedURL(String)
        /// `SUPublicEDKey` is missing or empty.
        case missingPublicKey
        /// `SUPublicEDKey` is not base64 of a 32-byte Ed25519 public key.
        case invalidPublicKey

        public var description: String {
            switch self {
            case .notAnAppBundle: "not running from an app bundle"
            case .missingFeedURL: "no update feed (build with WIZREC_SPARKLE_FEED)"
            case .invalidFeedURL(let s): "update feed is not an https URL: \(s)"
            case .missingPublicKey: "no update signing key (build with WIZREC_SPARKLE_PUBKEY)"
            case .invalidPublicKey: "update signing key is not a base64 Ed25519 public key"
            }
        }
    }

    /// `.enabled` carries the validated feed; `.disabled` the first problem found.
    public enum State: Sendable, Equatable {
        case enabled(feedURL: URL, publicKey: String)
        case disabled(DisabledReason)
    }

    public let state: State

    /// True when Sparkle may be started.
    public var isEnabled: Bool { if case .enabled = state { true } else { false } }

    /// Decides from an Info.plist dictionary. `isAppBundle` is false for unbundled runs.
    public init(infoDictionary: [String: Any], isAppBundle: Bool = true) {
        state = Self.evaluate(info: infoDictionary, isAppBundle: isAppBundle)
    }

    /// Decides for `bundle` (normally `Bundle.main`).
    public init(bundle: Bundle) {
        self.init(infoDictionary: bundle.infoDictionary ?? [:], isAppBundle: bundle.bundleURL.pathExtension == "app")
    }

    private static func evaluate(info: [String: Any], isAppBundle: Bool) -> State {
        guard isAppBundle else { return .disabled(.notAnAppBundle) }
        let feed = (info[Key.feedURL] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !feed.isEmpty else { return .disabled(.missingFeedURL) }
        guard let url = URL(string: feed), url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty
        else { return .disabled(.invalidFeedURL(feed)) }
        let key = (info[Key.publicKey] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty else { return .disabled(.missingPublicKey) }
        guard isEd25519PublicKey(key) else { return .disabled(.invalidPublicKey) }
        return .enabled(feedURL: url, publicKey: key)
    }

    /// Base64 of exactly 32 bytes (what Sparkle's `generate_keys` prints).
    public static func isEd25519PublicKey(_ s: String) -> Bool {
        Data(base64Encoded: s)?.count == 32
    }
}
