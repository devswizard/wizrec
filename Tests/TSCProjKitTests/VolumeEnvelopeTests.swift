import Foundation
import Testing
@testable import TSCProjKit

/// Zero-length `volume` keyframes are a linear point envelope (audio.md §4, AU1), as in AudioEngine.
struct VolumeEnvelopeTests {
    static let fade = #"""
    {"volume":{"type":"double","defaultValue":1.0,"keyframes":[
      {"time":0,"endTime":0,"value":0.0,"duration":0},
      {"time":1000,"endTime":1000,"value":1.0,"duration":0},
      {"time":3000,"endTime":3000,"value":1.0,"duration":0},
      {"time":4000,"endTime":4000,"value":0.0,"duration":0}]}}
    """#

    private func params(_ text: String) throws -> Parameters {
        Parameters(try #require(JSON.parse(Data(text.utf8)).object))
    }

    @Test func pointEnvelopeIsLinearBetweenPoints() throws {
        let p = try params(Self.fade)
        #expect(try #require(p["volume"]).isPointEnvelope)
        #expect(p.volume(at: -10) == 0)        // before the first point: its value (not defaultValue)
        #expect(p.volume(at: 500) == 0.5)      // fade in
        #expect(p.volume(at: 2000) == 1)
        #expect(p.volume(at: 3500) == 0.5)     // fade out
        #expect(p.volume(at: 5000) == 0)       // after the last point
    }

    @Test func windowKeyframesKeepTheWindowRule() throws {
        let p = try params(#"{"volume":{"type":"double","defaultValue":1.0,"keyframes":[{"time":0,"endTime":1000,"value":0.0,"interp":"linr"}]}}"#)
        #expect(try #require(p["volume"]).isPointEnvelope == false)
        #expect(p.volume(at: 500) == 0.5)
        #expect(try params(#"{"volume":0.25}"#).volume() == 0.25)
        #expect(try params("{}").volume() == 1)
    }
}
