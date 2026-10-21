import AppKit
import CoreMedia
import MediaEngine
import Observation
import PlayerKit
import SwiftUI
import TSCProjKit
import UniformTypeIdentifiers

/// Bin thumbnails, decoded on the document's thumbnail pool (never the playback pool).
@MainActor @Observable
final class ThumbnailStore {
    private(set) var images: [URL: NSImage] = [:]
    @ObservationIgnored private var requested: Set<URL> = []
    @ObservationIgnored private let pool: MediaPool

    init(pool: MediaPool) { self.pool = pool }

    /// Starts loading a thumbnail for `url` once; `images[url]` fills in when ready.
    func request(_ url: URL, maxPixelSize: Int = 240) {
        guard !requested.contains(url) else { return }
        requested.insert(url)
        let pool = pool
        Task { [weak self] in
            guard let image = await Self.load(url, pool: pool, maxPixelSize: maxPixelSize) else { return }
            self?.images[url] = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        }
    }

    /// Forgets failures so a relinked file is tried again.
    func reset(_ url: URL) { requested.remove(url); images[url] = nil }

    nonisolated private static func load(_ url: URL, pool: MediaPool, maxPixelSize: Int) async -> CGImage? {
        guard FileManager.default.fileExists(atPath: url.path),
              let source = try? await pool.source(for: url) else { return nil }
        let info = source.info
        guard info.kind != .shader, let video = info.streams.first(where: { $0.kind == .video }) else { return nil }
        let len = video.duration.isNumeric ? video.duration.seconds : 0
        let t = CMTime(seconds: min(1, len / 2), preferredTimescale: 600)
        return try? await source.thumbnail(stream: video.index, at: t, maxPixelSize: maxPixelSize)
    }
}

/// One source-bin entry as the bin shows it.
struct BinItem: Identifiable, Equatable {
    var id: Int64
    var name: String
    var url: URL
    var kind: String
    var detail: String
    var missing: Bool

    @MainActor
    static func items(_ model: EditorDocumentModel) -> [BinItem] {
        let missing = Set(model.missing.map(\.id))
        return model.project.sourceBin.map { s in
            let name = (s.src.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
            let tracks = s.tracks
            let video = tracks.first { $0.isVideo }
            let kind: String
            if s.src.lowercased().hasSuffix(".tscshadervid") { kind = "Shader" }
            else if tracks.contains(where: { $0.type == 1 }) { kind = "Image" }
            else if s.src.lowercased().hasSuffix(".trec") { kind = "Recording" }
            else if video != nil { kind = "Video" }
            else if tracks.contains(where: \.isAudio) { kind = "Audio" }
            else { kind = "Media" }
            var detail = ""
            if let v = video, let r = v.object["trackRect"]?.array?.items.compactMap(\.double), r.count == 4, kind != "Shader" {
                detail = "\(Int(r[2]))×\(Int(r[3]))"
            } else if kind == "Image", s.rect.count == 4 {
                detail = "\(Int(s.rect[2]))×\(Int(s.rect[3]))"
            }
            let secs = tracks.filter { $0.type != 1 && ($0.range.last ?? 0) < Int64.max / 2 }.map(\.durationSeconds).max() ?? 0
            if secs > 0 {
                let t = Int(secs.rounded())
                detail += (detail.isEmpty ? "" : " · ") + String(format: "%d:%02d", t / 60, t % 60)
            }
            return BinItem(id: s.id, name: name, url: model.url(of: s), kind: kind, detail: detail, missing: missing.contains(s.id))
        }
    }
}

/// The media bin: the project's sources with thumbnails. Drag an item onto the canvas or
/// timeline, double-click to add it at the playhead, drop files from Finder to import.
struct MediaBinView: View {
    let model: EditorDocumentModel
    let thumbnails: ThumbnailStore
    let actions: BinActions
    @State private var selection: Int64?
    @State private var dropTargeted = false
    /// Keyboard focus across the tiles (Tab / Shift-Tab; Space or Return adds at the playhead).
    @State private var focus: LibraryTileFocus = {
        let f = LibraryTileFocus()
        f.focusSearchField = nil
        return f
    }()

    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 160), spacing: 8)]

    var body: some View {
        let _ = model.revision
        let items = BinItem.items(model)
        VStack(spacing: 0) {
            HStack {
                Text("Media").font(.headline)
                Spacer()
                Button { actions.importMedia() } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless).help("Import Media… (⌘I)")
                    .accessibilityLabel("Import Media")
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            Divider()
            if items.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "square.and.arrow.down.on.square").font(.system(size: 28)).foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    Text("Your recordings and imported media appear here. Drag files here from Finder, or:")
                        .multilineTextAlignment(.center).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Import Media…") { actions.importMedia() }
                        .accessibilityIdentifier("bin.importMedia")
                        .help("Add video, audio or image files (⌘I)")
                }
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(items) { item in
                            BinTile(item: item, image: thumbnails.images[item.url], selected: selection == item.id)
                                .id("bin.\(item.id)")
                                .accessibilityHidden(true)
                                .overlay(LibraryTileAccessibility(
                                    title: item.name, note: item.missing ? String(localized: "Missing") : nil,
                                    hint: String(localized: "Press to add at the playhead"),
                                    identifier: "bin.\(item.id)", focus: focus) {
                                        actions.insert(item.id)
                                        return true
                                    })
                                .onAppear { if !item.missing { thumbnails.request(item.url) } }
                                .onTapGesture(count: 2) { actions.insert(item.id) }
                                .onTapGesture { selection = item.id }
                                .onDrag { Self.provider(for: item) }
                                .contextMenu {
                                    Button("Add to Timeline at Playhead") { actions.insert(item.id) }
                                    Button(item.missing ? "Locate Missing File…" : "Relink…") { actions.relink(item.id) }
                                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                                        .disabled(item.missing)
                                }
                        }
                    }
                    .padding(10)
                }
                .onAppear { connectFocus(proxy, items) }
                .onChange(of: items.map(\.id)) { _, ids in focus.order = ids.map { "bin.\($0)" } }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(dropTargeted ? Color.accentColor.opacity(0.12) : Color.clear)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            Self.loadURLs(providers) { actions.importFiles($0) }
            return true
        }
    }

    private func connectFocus(_ proxy: ScrollViewProxy, _ items: [BinItem]) {
        focus.order = items.map { "bin.\($0.id)" }
        focus.scrollTo = { id, backward in proxy.scrollTo(id, anchor: backward ? UnitPoint.top : UnitPoint.bottom) }
    }

    static func provider(for item: BinItem) -> NSItemProvider {
        let p = NSItemProvider()
        let id = Data(String(item.id).utf8)
        p.registerDataRepresentation(forTypeIdentifier: MediaDrop.sourceUTType.identifier, visibility: .ownProcess) { done in
            done(id, nil)
            return nil
        }
        return p
    }

    static func loadURLs(_ providers: [NSItemProvider], _ done: @escaping @MainActor ([URL]) -> Void) {
        Task { @MainActor in
            var urls: [URL] = []
            for p in providers {
                if let u = await withCheckedContinuation({ (c: CheckedContinuation<URL?, Never>) in
                    _ = p.loadObject(ofClass: NSURL.self) { obj, _ in c.resume(returning: obj as? URL) }
                }) { urls.append(u) }
            }
            if !urls.isEmpty { done(urls) }
        }
    }
}

/// Callbacks from the bin into the window controller.
struct BinActions {
    var importMedia: () -> Void
    var importFiles: ([URL]) -> Void
    var insert: (Int64) -> Void
    var relink: (Int64) -> Void
}

private struct BinTile: View {
    let item: BinItem
    let image: NSImage?
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.85))
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: icon).font(.system(size: 22)).foregroundStyle(.white.opacity(0.6))
                }
                if item.missing {
                    VStack {
                        Spacer()
                        Text("Missing").font(.caption2.bold()).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.orange, in: Capsule())
                            .padding(4)
                    }
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
            Text(item.name).font(.caption).lineLimit(1).truncationMode(.middle)
            Text(item.detail.isEmpty ? item.kind : "\(item.kind) · \(item.detail)")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .help(item.url.path)
    }

    private var icon: String {
        switch item.kind {
        case "Audio": "waveform"
        case "Image": "photo"
        case "Shader": "sparkles"
        case "Recording": "record.circle"
        default: "film"
        }
    }
}
