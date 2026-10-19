import Foundation
import TSCProjKit

/// Overflow-safe arithmetic on `Rational` tick values.
///
/// Nested clip speeds multiply denominators quickly (the vlog has
/// `766479/4918496` inside 10¹¹-tick timelines), so exact `Int64` maths can
/// overflow. On overflow the result is rounded to the nearest whole tick
/// (1/705600000 s), which is far below a frame and keeps evaluation total.
enum Q {
    static let zero = Rational(0)
    static let one = Rational(1)

    static func approx(_ d: Double) -> Rational {
        guard d.isFinite else { return zero }
        let clamped = Swift.max(Swift.min(d, Double(Int64.max / 2)), Double(Int64.min / 2))
        return Rational(Int64(clamped.rounded()))
    }

    static func double(_ a: Rational) -> Double { a.double }

    static func add(_ a: Rational, _ b: Rational) -> Rational {
        if a.den == b.den, case (let s, false) = a.num.addingReportingOverflow(b.num) {
            return Rational(s, a.den)
        }
        let g = gcd(a.den, b.den)
        let (l, o1) = (a.den / g).multipliedReportingOverflow(by: b.den)
        let (x, o2) = a.num.multipliedReportingOverflow(by: b.den / g)
        let (y, o3) = b.num.multipliedReportingOverflow(by: a.den / g)
        let (s, o4) = x.addingReportingOverflow(y)
        if o1 || o2 || o3 || o4 || l == 0 { return approx(a.double + b.double) }
        return Rational(s, l)
    }

    static func neg(_ a: Rational) -> Rational { Rational(-a.num, a.den) }
    static func sub(_ a: Rational, _ b: Rational) -> Rational { add(a, neg(b)) }

    static func mul(_ a: Rational, _ b: Rational) -> Rational {
        // Cross-reduce first to keep magnitudes small.
        let g1 = Swift.max(gcd(abs(a.num), b.den), 1), g2 = Swift.max(gcd(abs(b.num), a.den), 1)
        let (n, o1) = (a.num / g1).multipliedReportingOverflow(by: b.num / g2)
        let (d, o2) = (a.den / g2).multipliedReportingOverflow(by: b.den / g1)
        if o1 || o2 || d == 0 { return approx(a.double * b.double) }
        return Rational(n, d)
    }

    /// `a / b`; a zero divisor yields `a` unchanged (treat as speed 1).
    static func div(_ a: Rational, _ b: Rational) -> Rational {
        guard b.num != 0 else { return a }
        return mul(a, Rational(b.den, b.num))
    }

    static func lt(_ a: Rational, _ b: Rational) -> Bool {
        let (x, o1) = a.num.multipliedReportingOverflow(by: b.den)
        let (y, o2) = b.num.multipliedReportingOverflow(by: a.den)
        if o1 || o2 { return a.double < b.double }
        return x < y
    }
    static func le(_ a: Rational, _ b: Rational) -> Bool { !lt(b, a) }
    static func min(_ a: Rational, _ b: Rational) -> Rational { lt(b, a) ? b : a }
    static func max(_ a: Rational, _ b: Rational) -> Rational { lt(a, b) ? b : a }

    /// Nearest whole tick (half away from zero).
    static func round(_ a: Rational) -> Int64 {
        if a.den == 1 { return a.num }
        let q = a.num / a.den, r = a.num % a.den
        if abs(r) >= a.den - abs(r) { return q + (a.num < 0 ? -1 : 1) }
        return q
    }

    private static func gcd(_ a: Int64, _ b: Int64) -> Int64 {
        var a = abs(a), b = abs(b)
        while b != 0 { (a, b) = (b, a % b) }
        return a
    }
}
