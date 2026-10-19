import Foundation

/// Titles for File ▸ Open Recent: the file name, plus the parent folder when two recent
/// projects share a name (e.g. `demo.cmproj — Desktop`).
public enum RecentDocuments {
    /// One menu row.
    public struct Entry: Equatable, Sendable {
        public var url: URL
        public var title: String
    }

    /// Entries in the given (most recent first) order, duplicates removed.
    public static func entries(_ urls: [URL]) -> [Entry] {
        var seen = Set<String>()
        let unique = urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
        var counts: [String: Int] = [:]
        for u in unique { counts[u.lastPathComponent, default: 0] += 1 }
        return unique.map { u in
            let name = u.lastPathComponent
            let parent = u.deletingLastPathComponent().lastPathComponent
            return Entry(url: u, title: (counts[name] ?? 0) > 1 && !parent.isEmpty ? "\(name) — \(parent)" : name)
        }
    }
}
