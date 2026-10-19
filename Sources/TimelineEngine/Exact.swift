import Foundation
import TSCProjKit

/// Overflow-checked exact arithmetic on `Rational` tick values.
///
/// TSCProjKit's `Rational` operators trap on `Int64` overflow. Edit commands
/// must never crash on untrusted project data, so they use these helpers,
/// which cancel common factors first and throw `EditError.invalid` when a
/// result still does not fit.
enum Exact {
    static func gcd(_ a: Int64, _ b: Int64) -> Int64 {
        var (x, y) = (a.magnitude, b.magnitude)
        while y != 0 { (x, y) = (y, x % y) }
        return Int64(clamping: x)
    }

    private static func checked(_ r: (partialValue: Int64, overflow: Bool)) throws -> Int64 {
        if r.overflow { throw EditError.invalid("time arithmetic overflow") }
        return r.partialValue
    }

    static func add(_ a: Rational, _ b: Rational) throws -> Rational {
        let g = max(gcd(a.den, b.den), 1)
        let den = try checked((a.den / g).multipliedReportingOverflow(by: b.den))
        let x = try checked(a.num.multipliedReportingOverflow(by: b.den / g))
        let y = try checked(b.num.multipliedReportingOverflow(by: a.den / g))
        return Rational(try checked(x.addingReportingOverflow(y)), den)
    }

    static func sub(_ a: Rational, _ b: Rational) throws -> Rational {
        try add(a, Rational(-b.num, b.den))
    }

    static func mul(_ a: Rational, _ b: Rational) throws -> Rational {
        let g1 = max(gcd(a.num, b.den), 1), g2 = max(gcd(b.num, a.den), 1)
        let num = try checked((a.num / g1).multipliedReportingOverflow(by: b.num / g2))
        let den = try checked((a.den / g2).multipliedReportingOverflow(by: b.den / g1))
        return Rational(num, den)
    }

    static func div(_ a: Rational, _ b: Rational) throws -> Rational {
        guard b.num != 0 else { throw EditError.invalid("division by zero") }
        return try mul(a, Rational(b.den, b.num))
    }

    /// Exact three-way comparison (128-bit cross products, never overflows).
    static func compare(_ a: Rational, _ b: Rational) -> Int {
        let l = a.num.multipliedFullWidth(by: b.den), r = b.num.multipliedFullWidth(by: a.den)
        if l.high != r.high { return l.high < r.high ? -1 : 1 }
        if l.low != r.low { return l.low < r.low ? -1 : 1 }
        return 0
    }

    static func less(_ a: Rational, _ b: Rational) -> Bool { compare(a, b) < 0 }

    /// Largest integer ≤ `a`.
    static func floor(_ a: Rational) -> Int64 {
        let q = a.num / a.den
        return (a.num % a.den != 0 && a.num < 0) ? q - 1 : q
    }
}

// MARK: - Writing times in the original number style

/// Writes tick values back to the JSON tree in the representation the key
/// already uses, and leaves the key untouched when the value is unchanged so
/// the original lexeme survives.
///
/// - Integer lexeme (`120`): stays an integer while whole; a fractional result
///   becomes Camtasia's exact rational string (`"11425/76"`).
/// - Double lexeme (`0.0`, `18110400000.0`): stays a double (`30.0`).
/// - Rational string (`"304/457"`) or missing key: rational string, or an
///   integer when whole (Camtasia's normal form, e.g. `scalar: 1`) [inf].
enum TimeWriter {
    static func set(_ value: Rational, _ key: String, in o: JSONObject) {
        let old = o[key]
        if let old, let r = Rational(old), r == value { return }
        if case .number(let n)? = old, !n.isInteger {
            o[key] = .number(JSONNumber(value.double))
        } else {
            o[key] = value.json
        }
    }

    static func set(_ value: Int64, _ key: String, in o: JSONObject) {
        set(Rational(value), key, in: o)
    }

    static func rational(_ key: String, in o: JSONObject) -> Rational? { Rational(o[key]) }
    static func int(_ key: String, in o: JSONObject) -> Int64? { o[key]?.int }
}
