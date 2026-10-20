import PlayerKit
import SwiftUI
import TimelineEngine
import TimelineUI

/// What the library panel can ask the editor to do.
struct LibraryActions {
    /// Double-click: apply the item to the timeline selection (effect → selected clips,
    /// transition → selected clip edges). Returns false when nothing could take it.
    var apply: (LibraryItem.Kind, String) -> Bool = { _, _ in false }
}

/// Left pane: the media bin plus the effects and transitions library (drag items onto
/// the timeline; TimelineUI applies the preset defaults on drop).
struct SidebarView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case media, effects, audio, transitions
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .media: "Media"
            case .effects: "Effects"
            case .audio: "Audio"
            case .transitions: "Transitions"
            }
        }
    }

    let model: EditorDocumentModel
    let thumbnails: ThumbnailStore
    let actions: BinActions
    var library = LibraryActions()
    @AppStorage("WizRec.SidebarTab") private var tab: Tab = .media

    var body: some View {
        VStack(spacing: 0) {
            Picker("Sidebar", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 8).padding(.top, 8)
            switch tab {
            case .media: MediaBinView(model: model, thumbnails: thumbnails, actions: actions)
            case .effects:
                LibraryList(items: Self.effectItems(), kind: .effect, apply: library.apply,
                            hint: "Drag an effect onto a clip, or double-click to add it to the selected clips.")
            case .audio:
                LibraryList(items: Self.audioItems(), kind: .audio, apply: library.apply,
                            hint: "Double-click to add to the selected clips' audio. Captions adds empty captions to type into.")
            case .transitions:
                LibraryList(items: Self.transitionItems(), kind: .transition, apply: library.apply,
                            hint: "Drag a transition onto the cut between two clips or a clip's start or end, or double-click to add it at the playhead cut or to the selected clips.")
            }
        }
    }

    static func effectItems() -> [LibraryItem] {
        TimelineLibrary.effects.map {
            LibraryItem(name: $0.name, title: $0.displayName, symbol: symbol(effect: $0.name),
                        note: $0.isRendered ? nil : String(localized: "not previewed"))
        }
    }

    /// The Audio Effects panel items, in Camtasia's panel order (`AudioPanelItem`).
    static func audioItems() -> [LibraryItem] {
        AudioPanelItem.allCases.map { LibraryItem(name: $0.rawValue, title: $0.displayName, symbol: symbol(audio: $0)) }
    }

    static func symbol(audio: AudioPanelItem) -> String {
        switch audio {
        case .aiNoiseRemoval: "waveform.badge.minus"
        case .audioCompression: "arrow.down.right.and.arrow.up.left"
        case .captions: "captions.bubble"
        case .clipSpeed: "speedometer"
        case .emphasize: "speaker.wave.3"
        case .fadeIn: "speaker.wave.1"
        case .fadeOut: "speaker.slash"
        case .pitch: "tuningfork"
        }
    }

    static func transitionItems() -> [LibraryItem] {
        TimelineLibrary.transitions.map {
            LibraryItem(name: $0.name, title: $0.displayName, symbol: symbol(transitionCategory: $0.category),
                        note: $0.isRendered ? nil : String(localized: "not previewed"),
                        section: sectionTitle($0.category))
        }
    }

    static func sectionTitle(_ category: String) -> String {
        switch category {
        case "fades": String(localized: "Fades")
        case "wipes": String(localized: "Wipes")
        case "slides": String(localized: "Slides")
        case "shapes": String(localized: "Shapes")
        case "3d": String(localized: "3D")
        default: category.capitalized
        }
    }

    static func symbol(transitionCategory: String) -> String {
        switch transitionCategory {
        case "fades": "circle.lefthalf.filled"
        case "wipes": "rectangle.righthalf.inset.filled"
        case "slides": "arrow.right.square"
        case "shapes": "circle.dashed"
        case "3d": "cube"
        default: "square.split.2x1"
        }
    }

    static func symbol(effect: String) -> String {
        switch effect {
        case "RoundCorners": "rectangle.roundedtop"
        case "DropShadow": "shadow"
        case "Mask": "theatermasks"
        case "ColorAdjustment": "slider.horizontal.3"
        default: "wand.and.stars"
        }
    }
}

/// One library tile: `name` is what the project stores, `title` what the user sees.
struct LibraryItem: Identifiable, Equatable {
    enum Kind { case effect, transition, audio }
    var name: String
    var title: String
    var symbol: String
    var note: String?
    /// Heading the tile is grouped under (nil = no heading).
    var section: String?
    var id: String { name }
}

/// A searchable grid of draggable library tiles. The drag carries the kind's pasteboard
/// type with the item's `name`; double-click applies it to the selection.
struct LibraryList: View {
    let items: [LibraryItem]
    let kind: LibraryItem.Kind
    let apply: (LibraryItem.Kind, String) -> Bool
    let hint: LocalizedStringKey
    @State private var query = ""
    private let columns = [GridItem(.adaptive(minimum: 96, maximum: 140), spacing: 8)]

    /// Drag pasteboard type; nil for audio items (double-click only: the timeline takes no audio drops).
    private var type: String? {
        switch kind {
        case .effect: TimelineUI.TimelineView.effectType.rawValue
        case .transition: TimelineUI.TimelineView.transitionType.rawValue
        case .audio: nil
        }
    }

    private var shown: [LibraryItem] {
        items.filter {
            LibrarySearch.matches(query, fields: [$0.title, LibrarySearch.words(ofIdentifier: $0.name), $0.section ?? ""])
        }
    }

    /// `shown` grouped by section, in first-appearance order.
    private var sections: [(title: String, items: [LibraryItem])] {
        var out: [(title: String, items: [LibraryItem])] = []
        for item in shown {
            let t = item.section ?? ""
            if let i = out.firstIndex(where: { $0.title == t }) { out[i].items.append(item) } else { out.append((t, [item])) }
        }
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 10).padding(.top, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if shown.isEmpty {
                        Text("No matches").font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.top, 20)
                    }
                    ForEach(sections, id: \.title) { group in
                        if let t = group.title.isEmpty ? nil : group.title {
                            Text(t).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                                .padding(.top, 4)
                                .accessibilityAddTraits(.isHeader)
                        }
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(group.items) { tile($0) }
                        }
                    }
                }
                .padding(10)
            }
        }
    }

    private func tile(_ item: LibraryItem) -> some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.12))
                Image(systemName: item.symbol).font(.system(size: 22)).foregroundStyle(Color.accentColor)
            }
            .aspectRatio(16 / 10, contentMode: .fit)
            Text(item.title).font(.caption).lineLimit(1)
            if let n = item.note { Text(n).font(.caption2).foregroundStyle(.orange) }
        }
        .contentShape(Rectangle())
        .help(item.note.map { "\(item.title) — \($0): kept in the project, not drawn yet" } ?? item.title)
        .onTapGesture(count: 2) { if !apply(kind, item.name) { NSSound.beep() } }
        .onDrag { type.map { Self.provider(type: $0, name: item.name) } ?? NSItemProvider() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.title)
        .accessibilityValue(item.note ?? "")
        .accessibilityHint(kind == .transition ? "Double-click to add at the cut under the playhead or to the selected clips"
                           : "Double-click to add to the selected clips")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { _ = apply(kind, item.name) }
        .accessibilityIdentifier("library.\(item.name)")
    }

    static func provider(type: String, name: String) -> NSItemProvider {
        let p = NSItemProvider()
        let data = Data(name.utf8)
        p.registerDataRepresentation(forTypeIdentifier: type, visibility: .ownProcess) { done in
            done(data, nil)
            return nil
        }
        return p
    }
}
