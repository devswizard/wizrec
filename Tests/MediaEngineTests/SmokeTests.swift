import Testing
@testable import MediaEngine

@Test func ffmpegLinksWithTSCC2() {
    #expect(!libavcodecVersion.isEmpty)
    #expect(hasTSCC2Decoder)
}
