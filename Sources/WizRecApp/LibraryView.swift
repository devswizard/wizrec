import PlayerKit
import RenderEngine
import SwiftUI
import TimelineUI

/// Left pane: the media bin plus the effects and transitions library (drag items onto
/// the timeline; TimelineUI applies the preset defaults on drop).
struct SidebarView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case media = "Media", effects = "Effects", transitions = "Transitions"
        var id: String { rawValue }
    }

    let model: EditorDocumentModel
    let thumbnails: ThumbnailStore
    let actions: BinActions
    @AppStorage("WizRec.SidebarTab") private var tab: Tab = .media

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 8).padding(.top, 8)
            switch tab {
            case .media: MediaBinView(model: model, thumbnails: thumbnails, actions: actions)
            case .effects: LibraryList(items: TimelineLibrary.effects.map {
                LibraryItem(name: $0.name, title: $0.displayName, symbol: Self.symbol(effect: $0.name),
                            note: Compositor.renderedEffects.contains($0.name) ? nil : "not previewed")
            }, type: TimelineUI.TimelineView.effectType.rawValue, hint: "Drag an effect onto a clip.")
            case .transitions: LibraryList(items: TimelineLibrary.transitions.map {
                LibraryItem(name: $0.name, title: $0.displayName, symbol: "square.split.2x1", note: nil)
            }, type: TimelineUI.TimelineView.transitionType.rawValue,
               hint: "Drag a transition onto the cut between two clips, or onto a clip's start or end.")
            }
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

struct LibraryItem: Identifiable, Equatable {
    var name: String
    var title: String
    var symbol: String
    var note: String?
    var id: String { name }
}

/// A grid of draggable library tiles. The drag carries `type` with the item's `name`.
struct LibraryList: View {
    let items: [LibraryItem]
    let type: String
    let hint: String
    private let columns = [GridItem(.adaptive(minimum: 96, maximum: 140), spacing: 8)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(items) { item in
                        VStack(spacing: 6) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.12))
                                Image(systemName: item.symbol).font(.system(size: 22)).foregroundStyle(Color.accentColor)
                            }
                            .aspectRatio(16 / 10, contentMode: .fit)
                            Text(item.title).font(.caption).lineLimit(1)
                            if let n = item.note { Text(n).font(.caption2).foregroundStyle(.orange) }
                        }
                        .help(item.note.map { "\(item.title) — \($0): kept in the project, not drawn yet" } ?? item.title)
                        .onDrag { Self.provider(type: type, name: item.name) }
                    }
                }
            }
            .padding(10)
        }
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
