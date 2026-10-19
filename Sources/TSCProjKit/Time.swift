import Foundation

/// Exact rational number. Camtasia stores some values as `"num/den"` strings:
/// clip speed (`"scalar": "304/457"`), media durations after a speed change
/// (`"13771788800000/113"`) and frame rates (`"sampleRate": "2997/50"`).
public struct Rational: Equatable, Hashable, Sendable, CustomStringConvertible {
    public var num: Int64
    public var den: Int64

    public init(_ num: Int64, _ den: Int64 = 1) {
        precondition(den != 0, "zero denominator")
        let g = Rational.gcd(abs(num), abs(den))
        let sign: Int64 = den < 0 ? -1 : 1
        self.num = sign * num / max(g, 1)
        self.den = sign * den / max(g, 1)
    }

    /// Parses `5`, `5.0`, or `"a/b"`.
    public init?(_ json: JSON?) {
        switch json {
        case .number(let n):
            if let i = n.int, n.isInteger { self.init(i) }
            else { self.init(approximating: n.double) }
        case .string(let s):
            let parts = s.split(separator: "/")
            guard parts.count == 2, let a = Int64(parts[0]), let b = Int64(parts[1]), b != 0 else {
                guard let d = Double(s) else { return nil }
                self.init(approximating: d)
                return
            }
            self.init(a, b)
        default:
            return nil
        }
    }

    public init(approximating d: Double) {
        if d == d.rounded() { self.init(Int64(d)) }
        else { self.init(Int64((d * 1_000_000).rounded()), 1_000_000) }
    }

    public var double: Double { Double(num) / Double(den) }
    public var description: String { den == 1 ? "\(num)" : "\(num)/\(den)" }

    /// Back to JSON in the form Camtasia uses: integer when whole, else string.
    public var json: JSON { den == 1 ? .number(JSONNumber(num)) : .string("\(num)/\(den)") }

    public static func * (a: Rational, b: Rational) -> Rational {
        Rational(a.num * b.num, a.den * b.den)
    }
    public static func / (a: Rational, b: Rational) -> Rational {
        Rational(a.num * b.den, a.den * b.num)
    }

    static func gcd(_ a: Int64, _ b: Int64) -> Int64 { b == 0 ? a : gcd(b, a % b) }
}

/// Converts timeline ticks to real time. Ticks are in units of the project's
/// top-level `editRate` (ticks per second): `705600000` in projects from
/// Camtasia 2020+, `30` (i.e. frames) in older ones. Never hard-code either.
public struct Timebase: Equatable, Hashable, Sendable {
    /// Ticks per second.
    public let editRate: Int64

    public init(editRate: Int64) { self.editRate = editRate }

    /// The modern Camtasia rate: divisible by 23.976/24/25/29.97/30/50/59.94/60
    /// fps and 44.1/48 kHz, so frame and sample boundaries land on whole ticks.
    public static let camtasia = Timebase(editRate: 705_600_000)

    public func seconds(_ ticks: Int64) -> Double { Double(ticks) / Double(editRate) }
    public func seconds(_ ticks: Rational) -> Double { ticks.double / Double(editRate) }
    public func ticks(seconds: Double) -> Int64 { Int64((seconds * Double(editRate)).rounded()) }

    /// Frame index at `fps`, floor-rounded.
    public func frame(_ ticks: Int64, fps: Rational) -> Int64 {
        (ticks * fps.num) / (editRate * fps.den)
    }

    public func ticks(frame: Int64, fps: Rational) -> Int64 {
        (frame * editRate * fps.den) / fps.num
    }

    /// `HH:MM:SS.mmm` for display and debugging.
    public func timecode(_ ticks: Int64) -> String {
        let ms = Int64((seconds(ticks) * 1000).rounded())
        let h = ms / 3_600_000, m = (ms / 60_000) % 60, s = (ms / 1000) % 60, f = ms % 1000
        return String(format: "%02lld:%02lld:%02lld.%03lld", h, m, s, f)
    }
}
