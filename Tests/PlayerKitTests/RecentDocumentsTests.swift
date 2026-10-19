import Foundation
import Testing
@testable import PlayerKit

@Suite struct RecentDocumentsTests {
    @Test func namesAndDisambiguation() {
        let a = URL(fileURLWithPath: "/Users/x/Desktop/demo.cmproj")
        let b = URL(fileURLWithPath: "/Users/x/Documents/demo.cmproj")
        let c = URL(fileURLWithPath: "/Users/x/Documents/vlog.cmproj")
        let e = RecentDocuments.entries([a, c, b, URL(fileURLWithPath: "/Users/x/Desktop/./demo.cmproj")])
        #expect(e.map(\.title) == ["demo.cmproj — Desktop", "vlog.cmproj", "demo.cmproj — Documents"])
        #expect(e.first?.url == a)
        #expect(RecentDocuments.entries([]).isEmpty)
    }
}
