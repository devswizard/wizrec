import Foundation
import Testing
@testable import PlayerKit

@Suite struct CaptionLanguageTests {
    @Test func languagePreferenceDefaultsToAutoDetect() throws {
        let suite = "wizrec-caplang-\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        var p = AppPreferences.load(from: d)
        #expect(p.captionLanguage == "")
        #expect(p.transcriptionLanguage == nil)
        d.set("bn", forKey: AppPreferences.Key.captionLanguage)
        p = AppPreferences.load(from: d)
        #expect(p.transcriptionLanguage == "bn")
        p.captionLanguage = " auto "
        #expect(p.transcriptionLanguage == nil)
        p.captionLanguage = "pt-BR"
        p.save(to: d)
        #expect(AppPreferences.load(from: d).transcriptionLanguage == "pt-BR")
        #expect(AppPreferences.captionLanguages.first == "")
        #expect(Set(AppPreferences.captionLanguages).count == AppPreferences.captionLanguages.count)
    }
}
