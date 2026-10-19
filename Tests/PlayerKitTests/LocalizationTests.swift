import Foundation
import Testing

/// The app's String Catalog stays in step with its sources (run scripts/update-strings.sh).
@Suite struct LocalizationTests {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    @Test func catalogCoversEveryLocalizedLiteral() throws {
        let catalogURL = Self.root.appendingPathComponent("Localization/Localizable.xcstrings")
        let catalog = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any])
        #expect(catalog["sourceLanguage"] as? String == "en")
        let keys = Set((catalog["strings"] as? [String: Any] ?? [:]).keys)

        let dir = Self.root.appendingPathComponent("Sources/WizRecApp")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        let pattern = try NSRegularExpression(pattern: #"String\(localized: "((?:[^"\\]|\\.)*)"\)"#)
        var missing: [String] = []
        var found = 0
        for f in files {
            let text = try String(contentsOf: f, encoding: .utf8)
            for m in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let r = Range(m.range(at: 1), in: text) else { continue }
                let key = String(text[r])
                found += 1
                if !key.contains("\\("), !keys.contains(key) { missing.append("\(f.lastPathComponent): \(key)") }
            }
        }
        #expect(found > 50)
        #expect(missing.isEmpty, "not in Localization/Localizable.xcstrings — run scripts/update-strings.sh: \(missing)")
    }
}
