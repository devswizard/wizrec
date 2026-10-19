import Foundation

/// A parsed SRT or WebVTT file that keeps what `CaptionCue` drops (cue identifiers, VTT cue
/// settings, inline markup, `NOTE`/`STYLE`/`REGION` blocks), so `text(_:)` reproduces the file.
/// Times are seconds. Line endings are normalised to `\n` and a leading BOM is dropped.
public struct SubtitleDocument: Sendable, Equatable {
    public enum Format: Sendable, Equatable { case srt, vtt }

    /// One cue as written in the file.
    public struct Cue: Sendable, Equatable {
        /// SRT index or VTT cue identifier, verbatim (nil when absent).
        public var identifier: String?
        /// Seconds.
        public var start: Double
        public var end: Double
        /// VTT cue settings (`align:start line:0`) or SRT coordinates (`X1:… Y1:…`), verbatim.
        public var settings: String
        /// Payload lines joined with `\n`, markup kept (`<i>`, `<v Bob>`, `{\an8}`, entities).
        public var rawText: String

        public init(identifier: String? = nil, start: Double, end: Double, settings: String = "", rawText: String) {
            self.identifier = identifier; self.start = start; self.end = end; self.settings = settings
            self.rawText = rawText
        }

        /// The payload as plain text: tags and SRT `{\…}` overrides removed, VTT entities decoded.
        public var plainText: String { SubtitleMarkup.plain(rawText) }
    }

    /// Blocks in file order.
    public enum Block: Sendable, Equatable {
        case cue(Cue)
        /// A VTT `NOTE`, `STYLE` or `REGION` block, verbatim (all its lines).
        case other(String)
    }

    public var format: Format
    /// VTT: the text after `WEBVTT` on the first line plus any header lines before the first blank line.
    public var header: String
    public var blocks: [Block]

    public init(format: Format, header: String = "", blocks: [Block]) {
        self.format = format; self.header = header; self.blocks = blocks
    }

    public var cues: [Cue] { blocks.compactMap { if case .cue(let c) = $0 { c } else { nil } } }

    /// Plain-text cues, in file order.
    public var captionCues: [CaptionCue] { cues.map { CaptionCue(start: $0.start, end: $0.end, text: $0.plainText) } }

    // MARK: Parsing

    /// Parses SRT. Tolerates a BOM, CRLF/CR line endings, missing or wrong indices, `.` instead of
    /// `,` before the milliseconds, extra blank lines and a missing blank line between cues.
    public static func parseSRT(_ text: String) throws -> SubtitleDocument {
        let all = lines(of: text)
        let timings = all.indices.compactMap { i in timing(all[i], vtt: false).map { (i, $0) } }
        guard !timings.isEmpty else {
            if all.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                return SubtitleDocument(format: .srt, blocks: [])
            }
            throw CaptionsError.parse("no SRT cues found")
        }
        func blank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespaces).isEmpty }
        var blocks: [Block] = []
        for (j, (k, t)) in timings.enumerated() {
            let next = j + 1 < timings.count ? timings[j + 1].0 : all.count
            var body = Array(all[(k + 1)..<next])
            // The next cue's index line belongs to it, not to this cue's text.
            if j + 1 < timings.count, let last = body.last, isIndex(last) { body.removeLast() }
            while let l = body.last, blank(l) { body.removeLast() }
            var id: String?
            if k > 0, isIndex(all[k - 1]) { id = all[k - 1].trimmingCharacters(in: .whitespaces) }
            blocks.append(.cue(Cue(identifier: id, start: t.start, end: t.end, settings: t.settings,
                                   rawText: body.joined(separator: "\n"))))
        }
        return SubtitleDocument(format: .srt, blocks: blocks)
    }

    /// Parses WebVTT. Requires the `WEBVTT` signature (after an optional BOM). Cue identifiers,
    /// settings, markup and NOTE/STYLE/REGION blocks are kept; timestamps may omit hours.
    public static func parseVTT(_ text: String) throws -> SubtitleDocument {
        let all = lines(of: text)
        guard let first = all.first, first.hasPrefix("WEBVTT"),
              first.count == 6 || first.dropFirst(6).first == " " || first.dropFirst(6).first == "\t"
        else { throw CaptionsError.parse("missing WEBVTT signature") }
        var header = String(first.dropFirst(6))
        if header.first == " " || header.first == "\t" { header.removeFirst() }
        var i = 1
        while i < all.count, !all[i].isEmpty { header += "\n" + all[i]; i += 1 }
        // Split the rest into blank-line separated blocks.
        var groups: [[String]] = []
        var g: [String] = []
        for line in all[min(i, all.count)...] {
            if line.isEmpty { if !g.isEmpty { groups.append(g); g = [] } } else { g.append(line) }
        }
        if !g.isEmpty { groups.append(g) }
        var blocks: [Block] = []
        for g in groups {
            if let ti = g.firstIndex(where: { $0.contains("-->") }), ti <= 1, let t = timing(g[ti], vtt: true) {
                blocks.append(.cue(Cue(identifier: ti == 1 ? g[0] : nil, start: t.start, end: t.end,
                                       settings: t.settings, rawText: g[(ti + 1)...].joined(separator: "\n"))))
            } else if let w = g.first, ["NOTE", "STYLE", "REGION"].contains(where: { w == $0 || w.hasPrefix($0 + " ") || w.hasPrefix($0 + "\t") }) {
                blocks.append(.other(g.joined(separator: "\n")))
            } else {
                throw CaptionsError.parse("malformed VTT block: \(g.first ?? "")")
            }
        }
        return SubtitleDocument(format: .vtt, header: header, blocks: blocks)
    }

    // MARK: Writing

    /// The document as text in `format` (its own format by default). Converting VTT to SRT drops
    /// non-cue blocks and cue settings, and renumbers cues; SRT to VTT keeps numeric identifiers.
    public func text(_ format: Format? = nil) -> String {
        let f = format ?? self.format
        var out = ""
        switch f {
        case .srt:
            var n = 0
            for case .cue(let c) in blocks {
                n += 1
                let id = self.format == .srt ? (c.identifier ?? String(n)) : String(n)
                let settings = self.format == .srt && !c.settings.isEmpty ? " " + c.settings : ""
                out += "\(id)\n\(Self.stamp(c.start, srt: true)) --> \(Self.stamp(c.end, srt: true))\(settings)\n"
                out += c.rawText.isEmpty ? "\n" : c.rawText + "\n\n"
            }
        case .vtt:
            out = "WEBVTT" + (header.isEmpty ? "" : (header.hasPrefix("\n") ? header : " " + header)) + "\n\n"
            for b in blocks {
                switch b {
                case .other(let s): out += s + "\n\n"
                case .cue(let c):
                    if let id = c.identifier { out += id + "\n" }
                    let settings = self.format == .vtt && !c.settings.isEmpty ? " " + c.settings : ""
                    out += "\(Self.stamp(c.start, srt: false)) --> \(Self.stamp(c.end, srt: false))\(settings)\n"
                    out += c.rawText.isEmpty ? "\n" : c.rawText + "\n\n"
                }
            }
        }
        while out.hasSuffix("\n\n") { out.removeLast() }
        return out
    }

    // MARK: Helpers

    static func lines(of text: String) -> [String] {
        var s = text
        if s.hasPrefix("\u{FEFF}") { s.removeFirst() }
        // Swift treats "\r\n" as one Character; normalise both CRLF and lone CR.
        s = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return s.components(separatedBy: "\n")
    }

    static func isIndex(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        return !t.isEmpty && t.allSatisfy(\.isASCII) && t.allSatisfy(\.isNumber)
    }

    /// `start --> end [settings]`.
    static func timing(_ line: String, vtt: Bool) -> (start: Double, end: Double, settings: String)? {
        guard let arrow = line.range(of: "-->") else { return nil }
        let a = line[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
        let rest = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
        let endField = rest.prefix { !$0.isWhitespace }
        let settings = rest.dropFirst(endField.count).trimmingCharacters(in: .whitespaces)
        guard let s = seconds(a), let e = seconds(String(endField)) else { return nil }
        return (s, e, settings)
    }

    /// `[[h]h:]mm:ss[,.]mmm` (also accepts fewer millisecond digits and a missing fraction).
    static func seconds(_ s: String) -> Double? {
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        let secField = parts[parts.count - 1].replacingOccurrences(of: ",", with: ".")
        let nums = parts.dropLast().map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard nums.allSatisfy({ $0 != nil && $0! >= 0 }), let sec = Double(secField), sec >= 0,
              secField.first?.isNumber == true else { return nil }
        let hm = nums.compactMap { $0 }
        let h = hm.count == 2 ? hm[0] : 0, m = hm.count == 2 ? hm[1] : hm[0]
        return Double(h * 3600 + m * 60) + sec
    }

    /// `HH:MM:SS,mmm` (SRT) or `HH:MM:SS.mmm` (VTT); rounded to the millisecond.
    static func stamp(_ t: Double, srt: Bool) -> String {
        let ms = max(0, Int64((t * 1000).rounded()))
        let h = ms / 3_600_000, m = ms / 60_000 % 60, s = ms / 1000 % 60, f = ms % 1000
        func pad(_ v: Int64, _ n: Int) -> String { let x = String(v); return String(repeating: "0", count: max(0, n - x.count)) + x }
        return "\(pad(h, 2)):\(pad(m, 2)):\(pad(s, 2))\(srt ? "," : ".")\(pad(f, 3))"
    }
}

/// Markup handling for cue payloads.
enum SubtitleMarkup {
    /// Strips `<…>` tags and SRT `{\…}` overrides, decodes the VTT/HTML entities.
    static func plain(_ raw: String) -> String {
        var out = ""
        var i = raw.startIndex
        while i < raw.endIndex {
            let c = raw[i]
            if c == "<", let close = raw[i...].firstIndex(of: ">") {
                i = raw.index(after: close); continue
            }
            if c == "{", raw[raw.index(after: i)...].first == "\\", let close = raw[i...].firstIndex(of: "}") {
                i = raw.index(after: close); continue
            }
            out.append(c); i = raw.index(after: i)
        }
        return decodeEntities(out)
    }

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        return s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: "\u{00A0}").replacingOccurrences(of: "&lrm;", with: "\u{200E}")
            .replacingOccurrences(of: "&rlm;", with: "\u{200F}").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Escapes plain text for a VTT payload (`&`, `<`, `>`), and breaks any `-->`.
    static func escapeVTT(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

extension SubtitleFile {
    /// Cue text made safe for a payload: CRLF normalised, blank lines (which would end the cue) removed,
    /// and `-->` (which would start a timing line) shortened to `->`.
    static func payload(_ text: String) -> String {
        SubtitleDocument.lines(of: text).map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "-->", with: "->") }
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
