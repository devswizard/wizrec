// The mix itself. Every node is rendered as a function of its own sample grid:
//
//   content(node)   on the node's media/inner axis, in blocks of `blockSize` samples aligned to
//                   media sample 0: decoded source (leaf) or the mix of its inner tracks
//                   (group / stitched), × loudness gain, → effects → mixToMono. Cached.
//   place(node)     on the parent axis: content shifted (speed 1, no pitch) or WSOLA-stretched
//                   (speed ≠ 1; a pitch shift p reads content resampled by p, then stretches),
//                   × gain × volume(media time) × transition fades.
//   mixTracks       sums the placed clips of the audible tracks; `emphasize` clips duck the
//                   other tracks at their level.
//
// Each output sample therefore depends only on the scene, never on how render ranges were cut.

import CoreMedia
import Foundation
import MediaEngine
import TSCProjKit

struct BlockKey: Hashable, Sendable {
    var node: Int
    var index: Int64
    /// Pre-effects content (only cached separately for nodes with effects).
    var raw: Bool
    /// Resampled content of a pitch-shifted node (`AudioMixer.source`).
    var pitched = false
}

/// A ducking window from an `emphasize` clip on track `track`: other tracks drop to `gain` over
/// `[lo, hi)` (parent ticks), ramping linearly over `ramp` ticks on each side [inf, until AU1].
struct Duck: Sendable {
    var track: Int
    var lo: Double
    var hi: Double
    var gain: Double

    /// 0.25 s at editRate 705600000 (ticks).
    static let ramp = 176_400_000.0

    func factor(at t: Double) -> Double {
        let x: Double
        if t >= lo && t < hi { x = 1 }
        else if t < lo { x = max(0, 1 - (lo - t) / Self.ramp) }
        else { x = max(0, 1 - (t - hi) / Self.ramp) }
        return 1 - (1 - gain) * x
    }
}

struct ChainKey: Hashable, Sendable {
    var node: Int
    var segment: Int64
}

struct StreamKey: Hashable, Sendable {
    var url: URL
    var stream: Int
}

/// LRU cache of content blocks with a byte budget.
struct BlockCache: Sendable {
    let limitBytes: Int
    private var entries: [BlockKey: (signal: Signal, use: UInt64)] = [:]
    private var clock: UInt64 = 0
    private(set) var bytes = 0

    init(limitBytes: Int) { self.limitBytes = limitBytes }

    var count: Int { entries.count }

    mutating func get(_ k: BlockKey) -> Signal? {
        guard let e = entries[k] else { return nil }
        clock += 1
        entries[k] = (e.signal, clock)
        return e.signal
    }

    mutating func put(_ k: BlockKey, _ s: Signal) {
        clock += 1
        if let old = entries[k] { bytes -= old.signal.bytes }
        entries[k] = (s, clock)
        bytes += s.bytes
        guard bytes > limitBytes else { return }
        let goal = limitBytes * 3 / 4
        for (key, e) in entries.sorted(by: { $0.value.use < $1.value.use }) {
            guard bytes > goal else { break }
            entries[key] = nil
            bytes -= e.signal.bytes
        }
    }

    mutating func removeAll() { entries.removeAll(); bytes = 0 }
}

extension AudioMixer {
    // MARK: Top level

    func renderMix(_ range: Range<Int64>) async throws -> PCMBuffer {
        let samples = grid.samples(range)
        let n = Int(samples.count)
        let out = PCMFormat(sampleRate: Double(grid.rate), channels: max(1, format.channels))
        let start = CMTime(value: samples.lowerBound, timescale: CMTimeScale(clamping: grid.rate))
        guard n > 0 else {
            return PCMBuffer(format: out, startTime: start, frameCount: 0,
                             channels: Array(repeating: [], count: out.channels))
        }
        var mix = try await mixTracks(scene.tracks, from: samples.lowerBound, count: n)
        mix.scale(by: Float(scene.masterGain))
        mix = mix.mapped(to: out.channels)
        clippedSamples += mix.countAbove(1)
        // No limiter (audio.md §2 working rule: normalisation gains are peak-capped instead); the
        // sum is hard-clipped to ±1 like any PCM output.
        mix.clip(to: 1)
        return PCMBuffer(format: out, startTime: start, frameCount: n, channels: mix.channels)
    }

    /// Sum of the audible tracks over samples `[from, from + count)` of their (shared) axis.
    /// Mute and solo: a muted track is silent; when any track at this level is soloed, only the
    /// soloed (unmuted) ones play [inf: Camtasia's solo isolates a track]. A clip with an
    /// `emphasize` effect ducks every *other* audible track at this level while it sounds.
    func mixTracks(_ tracks: [ATrack], from: Int64, count: Int) async throws -> Signal {
        var acc = Signal.zeros(channels: 1, count: count)
        let anySolo = tracks.contains { $0.solo && !$0.muted }
        let lo = grid.ticks(from), hi = grid.ticks(from + Int64(count))
        let audible = tracks.indices.filter { !tracks[$0].muted && (!anySolo || tracks[$0].solo) }
        let emphasis = audible.flatMap { i in
            tracks[i].clips.compactMap { c in
                c.effects.first { $0.kind == .emphasize }.map { Duck(track: i, lo: c.activeLo, hi: c.activeHi, gain: $0.duckGain) }
            }
        }
        for i in audible {
            let t = tracks[i]
            let clips = t.clips.filter { $0.activeLo < hi && $0.activeHi > lo }
            guard !clips.isEmpty else { continue }
            let ducks = emphasis.filter { $0.track != i && $0.lo - Duck.ramp < hi && $0.hi + Duck.ramp > lo }
            if ducks.isEmpty {
                for c in clips { try await place(c, into: &acc, from: from) }
            } else {
                var own = Signal.zeros(channels: 1, count: count)
                for c in clips { try await place(c, into: &own, from: from) }
                var env = [Float](repeating: 1, count: count)
                for k in 0..<count {
                    let tk = grid.ticks(from + Int64(k))
                    env[k] = Float(ducks.reduce(1.0) { min($0, $1.factor(at: tk)) })
                }
                acc.add(own, at: 0, gain: env)
            }
        }
        return acc
    }

    // MARK: Placement on the parent axis

    func place(_ n: ANode, into acc: inout Signal, from: Int64) async throws {
        let a = max(from, grid.sampleCeil(n.activeLo))
        let b = min(from + Int64(acc.count), grid.sampleCeil(n.activeHi))
        guard a < b else { return }
        let count = Int(b - a)
        let sig: Signal
        if n.isPlain {
            let shift = Int64(((n.mediaStart.double - Double(n.start)) / grid.ticksPerSample).rounded())
            sig = try await content(n, from: a + shift, count: count)
        } else {
            sig = try await stretched(n, from: a, count: count)
        }
        if let env = envelope(n, from: a, count: count) {
            acc.add(sig, at: Int(a - from), gain: env)
        } else {
            acc.add(sig, at: Int(a - from), scale: Float(n.gain * (n.volume?.constant ?? 1)))
        }
    }

    /// Per-sample gain × volume × fades, or nil when constant over the span (then gain × volume).
    func envelope(_ n: ANode, from a: Int64, count: Int) -> [Float]? {
        let lo = grid.ticks(a), hi = grid.ticks(a + Int64(count))
        let fades = n.fades.filter { f in f.fadeIn ? lo < f.hi : hi > f.lo }
        let animated = n.volume?.isAnimated ?? false
        guard animated || !fades.isEmpty else { return nil }
        var env = [Float](repeating: 0, count: count)
        let constant = n.volume?.constant ?? 1
        for i in 0..<count {
            let t = grid.ticks(a + Int64(i))
            var g = n.gain
            g *= animated ? (n.volume?.value(at: n.mediaTicks(at: t)) ?? 1) : constant
            for f in fades { g *= f.gain(at: t) }
            env[i] = Float(g)
        }
        return env
    }

    // MARK: Content on the node's own axis

    /// Content samples `[from, from + count)` (media / inner axis).
    func content(_ n: ANode, from: Int64, count: Int) async throws -> Signal {
        try await assemble(from: from, count: count) { b in try await self.contentBlock(n, b) }
    }

    func assemble(from: Int64, count: Int, block: (Int64) async throws -> Signal) async throws -> Signal {
        let B = Int64(blockSize)
        let first = floorDiv(from, B), last = floorDiv(from + Int64(count) - 1, B)
        if first == last {
            let s = try await block(first)
            return s.slice(Int(from - first * B), count)
        }
        var out = Signal.zeros(channels: 1, count: count)
        for b in first...last {
            let s = try await block(b)
            let lo = max(from, b * B), hi = min(from + Int64(count), (b + 1) * B)
            out.write(s.slice(Int(lo - b * B), Int(hi - lo)), at: Int(lo - from))
        }
        return out
    }

    func contentBlock(_ n: ANode, _ b: Int64) async throws -> Signal {
        let key = BlockKey(node: n.key, index: b, raw: false)
        if let s = blocks.get(key) { return s }
        let procs = processors(n)
        var sig: Signal
        if procs.isEmpty {
            sig = try await rawBlock(n, b)
        } else {
            let hist = procs.reduce(0) { $0 + $1.history }, ahead = procs.reduce(0) { $0 + $1.lookahead }
            let B = Int64(blockSize)
            var start = b * B - Int64(hist), end = (b + 1) * B + Int64(ahead)
            sig = try await assemble(from: start, count: Int(end - start)) { i in
                let rk = BlockKey(node: n.key, index: i, raw: true)
                if let s = self.blocks.get(rk) { return s }
                let s = try await self.rawBlock(n, i)
                self.blocks.put(rk, s)
                return s
            }
            for p in procs {
                let os = start + Int64(p.history), oe = end - Int64(p.lookahead)
                sig = p.process(sig, outputStart: os, count: Int(oe - os))
                start = os; end = oe
            }
        }
        if n.mixToMono { sig = sig.monoMix() }
        blocks.put(key, sig)
        return sig
    }

    /// Pre-effects content block `b`.
    func rawBlock(_ n: ANode, _ b: Int64) async throws -> Signal {
        let B = Int64(blockSize)
        switch n.body {
        case .container(let tracks):
            return try await mixTracks(tracks, from: b * B, count: blockSize)
        case .leaf(let url, let stream, let channels, let loudness):
            var sig = try await decode(url: url, stream: stream, from: b * B, count: blockSize)
            // `channelNumber` = the source channels the clip uses ("0", "0,1") [obs].
            if let channels, channels != Array(0..<sig.channelCount) {
                let picked = channels.filter { $0 < sig.channelCount }.map { sig.channels[$0] }
                if !picked.isEmpty { sig = Signal(channels: picked, count: sig.count) }
            }
            if loudness != nil {
                sig.scale(by: Float(try await loudnessGain(n)))
            }
            return sig
        }
    }

    /// Source samples `[from, from + count)` at the mix rate (stream time = sample / rate), native
    /// channel count. Missing or unsupported media → silence.
    func decode(url: URL, stream: Int, from: Int64, count: Int) async throws -> Signal {
        let rate = CMTimeScale(clamping: grid.rate)
        do {
            let src = try await pool.source(for: url)
            let sk = StreamKey(url: url, stream: stream)
            let ch: Int
            if let c = sourceChannels[sk] { ch = c } else {
                guard let s = src.info.streams.first(where: { $0.index == stream && $0.kind == .audio })
                else { throw MediaError.noSuchStream(stream) }
                ch = max(1, s.channelCount)
                sourceChannels[sk] = ch
            }
            let range = CMTimeRange(start: CMTime(value: from, timescale: rate),
                                    duration: CMTime(value: Int64(count), timescale: rate))
            let pcm = try await src.audio(stream: stream, range: range,
                                          format: PCMFormat(sampleRate: Double(grid.rate), channels: ch))
            var sig = Signal(channels: pcm.channels, count: count)
            if pcm.frameCount != count || pcm.channels.contains(where: { $0.count != count }) {
                var fixed = Signal.zeros(channels: max(1, pcm.channels.count), count: count)
                for c in 0..<pcm.channels.count {
                    let m = min(count, pcm.channels[c].count)
                    fixed.channels[c].replaceSubrange(0..<m, with: pcm.channels[c][0..<m])
                }
                sig = fixed
            }
            return sig
        } catch let e as MediaError {
            switch e {
            case .fileNotFound, .unsupported, .noSuchStream:
                missingReads += 1
                return Signal.zeros(channels: 1, count: count)
            default:
                throw AudioError.decodeFailed("\(url.lastPathComponent): \(e)")
            }
        } catch let e as AudioError {
            throw e
        } catch {
            throw AudioError.decodeFailed("\(url.lastPathComponent): \(error)")
        }
    }

    // MARK: Speed ≠ 1 (WSOLA, Stretch.swift)

    /// Analysis position of output sample `s` for a stretched node, on the axis `source` reads:
    /// content samples, or resampled-content samples (÷ pitch) for a pitch-shifted node.
    func analysisPosition(_ n: ANode, _ s: Int64) -> Int64 {
        Int64((n.mediaTicks(at: grid.ticks(s)) / grid.ticksPerSample / n.pitch).rounded())
    }

    /// What WSOLA reads: the node's content, or for a pitch shift p the content resampled so that
    /// sample k = content at k·p (frequencies × p, running p× faster). WSOLA then restores the
    /// duration, so pitch and speed compose: pitch shift = resample + time-stretch.
    func source(_ n: ANode, from: Int64, count: Int) async throws -> Signal {
        guard n.pitch != 1 else { return try await content(n, from: from, count: count) }
        return try await assemble(from: from, count: count) { b in try await self.pitchedBlock(n, b) }
    }

    /// Block `b` of the resampled content (cached; a pure function of the scene).
    func pitchedBlock(_ n: ANode, _ b: Int64) async throws -> Signal {
        let key = BlockKey(node: n.key, index: b, raw: false, pitched: true)
        if let s = blocks.get(key) { return s }
        let B = Int64(blockSize), from = b * B
        let p = n.pitch, w = Resampler.halfWidth(pitch: p)
        let lo = Int64((Double(from) * p).rounded(.down)) - Int64(w) - 1
        let hi = Int64((Double(from + B) * p).rounded(.up)) + Int64(w) + 2
        let c = try await content(n, from: lo, count: Int(hi - lo))
        let s = Resampler.resample(c, inputStart: lo, ratio: p, from: from, count: blockSize)
        blocks.put(key, s)
        return s
    }

    func stretched(_ n: ANode, from s0: Int64, count: Int) async throws -> Signal {
        let st = stretcher
        let hop = Int64(st.hop), half = Int64(st.window / 2)
        let n0 = grid.sampleCeil(n.activeLo)
        let s1 = s0 + Int64(count)
        let kLo = floorDiv(s0 - n0 - half, hop), kHi = floorDiv(s1 - 1 - n0 + half, hop)
        func center(_ k: Int64) -> Int64 { n0 + k * hop }
        var offsets: [Int64: Int] = [:]
        // Extend the δ chain to kHi first (64-frame batches); the per-frame calls then hit the cache.
        _ = try await offset(n, frame: kHi, n0: n0)
        for k in kLo...kHi { offsets[k] = try await offset(n, frame: k, n0: n0) }
        let tol = Int64(st.tolerance)
        let inLo = analysisPosition(n, center(kLo)) - tol - half - 1
        let inHi = analysisPosition(n, center(kHi)) + tol + half + 1
        let input = try await source(n, from: inLo, count: Int(inHi - inLo))
        var out = Signal.zeros(channels: input.channelCount, count: count)
        for k in kLo...kHi {
            let pos = analysisPosition(n, center(k)) + Int64(offsets[k] ?? 0)
            st.addFrame(center: center(k), pos: pos, input: input, inStart: inLo, into: &out, outStart: s0)
        }
        return out
    }

    /// δ of frame `k` (WSOLA chain, restarted every `segmentFrames`).
    func offset(_ n: ANode, frame k: Int64, n0: Int64) async throws -> Int {
        let st = stretcher
        let R = Int64(st.segmentFrames)
        let g = floorDiv(k, R)
        let key = ChainKey(node: n.key, segment: g)
        var chain = chains[key] ?? []
        let first = g * R
        if chain.isEmpty { chain = [0] }
        let hop = Int64(st.hop), half = Int64(st.window / 2), tol = Int64(st.tolerance)
        func pos(_ j: Int64) -> Int64 { analysisPosition(n, n0 + j * hop) }
        while first + Int64(chain.count) <= k {
            // Extend in batches; one content read per batch.
            let jStart = first + Int64(chain.count)
            let jEnd = min(k, jStart + 63)
            let lo = pos(jStart - 1) - tol - half - 1
            let hi = pos(jEnd) + tol + hop + half + 2
            let mono = try await source(n, from: lo, count: Int(hi - lo)).monoMix().channels[0]
            mono.withUnsafeBufferPointer { mp in
                guard let base = mp.baseAddress else { return }
                for j in jStart...jEnd {
                    let prev = pos(j - 1) + Int64(chain[Int(j - 1 - first)])
                    let tStart = prev + hop - half - lo
                    let rStart = pos(j) - tol - half - lo
                    guard tStart >= 0, rStart >= 0,
                          tStart + Int64(st.window) <= Int64(mono.count),
                          rStart + Int64(st.window) + 2 * tol <= Int64(mono.count)
                    else { chain.append(0); continue }
                    chain.append(st.bestOffset(template: base + Int(tStart), region: base + Int(rStart)))
                }
            }
        }
        chains[key] = chain
        return chain[Int(k - first)]
    }

    // MARK: Effects and loudness (Effects.swift, LoudnessGain.swift)

    func processors(_ n: ANode) -> [any AudioProcessor] {
        if let p = processorCache[n.key] { return p }
        let p = n.effects.compactMap { EffectRegistry.processor(for: $0, sampleRate: Double(grid.rate)) }
        processorCache[n.key] = p
        return p
    }
}
