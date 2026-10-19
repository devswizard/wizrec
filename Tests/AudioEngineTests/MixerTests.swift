import CoreMedia
import Foundation
import MediaEngine
import Testing
import TSCProjKit
@testable import AudioEngine

/// A 48 kHz mono WAV holding `seconds` of a sine (default 440 Hz, amplitude 0.5).
private func sineFile(_ dir: URL, _ name: String = "tone.wav", seconds: Double = 6, freq: Double = 440,
                      amp: Double = 0.5, rate: Int = 48_000) throws -> URL {
    let u = dir.appendingPathComponent(name)
    try Synth.wav(u, rate: rate, channels: 1, frames: Int(seconds * Double(rate)),
                  Synth.sine(freq: freq, amp: amp, rate: rate))
    return u
}

/// Source sample i of `sineFile`.
private func tone(_ i: Int, freq: Double = 440, amp: Double = 0.5) -> Float {
    Float(amp * sin(2 * Double.pi * freq * Double(i) / 48_000))
}

@Test func leafClipPlaysSourceSamplesExactly() async throws {
    let dir = try Synth.tempDir()
    let u = try sineFile(dir)
    // Clip at 1 s for 2 s, starting 0.5 s into the media.
    let p = try P.project(tracks: [P.track(0, [
        P.clip("AMFile", id: 10, src: 1, start: sec(1), duration: sec(2), mediaStart: sec(0.5)),
    ])], sources: [P.source(1, u)])
    let mixer = P.mixer(p)
    let buf = try await mixer.render(0 ..< sec(4))
    #expect(buf.frameCount == idx(4))
    #expect(buf.channels.count == 2)
    #expect(buf.startTime == CMTime(value: 0, timescale: 48_000))
    let l = buf.channels[0], r = buf.channels[1]
    #expect(l[0 ..< idx(1)].allSatisfy { $0 == 0 })
    #expect(l[idx(3)...].allSatisfy { $0 == 0 })
    for k in stride(from: 0, to: idx(2), by: 97) {
        #expect(l[idx(1) + k] == tone(idx(0.5) + k))
    }
    #expect(l == r)  // mono source → both channels
}

@Test func gainVolumeAndGroupGainMultiply() async throws {
    let dir = try Synth.tempDir()
    let u = try sineFile(dir)
    let g = P.clip("Group", id: 40, start: 0, duration: sec(2), mediaStart: 0.0, parameters: ["volume": 0.8],
                   attributes: ["gain": 0.5], extra: [
        "tracks": [P.track(0, [P.clip("AMFile", id: 41, src: 1, start: 0, duration: sec(2),
                                      parameters: ["volume": 0.5], attributes: ["gain": 0.5])],
                           extra: ["audioMuted": false, "solo": false])],
    ])
    let p = try P.project(tracks: [P.track(0, [g])], sources: [P.source(1, u)], timelineGain: 0.5)
    let buf = try await P.mixer(p).render(0 ..< sec(1))
    // group gain × group volume × clip gain × clip volume × timeline gain.
    let k = 0.5 * 0.8 * 0.5 * 0.5 * 0.5
    for i in stride(from: 1, to: idx(1), by: 211) {
        #expect(abs(Double(buf.channels[0][i]) - k * Double(tone(i))) < 1e-6)
    }
    #expect(abs(rms(buf.channels[0][0...]) - k * 0.5 / 2.squareRoot()) < 1e-3)
}

@Test func volumeKeyframesAreOnTheMediaAxis() async throws {
    let dir = try Synth.tempDir()
    let u = try sineFile(dir)
    // Clip at 2 s, mediaStart 1 s: keyframe 1 s → 2 s (media time) ramps 0 → 1 over timeline 2 s → 3 s.
    let vol = P.keyframed(0, [(sec(1), sec(2), 1.0)])
    let p = try P.project(tracks: [P.track(0, [
        P.clip("AMFile", id: 10, src: 1, start: sec(2), duration: sec(3), mediaStart: sec(1), parameters: ["volume": vol]),
    ])], sources: [P.source(1, u)])
    let buf = try await P.mixer(p).render(0 ..< sec(5))
    let x = buf.channels[0]
    for s in [2.1, 2.5, 2.75, 3.5, 4.2] {
        let i = idx(s)
        let m = idx(s - 1)  // media sample
        let v = min(1, max(0, s - 2))
        #expect(abs(Double(x[i]) - v * Double(tone(m))) < 1e-5, "t=\(s)")
    }
}

@Test func renderIsChunkSeamlessAndDeterministic() async throws {
    let dir = try Synth.tempDir()
    let u = try sineFile(dir, seconds: 12)
    let v = try sineFile(dir, "b.wav", seconds: 12, freq: 660, amp: 0.3)
    let tracks = [
        P.track(0, [
            P.clip("AMFile", id: 10, src: 1, start: 0, duration: sec(3), mediaStart: sec(0.25),
                   parameters: ["volume": P.keyframed(1, [(sec(1), sec(2), 0.2)], interp: "eioe")]),
            P.clip("AMFile", id: 11, src: 2, start: sec(3), duration: sec(3)),
        ], transitions: [["name": "Fade", "duration": sec(0.5), "leftMedia": 10, "rightMedia": 11,
                          "trivial": false, "reverse": false, "bypass": false,
                          "useAudioPreRoll": true, "useVisualPreRoll": true]]),
        // A 1.5× clip (scalar 2/3): WSOLA path.
        P.track(1, [P.clip("AMFile", id: 20, src: 2, start: sec(1), duration: sec(4), mediaStart: 0,
                           mediaDuration: sec(6), scalar: "2/3")]),
    ]
    let p = try P.project(tracks: tracks, sources: [P.source(1, u), P.source(2, v)])
    let whole = try await P.mixer(p).render(0 ..< sec(7))
    // Odd chunk edges, including ones that are not on the sample grid.
    let cuts: [Int64] = [0, 12_345_678, sec(1) + 7, sec(2.5), sec(2.5) + 14_700, sec(3.1), sec(4.99), sec(7)]
    let m2 = P.mixer(p)
    var joined: [[Float]] = [[], []]
    for i in 0 ..< cuts.count - 1 {
        let b = try await m2.render(cuts[i] ..< cuts[i + 1])
        for c in 0 ..< 2 { joined[c] += b.channels[c] }
    }
    #expect(joined[0].count == whole.frameCount)
    if let d = zip(joined[0], whole.channels[0]).enumerated().first(where: { $0.element.0 != $0.element.1 }) {
        Issue.record("first diff at \(d.offset) (\(Double(d.offset) / 48_000) s): \(d.element.0) vs \(d.element.1)")
    }
    #expect(joined == whole.channels)
    // Reverse order on a fresh mixer: same samples.
    let m3 = P.mixer(p)
    let late = try await m3.render(sec(4) ..< sec(7))
    let early = try await m3.render(0 ..< sec(4))
    #expect(early.channels[0] + late.channels[0] == whole.channels[0])
}

@Test func muteAndSolo() async throws {
    let dir = try Synth.tempDir()
    let a = try sineFile(dir, "a.wav", freq: 440)
    let b = try sineFile(dir, "b.wav", freq: 1000)
    let tracks = [
        P.track(0, [P.clip("AMFile", id: 1, src: 1, start: 0, duration: sec(1))]),
        P.track(1, [P.clip("AMFile", id: 2, src: 2, start: 0, duration: sec(1))]),
    ]
    let sources = [P.source(1, a), P.source(2, b)]
    func render(_ attrs: [[String: Any]]) async throws -> [Float] {
        let p = try P.project(tracks: tracks, sources: sources, trackAttributes: attrs)
        return try await P.mixer(p).render(0 ..< sec(1)).channels[0]
    }
    let both = try await render([["audioMuted": false, "solo": false], ["audioMuted": false, "solo": false]])
    let muted = try await render([["audioMuted": true, "solo": false], ["audioMuted": false, "solo": false]])
    let solo = try await render([["audioMuted": false, "solo": true], ["audioMuted": false, "solo": false]])
    #expect(abs(frequency(muted[1000...], rate: 48_000) - 1000) < 2)
    #expect(abs(frequency(solo[1000...], rate: 48_000) - 440) < 1)
    #expect(rms(both[0...]) > rms(solo[0...]))
}

@Test func stitchedSegmentsAndOuterGain() async throws {
    let dir = try Synth.tempDir()
    let u = try sineFile(dir, seconds: 10)
    // Two segments of one source: media 1–2 s then 5–6 s, laid end to end on the inner timeline.
    func stitched(gain: Double) -> [String: Any] {
        P.clip("StitchedMedia", id: 50, start: sec(1), duration: sec(2), parameters: ["volume": 1.0],
               attributes: ["gain": gain], extra: ["minMediaStart": 0.0, "medias": [
                   P.clip("AMFile", id: 51, src: 1, start: 0, duration: sec(1), mediaStart: sec(1)),
                   P.clip("AMFile", id: 52, src: 1, start: sec(1), duration: sec(1), mediaStart: sec(5)),
               ]])
    }
    let p = try P.project(tracks: [P.track(0, [stitched(gain: 1)])], sources: [P.source(1, u)])
    let x = try await P.mixer(p).render(0 ..< sec(3)).channels[0]
    #expect(x[idx(1) + 10] == tone(idx(1) + 10))
    #expect(x[idx(2) + 10] == tone(idx(5) + 10))
    // gain 0.0 on the outer clip silences segments whose own gain is 1 (defaults.md).
    let q = try P.project(tracks: [P.track(0, [stitched(gain: 0)])], sources: [P.source(1, u)])
    let y = try await P.mixer(q).render(0 ..< sec(3)).channels[0]
    #expect(y.allSatisfy { $0 == 0 })
}

@Test func speedChangeKeepsPitchAndMapsTime() async throws {
    let dir = try Synth.tempDir()
    let u = try sineFile(dir, seconds: 10)
    // 2× (scalar 1/2): 4 s of media in 2 s; 0.5× (scalar 2): 1 s of media in 2 s.
    for (scalar, mediaDur) in [("1/2", sec(4)), ("2", sec(1))] {
        let p = try P.project(tracks: [P.track(0, [
            P.clip("AMFile", id: 1, src: 1, start: sec(0.5), duration: sec(2), mediaStart: sec(1),
                   mediaDuration: mediaDur, scalar: scalar),
        ])], sources: [P.source(1, u)])
        let x = try await P.mixer(p).render(0 ..< sec(3)).channels[0]
        #expect(x[0 ..< idx(0.5)].allSatisfy { $0 == 0 })
        #expect(x[idx(2.5)...].allSatisfy { $0 == 0 })
        let body = x[idx(0.6) ..< idx(2.4)]
        #expect(abs(frequency(body, rate: 48_000) - 440) < 1.5, "scalar \(scalar)")
        #expect(abs(rms(body) - 0.5 / 2.squareRoot()) < 0.03, "scalar \(scalar)")
    }
}

@Test func transitionCrossfadesCentredOnTheCut() async throws {
    let dir = try Synth.tempDir()
    let a = try sineFile(dir, "a.wav", freq: 440)
    let b = try sineFile(dir, "b.wav", freq: 1000)
    let p = try P.project(tracks: [P.track(0, [
        P.clip("AMFile", id: 1, src: 1, start: 0, duration: sec(2)),
        P.clip("AMFile", id: 2, src: 2, start: sec(2), duration: sec(2), mediaStart: sec(1)),
    ], transitions: [["name": "Fade", "duration": sec(1), "leftMedia": 1, "rightMedia": 2, "bypass": false,
                      "useAudioPreRoll": true],
                     ["name": "Fade", "duration": sec(0.5), "rightMedia": 1, "bypass": false]])],
    sources: [P.source(1, a), P.source(2, b)])
    let x = try await P.mixer(p).render(0 ..< sec(4)).channels[0]
    // Fade-in on the first clip: 0 → 1 over 0–0.5 s.
    #expect(abs(Double(x[idx(0.25)]) - 0.5 * Double(tone(idx(0.25)))) < 1e-5)
    // Window 1.5–2.5 s: at 2.0 s both clips at 0.5; the right clip rolls back 0.5 s into its media.
    for s in [1.6, 2.0, 2.3] {
        let w = (s - 1.5)
        let e = (1 - w) * Double(tone(idx(s))) + w * Double(tone(idx(s - 2 + 1), freq: 1000))
        #expect(abs(Double(x[idx(s)]) - e) < 1e-5, "t=\(s)")
    }
    #expect(x[idx(3)] == tone(idx(2), freq: 1000))
}

@Test func unifiedAudioChildChannelsAndMono() async throws {
    let dir = try Synth.tempDir()
    let u = dir.appendingPathComponent("st.wav")
    try Synth.wav(u, rate: 48_000, channels: 2, frames: 48_000 * 2) { c, i in
        c == 0 ? tone(i) : tone(i, freq: 1000, amp: 0.25)
    }
    let src = P.source(1, u, channels: 2)
    func render(_ channelNumber: String, mono: Bool) async throws -> PCMBuffer {
        let unified = P.clip("UnifiedMedia", id: 5, start: 0, duration: sec(1), extra: [
            "video": P.clip("VMFile", id: 6, src: 1, start: 0, duration: sec(1)),
            "audio": P.clip("AMFile", id: 7, src: 1, start: 0, duration: sec(1),
                            attributes: ["gain": 1.0, "mixToMono": mono], channelNumber: channelNumber),
        ])
        let p = try P.project(tracks: [P.track(0, [unified])], sources: [src])
        return try await P.mixer(p).render(0 ..< sec(1))
    }
    let stereo = try await render("0,1", mono: false)
    #expect(stereo.channels[0][100] == tone(100))
    #expect(stereo.channels[1][100] == tone(100, freq: 1000, amp: 0.25))
    let left = try await render("0", mono: false)
    #expect(left.channels[1][100] == tone(100))
    let mono = try await render("0,1", mono: true)
    #expect(abs(mono.channels[1][100] - (tone(100) + tone(100, freq: 1000, amp: 0.25)) / 2) < 1e-7)
}

@Test func resamplesOtherSourceRates() async throws {
    let dir = try Synth.tempDir()
    let u = try sineFile(dir, "t44.wav", seconds: 3, freq: 1000, amp: 0.5, rate: 44_100)
    let p = try P.project(tracks: [P.track(0, [P.clip("AMFile", id: 1, src: 1, start: 0, duration: sec(2))])],
                          sources: [P.source(1, u)])
    let x = try await P.mixer(p).render(0 ..< sec(2)).channels[0]
    #expect(abs(frequency(x[1000 ..< 90_000], rate: 48_000) - 1000) < 0.5)
    #expect(abs(rms(x[1000 ..< 90_000]) - 0.5 / 2.squareRoot()) < 2e-3)
}

@Test func missingMediaIsSilent() async throws {
    let p = try P.project(tracks: [P.track(0, [P.clip("AMFile", id: 1, src: 1, start: 0, duration: sec(1))])],
                          sources: [P.source(1, URL(fileURLWithPath: "/nonexistent/x.wav"))])
    let b = try await P.mixer(p).render(0 ..< sec(1))
    #expect(b.channels[0].allSatisfy { $0 == 0 })
}
