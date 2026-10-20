import Foundation
import MediaEngine
import Testing
import TimelineEngine
import TSCProjKit
@testable import PlayerKit

@Suite @MainActor struct BackgroundSaveNoticeTests {
    /// A minimal shader-video file of our own; `signature` is a placeholder string, not a real one.
    private static func shaderVid(signature: String?) -> Data {
        var s = #"{"name":"t","version":"1.0","width":1920,"height":1080,"code":"void main(){}""#
        if let signature { s += #","signature":"\#(signature)""# }
        return Data((s + "}").utf8)
    }

    @Test func signatureDetection() {
        #expect(BackgroundSaveNotice.isSigned(shaderVid: Self.shaderVid(signature: nil)) == false)
        #expect(BackgroundSaveNotice.isSigned(shaderVid: Self.shaderVid(signature: "")) == false)
        #expect(BackgroundSaveNotice.isSigned(shaderVid: Self.shaderVid(signature: "MIGIAkIB")) == true)
        #expect(BackgroundSaveNotice.isSigned(shaderVid: Data("not json".utf8)) == nil)
        #expect(BackgroundSaveNotice.isSigned(shaderVid: Data("[1]".utf8)) == nil)
    }

    @Test func findsOnlyUnsignedBackgroundsThatExist() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wizrec-bgnotice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let doc = try EditorDocumentModel.untitled(in: dir)
        #expect(BackgroundSaveNotice.unsignedBackgrounds(in: doc.bundle).isEmpty)

        func add(_ name: String, _ data: Data?) throws {
            let file = dir.appendingPathComponent(name)
            if let data { try data.write(to: file) } else { try Data().write(to: file) }
            let src = try doc.bundle.importFile(file)
            if data == nil {
                try FileManager.default.removeItem(at: doc.bundle.directory.appendingPathComponent(src).standardizedFileURL)
            }
            try doc.perform(AddSource(SourceDescriptor(src: src, lastModified: Date(timeIntervalSince1970: 0), tracks: [
                .init(type: 0, editRate: 30, rangeEnd: 30, width: 1920, height: 1080,
                      sampleRate: Rational(0), bitDepth: 32, channelCount: 0),
            ])))
        }
        try add("wizrec-aurora.tscshadervid", Self.shaderVid(signature: nil))
        try add("signed.tscshadervid", Self.shaderVid(signature: "MIGIAkIB"))
        try add("gone.tscshadervid", nil)                        // missing file: unknown, left out
        try add("clip.json", Self.shaderVid(signature: nil))     // not a background
        try add("UPPER.TSCSHADERVID", Self.shaderVid(signature: nil))

        #expect(BackgroundSaveNotice.unsignedBackgrounds(in: doc.bundle) == ["wizrec-aurora.tscshadervid", "UPPER.TSCSHADERVID"])
    }

    @Test func showsOncePerSessionNeverScriptedOrDisabled() {
        let names = ["wizrec-aurora.tscshadervid"]
        #expect(!BackgroundSaveNotice().shouldShow(unsignedBackgrounds: names, scripted: true, enabled: true))
        #expect(!BackgroundSaveNotice().shouldShow(unsignedBackgrounds: names, scripted: false, enabled: false))
        let n = BackgroundSaveNotice()
        #expect(!n.shouldShow(unsignedBackgrounds: [], scripted: false, enabled: true))
        #expect(!n.wasShown)
        #expect(n.shouldShow(unsignedBackgrounds: names, scripted: false, enabled: true))
        #expect(n.wasShown)
        #expect(!n.shouldShow(unsignedBackgrounds: names, scripted: false, enabled: true))
    }

    @Test func preferenceDefaultsOnAndRoundTrips() throws {
        let suite = "wizrec-bgnotice-\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        #expect(AppPreferences.load(from: d).warnUnsignedBackgrounds)
        d.set(false, forKey: AppPreferences.Key.warnUnsignedBackgrounds)
        #expect(!AppPreferences.load(from: d).warnUnsignedBackgrounds)
    }
}
