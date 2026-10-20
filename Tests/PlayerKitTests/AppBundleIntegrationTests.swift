import Foundation
import Testing
import WizRecTestSupport
@testable import PlayerKit

/// S5-QA-1 / ship6: checks a built `WizRec.app` (from `scripts/make-app.sh`) without launching it.
/// Opt in with `WIZREC_APP_BUNDLE=<path to WizRec.app>`, e.g.
///
/// ```sh
/// WIZREC_SPARKLE_FEED=https://example.org/appcast.xml \
/// WIZREC_SPARKLE_PUBKEY=$(head -c 32 /dev/zero | base64) scripts/make-app.sh
/// WIZREC_APP_BUNDLE=build/WizRec.app swift test --filter AppBundleIntegrationTests
/// ```
/// Sparkle is embedded under Contents/Frameworks and found through the
/// `@executable_path/../Frameworks` run path, the signature verifies (deep, strict), the bundle id
/// is `com.devswizard.WizRec` (or `WIZREC_BUNDLE_ID`), Sparkle's licence travels with it, and the
/// Info.plist's updater keys give the state `UpdaterConfiguration` expects (enabled with both keys,
/// disabled without).
@Suite(.enabled(if: ProcessInfo.processInfo.environment["WIZREC_APP_BUNDLE"].map { !$0.isEmpty } ?? false,
                "set WIZREC_APP_BUNDLE to a built WizRec.app"))
struct AppBundleIntegrationTests {
    static var app: URL {
        let p = ProcessInfo.processInfo.environment["WIZREC_APP_BUNDLE"] ?? ""
        return URL(fileURLWithPath: (p as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Runs `tool args`; returns status and stdout+stderr.
    static func run(_ tool: String, _ args: [String]) throws -> (status: Int32, out: String) {
        let r = try TestProcess.run(tool, args, stderr: .stdout)
        return (r.status, r.stdoutText)
    }

    var executable: URL { Self.app.appendingPathComponent("Contents/MacOS/WizRec") }
    var info: [String: Any] {
        (NSDictionary(contentsOf: Self.app.appendingPathComponent("Contents/Info.plist")) as? [String: Any]) ?? [:]
    }

    @Test func sparkleIsEmbeddedAndLinkedThroughRunPath() throws {
        let fm = FileManager.default
        let fw = Self.app.appendingPathComponent("Contents/Frameworks/Sparkle.framework")
        #expect(fm.fileExists(atPath: fw.appendingPathComponent("Versions/Current/Sparkle").path)
                || fm.fileExists(atPath: fw.appendingPathComponent("Sparkle").path), "Sparkle.framework binary missing")
        #expect(fm.fileExists(atPath: Self.app.appendingPathComponent("Contents/Resources/Licenses/Sparkle/LICENSE").path),
                "Sparkle LICENSE (MIT notice) missing")

        let links = try Self.run("/usr/bin/otool", ["-L", executable.path])
        #expect(links.status == 0)
        #expect(links.out.contains("@rpath/Sparkle.framework"), "WizRec does not link Sparkle via @rpath:\n\(links.out)")
        let loads = try Self.run("/usr/bin/otool", ["-l", executable.path])
        let rpaths = loads.out.components(separatedBy: "cmd LC_RPATH").dropFirst()
            .compactMap { $0.components(separatedBy: "path ").dropFirst().first?.components(separatedBy: " (offset").first }
        #expect(rpaths.contains("@executable_path/../Frameworks"), "run paths: \(rpaths)")
    }

    @Test func signatureVerifiesDeepAndStrict() throws {
        let verify = try Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", Self.app.path])
        #expect(verify.status == 0, "codesign --verify failed:\n\(verify.out)")
        let fw = Self.app.appendingPathComponent("Contents/Frameworks/Sparkle.framework")
        let inner = try Self.run("/usr/bin/codesign", ["--verify", "--strict", fw.path])
        #expect(inner.status == 0, "Sparkle.framework signature:\n\(inner.out)")
    }

    @Test func infoPlistIdentityAndUpdaterState() {
        let expectedID = ProcessInfo.processInfo.environment["WIZREC_BUNDLE_ID"] ?? "com.devswizard.WizRec"
        #expect(info["CFBundleIdentifier"] as? String == expectedID)
        #expect(info["CFBundleExecutable"] as? String == "WizRec")
        let config = UpdaterConfiguration(infoDictionary: info)
        let hasFeed = info["SUFeedURL"] != nil, hasKey = info["SUPublicEDKey"] != nil
        #expect(hasFeed == hasKey, "half-configured updater in Info.plist")
        #expect(config.isEnabled == (hasFeed && hasKey), "\(config.state)")
        print("app bundle: \(expectedID), updater \(config.state)")
    }
}
