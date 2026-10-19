import Testing
@testable import PlayerKit

@Suite struct LibrarySearchTests {
    @Test func blankQueryMatchesEverything() {
        #expect(LibrarySearch.matches("", fields: ["Drop Shadow"]))
        #expect(LibrarySearch.matches("   ", fields: []))
    }

    @Test func everyWordMustMatchSomeField() {
        let f = ["Drop Shadow", "DropShadow", "categoryVisualEffects"]
        #expect(LibrarySearch.matches("shadow", fields: f))
        #expect(LibrarySearch.matches("SHAD drop", fields: f))
        #expect(LibrarySearch.matches("visual shadow", fields: f))
        #expect(!LibrarySearch.matches("shadow blur", fields: f))
        #expect(LibrarySearch.matches("cafe", fields: ["Café intro"]))
    }

    @Test func splitsIdentifiers() {
        #expect(LibrarySearch.words(ofIdentifier: "DropShadow") == "Drop Shadow")
        #expect(LibrarySearch.words(ofIdentifier: "FadeThroughBlack") == "Fade Through Black")
        #expect(LibrarySearch.words(ofIdentifier: "RGB") == "RGB")
        #expect(LibrarySearch.words(ofIdentifier: "fade2Black") == "fade2 Black")
        #expect(LibrarySearch.words(ofIdentifier: "") == "")
    }
}
