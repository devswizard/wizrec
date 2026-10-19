import Foundation

/// Lossless JSON tree.
///
/// `.tscproj` files must survive open → edit → save → reopen in Camtasia with
/// nothing dropped, so this model keeps what `JSONSerialization` / `Codable`
/// throw away: object key order, the exact text of every number, and every key
/// we don't understand. Containers are reference types so typed views
/// (`Clip`, `Track`, …) can edit the tree in place.
public indirect enum JSON {
    case object(JSONObject)
    case array(JSONArray)
    case string(String)
    case number(JSONNumber)
    case bool(Bool)
    case null

    public var object: JSONObject? { if case .object(let o) = self { o } else { nil } }
    public var array: JSONArray? { if case .array(let a) = self { a } else { nil } }
    public var string: String? { if case .string(let s) = self { s } else { nil } }
    public var number: JSONNumber? { if case .number(let n) = self { n } else { nil } }
    public var bool: Bool? { if case .bool(let b) = self { b } else { nil } }
    public var isNull: Bool { if case .null = self { true } else { false } }

    public var double: Double? { number?.double }
    public var int: Int64? { number?.int }

    /// Deep copy. Containers are shared by reference, so duplicating a clip
    /// must go through this.
    public func copy() -> JSON {
        switch self {
        case .object(let o): .object(o.copy())
        case .array(let a): .array(a.copy())
        default: self
        }
    }
}

/// A JSON number stored as its original lexeme so re-serialising never
/// changes precision (`0.714285714285714` stays exactly that).
public struct JSONNumber: Equatable, Hashable, Sendable, CustomStringConvertible {
    public let lexeme: String

    public init(lexeme: String) { self.lexeme = lexeme }

    public init(_ value: Int64) { lexeme = String(value) }
    public init(_ value: Int) { lexeme = String(value) }

    /// Camtasia writes doubles with 15 significant digits and always keeps a
    /// fractional part (`1920.0`, `-1.79769313486232e+308`).
    public init(_ value: Double) {
        guard value.isFinite else { lexeme = "0.0"; return }
        var s = String(format: "%.15g", value)
        if !s.contains(".") && !s.contains("e") && !s.contains("n") { s += ".0" }
        lexeme = s
    }

    public var isInteger: Bool { !lexeme.contains(where: { $0 == "." || $0 == "e" || $0 == "E" }) }
    public var double: Double { Double(lexeme) ?? 0 }
    public var int: Int64? { isInteger ? Int64(lexeme) : Double(lexeme).map { Int64($0) } }
    public var description: String { lexeme }
}

public final class JSONObject {
    public private(set) var keys: [String] = []
    private var storage: [String: JSON] = [:]

    public init() {}

    public init(_ pairs: [(String, JSON)]) {
        for (k, v) in pairs { self[k] = v }
    }

    public var count: Int { keys.count }
    public var entries: [(key: String, value: JSON)] { keys.map { ($0, storage[$0]!) } }

    /// Setting `nil` removes the key. Setting an existing key keeps its position.
    public subscript(key: String) -> JSON? {
        get { storage[key] }
        set {
            if let newValue {
                if storage.updateValue(newValue, forKey: key) == nil { keys.append(key) }
            } else if storage.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }

    public func copy() -> JSONObject {
        let o = JSONObject()
        for k in keys { o[k] = storage[k]!.copy() }
        return o
    }
}

public final class JSONArray {
    public var items: [JSON]

    public init(_ items: [JSON] = []) { self.items = items }

    public var count: Int { items.count }
    public subscript(i: Int) -> JSON {
        get { items[i] }
        set { items[i] = newValue }
    }

    public func copy() -> JSONArray { JSONArray(items.map { $0.copy() }) }
}

// MARK: - Structural equality (used by round-trip tests)

extension JSON: Equatable {
    public static func == (a: JSON, b: JSON) -> Bool {
        switch (a, b) {
        case (.null, .null): true
        case (.bool(let x), .bool(let y)): x == y
        case (.string(let x), .string(let y)): x == y
        case (.number(let x), .number(let y)): x == y
        case (.array(let x), .array(let y)): x.items == y.items
        case (.object(let x), .object(let y)):
            x.keys == y.keys && x.keys.allSatisfy { x[$0]! == y[$0]! }
        default: false
        }
    }
}

// MARK: - Parsing

public struct JSONParseError: Error, CustomStringConvertible {
    public let message: String
    public let offset: Int
    public var description: String { "JSON parse error at byte \(offset): \(message)" }
}

extension JSON {
    public static func parse(_ data: Data) throws -> JSON {
        var p = Parser(bytes: [UInt8](data))
        p.skipWhitespace()
        // Some writers emit a UTF-8 BOM.
        if p.bytes.starts(with: [0xEF, 0xBB, 0xBF]) { p.i = 3 }
        let v = try p.value()
        p.skipWhitespace()
        guard p.i == p.bytes.count else { throw p.error("trailing data") }
        return v
    }

    public static func parse(_ text: String) throws -> JSON { try parse(Data(text.utf8)) }
}

private struct Parser {
    let bytes: [UInt8]
    var i = 0

    func error(_ m: String) -> JSONParseError { JSONParseError(message: m, offset: i) }

    mutating func skipWhitespace() {
        while i < bytes.count, [0x20, 0x0A, 0x0D, 0x09].contains(bytes[i]) { i += 1 }
    }

    mutating func expect(_ s: String) throws {
        for b in s.utf8 {
            guard i < bytes.count, bytes[i] == b else { throw error("expected \(s)") }
            i += 1
        }
    }

    mutating func value() throws -> JSON {
        skipWhitespace()
        guard i < bytes.count else { throw error("unexpected end") }
        switch bytes[i] {
        case UInt8(ascii: "{"): return .object(try object())
        case UInt8(ascii: "["): return .array(try array())
        case UInt8(ascii: "\""): return .string(try string())
        case UInt8(ascii: "t"): try expect("true"); return .bool(true)
        case UInt8(ascii: "f"): try expect("false"); return .bool(false)
        case UInt8(ascii: "n"): try expect("null"); return .null
        default: return .number(try number())
        }
    }

    mutating func object() throws -> JSONObject {
        i += 1
        let o = JSONObject()
        skipWhitespace()
        if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return o }
        while true {
            skipWhitespace()
            guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw error("expected key") }
            let k = try string()
            skipWhitespace()
            try expect(":")
            o[k] = try value()
            skipWhitespace()
            guard i < bytes.count else { throw error("unterminated object") }
            if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
            if bytes[i] == UInt8(ascii: "}") { i += 1; return o }
            throw error("expected , or }")
        }
    }

    mutating func array() throws -> JSONArray {
        i += 1
        var items: [JSON] = []
        skipWhitespace()
        if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return JSONArray(items) }
        while true {
            items.append(try value())
            skipWhitespace()
            guard i < bytes.count else { throw error("unterminated array") }
            if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
            if bytes[i] == UInt8(ascii: "]") { i += 1; return JSONArray(items) }
            throw error("expected , or ]")
        }
    }

    mutating func number() throws -> JSONNumber {
        let start = i
        if i < bytes.count, bytes[i] == UInt8(ascii: "-") { i += 1 }
        while i < bytes.count {
            let b = bytes[i]
            let isNumChar = (b >= 0x30 && b <= 0x39) || b == UInt8(ascii: ".") || b == UInt8(ascii: "e")
                || b == UInt8(ascii: "E") || b == UInt8(ascii: "+") || b == UInt8(ascii: "-")
            guard isNumChar else { break }
            i += 1
        }
        let lexeme = String(decoding: bytes[start..<i], as: UTF8.self)
        guard !lexeme.isEmpty, lexeme != "-", Double(lexeme) != nil else {
            i = start
            throw error("invalid number")
        }
        return JSONNumber(lexeme: lexeme)
    }

    mutating func string() throws -> String {
        i += 1
        var out = [UInt8]()
        while true {
            guard i < bytes.count else { throw error("unterminated string") }
            let b = bytes[i]
            i += 1
            if b == UInt8(ascii: "\"") { break }
            guard b == UInt8(ascii: "\\") else { out.append(b); continue }
            guard i < bytes.count else { throw error("bad escape") }
            let e = bytes[i]
            i += 1
            switch e {
            case UInt8(ascii: "\""): out.append(0x22)
            case UInt8(ascii: "\\"): out.append(0x5C)
            case UInt8(ascii: "/"): out.append(0x2F)
            case UInt8(ascii: "b"): out.append(0x08)
            case UInt8(ascii: "f"): out.append(0x0C)
            case UInt8(ascii: "n"): out.append(0x0A)
            case UInt8(ascii: "r"): out.append(0x0D)
            case UInt8(ascii: "t"): out.append(0x09)
            case UInt8(ascii: "u"):
                var scalar = try hex4()
                if (0xD800...0xDBFF).contains(scalar), i + 1 < bytes.count,
                   bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u") {
                    i += 2
                    let low = try hex4()
                    scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                }
                out.append(contentsOf: Array(String(Unicode.Scalar(scalar) ?? "\u{FFFD}").utf8))
            default: throw error("bad escape \\\(Character(Unicode.Scalar(e)))")
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    mutating func hex4() throws -> UInt32 {
        guard i + 4 <= bytes.count, let v = UInt32(String(decoding: bytes[i..<i + 4], as: UTF8.self), radix: 16)
        else { throw error("bad \\u escape") }
        i += 4
        return v
    }
}

// MARK: - Serialising

extension JSON {
    /// Pretty-prints in the style Camtasia 2026 writes: two-space indent,
    /// `"key" : value`, scalar-only arrays inline, raw UTF-8.
    public func serialized() -> Data {
        var out = ""
        out.reserveCapacity(1 << 20)
        write(to: &out, indent: 0)
        out += "\n"
        return Data(out.utf8)
    }

    private func write(to out: inout String, indent: Int) {
        let pad = String(repeating: "  ", count: indent)
        let inner = String(repeating: "  ", count: indent + 1)
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n): out += n.lexeme
        case .string(let s): JSON.writeString(s, to: &out)
        case .object(let o):
            out += "{\n"
            for (idx, (k, v)) in o.entries.enumerated() {
                out += inner
                JSON.writeString(k, to: &out)
                out += " : "
                v.write(to: &out, indent: indent + 1)
                out += idx == o.count - 1 ? "\n" : ",\n"
            }
            out += pad + "}"
        case .array(let a):
            let scalarOnly = a.items.allSatisfy { $0.object == nil && $0.array == nil }
            if scalarOnly && !a.items.isEmpty {
                out += "["
                for (idx, v) in a.items.enumerated() {
                    if idx > 0 { out += ", " }
                    v.write(to: &out, indent: indent + 1)
                }
                out += "]"
                return
            }
            out += "[\n"
            for (idx, v) in a.items.enumerated() {
                out += inner
                v.write(to: &out, indent: indent + 1)
                out += idx == a.count - 1 ? "\n" : ",\n"
            }
            out += pad + "]"
        }
    }

    private static func writeString(_ s: String, to out: inout String) {
        out += "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if u.value < 0x20 {
                    out += String(format: "\\u%04x", u.value)
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        out += "\""
    }
}
