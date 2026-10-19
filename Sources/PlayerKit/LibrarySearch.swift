import Foundation

/// Search used by the library panel and media bin: every whitespace-separated word of the
/// query must appear (case- and diacritic-insensitive) in at least one of the fields.
public enum LibrarySearch {
    /// True when `query` is blank or every query word matches one of `fields`.
    public static func matches(_ query: String, fields: [String]) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        return words.allSatisfy { w in
            fields.contains { $0.range(of: w, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    /// Splits a camel-case identifier into words (`DropShadow` → `Drop Shadow`), so a
    /// search for "shadow" finds an effect by its project name too.
    public static func words(ofIdentifier name: String) -> String {
        var out = ""
        var prev: Character?
        for c in name {
            if let p = prev, c.isUppercase, p.isLowercase || p.isNumber { out.append(" ") }
            out.append(c)
            prev = c
        }
        return out
    }
}
