import Foundation
import Testing
import WizRecTestSupport
@testable import PlayerKit

@Suite struct UpdaterConfigurationTests {
    /// Base64 of 32 bytes, the shape `generate_keys` prints (not a real key).
    static let key = Data(repeating: 7, count: 32).base64EncodedString()
    static let feed = "https://updates.example.org/wizrec/appcast.xml"

    @Test func enabledWithHttpsFeedAndKey() {
        let c = UpdaterConfiguration(infoDictionary: ["SUFeedURL": Self.feed, "SUPublicEDKey": Self.key])
        #expect(c.isEnabled)
        #expect(c.state == .enabled(feedURL: URL(string: Self.feed)!, publicKey: Self.key))
    }

    @Test func disabledWhenUnset() {
        #expect(UpdaterConfiguration(infoDictionary: [:]).state == .disabled(.missingFeedURL))
        #expect(UpdaterConfiguration(infoDictionary: ["SUFeedURL": "  "]).state == .disabled(.missingFeedURL))
        #expect(UpdaterConfiguration(infoDictionary: ["SUFeedURL": Self.feed]).state == .disabled(.missingPublicKey))
        #expect(UpdaterConfiguration(infoDictionary: ["SUPublicEDKey": Self.key]).state == .disabled(.missingFeedURL))
    }

    @Test func disabledOutsideAppBundle() {
        let c = UpdaterConfiguration(infoDictionary: ["SUFeedURL": Self.feed, "SUPublicEDKey": Self.key], isAppBundle: false)
        #expect(c.state == .disabled(.notAnAppBundle))
        // The test runner is not an app bundle.
        #expect(!UpdaterConfiguration(bundle: .main).isEnabled)
    }

    @Test func rejectsInsecureOrMalformedFeeds() {
        for feed in ["http://updates.example.org/appcast.xml", "ftp://x/y", "appcast.xml", "https://", "https:///a"] {
            let c = UpdaterConfiguration(infoDictionary: ["SUFeedURL": feed, "SUPublicEDKey": Self.key])
            #expect(c.state == .disabled(.invalidFeedURL(feed)), "\(feed)")
        }
    }

    @Test func rejectsBadKeys() {
        for key in ["not base64!", Data(count: 31).base64EncodedString(), Data(count: 64).base64EncodedString()] {
            let c = UpdaterConfiguration(infoDictionary: ["SUFeedURL": Self.feed, "SUPublicEDKey": key])
            #expect(c.state == .disabled(.invalidPublicKey), "\(key)")
        }
        #expect(UpdaterConfiguration.isEd25519PublicKey(Self.key))
    }

    // MARK: scripts/release/sparkle-info.sh (build-time env → Info.plist entries)

    private static let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("scripts/release/sparkle-info.sh")

    private func run(_ env: [String: String]) throws -> (status: Int32, out: String) {
        var e = ProcessInfo.processInfo.environment
        e["WIZREC_SPARKLE_FEED"] = nil
        e["WIZREC_SPARKLE_PUBKEY"] = nil
        e.merge(env) { $1 }
        let r = try TestProcess.run("/bin/bash", [Self.script.path], environment: e, stderr: .discard)
        return (r.status, r.stdoutText)
    }

    @Test func buildScriptWritesNothingWhenUnset() throws {
        let r = try run([:])
        #expect(r.status == 0 && r.out.isEmpty)
    }

    @Test func buildScriptWritesKeysThatEnableTheUpdater() throws {
        let r = try run(["WIZREC_SPARKLE_FEED": Self.feed, "WIZREC_SPARKLE_PUBKEY": Self.key])
        #expect(r.status == 0)
        let plist = "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict>\(r.out)</dict></plist>"
        let info = try PropertyListSerialization.propertyList(from: Data(plist.utf8), format: nil) as? [String: Any]
        #expect(UpdaterConfiguration(infoDictionary: info ?? [:]).isEnabled)
    }

    @Test func buildScriptRejectsHalfOrInvalidConfiguration() throws {
        #expect(try run(["WIZREC_SPARKLE_FEED": Self.feed]).status != 0)
        #expect(try run(["WIZREC_SPARKLE_PUBKEY": Self.key]).status != 0)
        #expect(try run(["WIZREC_SPARKLE_FEED": "http://x.org/a.xml", "WIZREC_SPARKLE_PUBKEY": Self.key]).status != 0)
        #expect(try run(["WIZREC_SPARKLE_FEED": Self.feed, "WIZREC_SPARKLE_PUBKEY": "abc"]).status != 0)
        #expect(try run(["WIZREC_SPARKLE_FEED": Self.feed + "?a=<b>", "WIZREC_SPARKLE_PUBKEY": Self.key]).status != 0)
    }
}
