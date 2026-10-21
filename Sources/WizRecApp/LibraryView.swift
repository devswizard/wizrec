import PlayerKit
import SwiftUI
import TimelineEngine
import TimelineUI
import WizRecAssets

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
        case media, backgrounds, annotations, effects, audio, transitions
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .media: "Media"
            case .backgrounds: "Backgrounds"
            case .annotations: "Annotations"
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
            case .backgrounds:
                LibraryList(items: Self.backgroundItems(), kind: .background, apply: library.apply,
                            hint: "Double-click to add at the playhead for 60 seconds. Camtasia won't show WizRec backgrounds.")
            case .effects:
                LibraryList(items: Self.effectItems(), kind: .effect, apply: library.apply,
                            hint: "Drag an effect onto a clip, or double-click to add it to the selected clips.")
            case .annotations:
                LibraryList(items: Self.calloutItems(), kind: .callout, apply: library.apply,
                            hint: "Double-click to add at the playhead, above the clips there, for 5 seconds.")
            case .audio:
                LibraryList(items: Self.audioItems(), kind: .audio, apply: library.apply,
                            hint: "Double-click to add to the selected clips' audio. Captions adds empty captions to type into.")
            case .transitions:
                LibraryList(items: Self.transitionItems(), kind: .transition, apply: library.apply,
                            hint: "Drag a transition onto the cut between two clips or a clip's start or end, or double-click to add it at the playhead cut or to the selected clips.")
            }
        }
    }

    /// The tab's title as the picker shows it (plain string, for logs and UI checks).
    static func label(of tab: Tab) -> String {
        switch tab {
        case .media: String(localized: "Media")
        case .backgrounds: String(localized: "Backgrounds")
        case .annotations: String(localized: "Annotations")
        case .effects: String(localized: "Effects")
        case .audio: String(localized: "Audio")
        case .transitions: String(localized: "Transitions")
        }
    }

    /// Every library tile by tab (Media excluded: its items are the project's sources), with the
    /// accessibility identifier its tile carries (`library.<name>`).
    static func libraryManifest() -> [(tab: String, identifier: String)] {
        let lists: [(Tab, [LibraryItem])] = [(.backgrounds, backgroundItems()), (.annotations, calloutItems()),
                                             (.effects, effectItems()), (.audio, audioItems()),
                                             (.transitions, transitionItems())]
        var out: [(tab: String, identifier: String)] = []
        for (tab, items) in lists {
            let name = label(of: tab)
            for item in items { out.append((tab: name, identifier: "library.\(item.name)")) }
        }
        return out
    }

    static func effectItems() -> [LibraryItem] {
        TimelineLibrary.effects.map {
            LibraryItem(name: $0.name, title: $0.displayName, symbol: symbol(effect: $0.name),
                        note: $0.isRendered ? nil : String(localized: "not previewed"))
        }
    }

    /// WizRec's own animated backgrounds (`AssetCatalog.backgrounds`), grouped by category.
    static func backgroundItems() -> [LibraryItem] {
        AssetCatalog.backgrounds.map {
            LibraryItem(name: $0.id, title: $0.displayName, symbol: symbol(background: $0.category),
                        section: backgroundSection($0.category))
        }
    }

    static func backgroundSection(_ c: BackgroundAsset.Category) -> String {
        switch c {
        case .gradients: String(localized: "Gradients")
        case .patterns: String(localized: "Patterns")
        case .abstract: String(localized: "Abstract")
        }
    }

    static func symbol(background: BackgroundAsset.Category) -> String {
        switch background {
        case .gradients: "paintpalette"
        case .patterns: "square.grid.3x3"
        case .abstract: "sparkles"
        }
    }

    /// WizRec's own callout presets (`AssetCatalog.callouts`), grouped by library tab.
    static func calloutItems() -> [LibraryItem] {
        AssetCatalog.callouts.map {
            LibraryItem(name: $0.id, title: $0.displayName, symbol: symbol(calloutGroup: $0.group),
                        section: calloutSection($0.group))
        }
    }

    static func calloutSection(_ g: CalloutPreset.Group) -> String {
        switch g {
        case .shapes: String(localized: "Shapes")
        case .bubbles: String(localized: "Bubbles")
        case .arrows: String(localized: "Arrows & Lines")
        case .text: String(localized: "Text")
        case .regions: String(localized: "Blur & Highlight")
        }
    }

    static func symbol(calloutGroup: CalloutPreset.Group) -> String {
        switch calloutGroup {
        case .shapes: "square.on.circle"
        case .bubbles: "bubble.left"
        case .arrows: "arrow.up.right"
        case .text: "textformat"
        case .regions: "eye.slash"
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
    enum Kind { case effect, transition, audio, callout, background }
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
    @State private var focus = LibraryTileFocus()
    @FocusState private var searchFocused: Bool
    private let columns = [GridItem(.adaptive(minimum: 96, maximum: 140), spacing: 8)]

    /// Drag pasteboard type; nil for audio items (double-click only: the timeline takes no audio drops).
    private var type: String? {
        switch kind {
        case .effect: TimelineUI.TimelineView.effectType.rawValue
        case .transition: TimelineUI.TimelineView.transitionType.rawValue
        case .audio, .callout, .background: nil
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

    /// Tile identifiers in reading order (sections top to bottom, each grid row-major).
    private var focusOrder: [String] {
        sections.flatMap { group in group.items.map { (item: LibraryItem) -> String in "library.\(item.name)" } }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .accessibilityIdentifier("librarySearch")
                .onKeyPress(.tab, phases: .down) { press in
                    // Tab from the search field enters the grid at its first tile.
                    guard press.modifiers.isEmpty else { return .ignored }
                    return focus.enterFromSearchField(backward: false) ? .handled : .ignored
                }
                .padding(.horizontal, 10).padding(.top, 8)
            ScrollViewReader { proxy in
                grid
                    .onAppear { connectFocus(proxy) }
                    .onChange(of: focusOrder) { _, order in focus.order = order }
            }
        }
    }

    private func connectFocus(_ proxy: ScrollViewProxy) {
        focus.order = focusOrder
        focus.scrollTo = { id, backward in
            proxy.scrollTo(id, anchor: backward ? UnitPoint.top : UnitPoint.bottom)
        }
        let field = $searchFocused
        focus.focusSearchField = { field.wrappedValue = true }
    }

    private var grid: some View {
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
                        ForEach(group.items) { tile($0).id("library.\($0.name)") }
                    }
                }
            }
            .padding(10)
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
        // SwiftUI's own accessibility label on a LazyVGrid cell never reaches AXTitle /
        // AXDescription; an AppKit element in front of the tile carries them (mouse passes through).
        .accessibilityHidden(true)
        .overlay(LibraryTileAccessibility(title: item.title, note: item.note, hint: Self.hint(for: kind),
                                          identifier: "library.\(item.name)", focus: focus) { apply(kind, item.name) })
    }

    static func hint(for kind: LibraryItem.Kind) -> String {
        switch kind {
        case .transition: String(localized: "Double-click to add at the cut under the playhead or to the selected clips")
        case .callout, .background: String(localized: "Double-click to add at the playhead")
        case .effect, .audio: String(localized: "Double-click to add to the selected clips")
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

/// The accessibility element of one library tile: an AppKit button element with the tile's
/// title as AXTitle and AXDescription, its note as AXValue, a press action that applies the
/// item, and the `library.<name>` identifier. It is transparent to the mouse (`hitTest` nil),
/// so clicks, double-clicks and drags still reach the SwiftUI tile below.
struct LibraryTileAccessibility: NSViewRepresentable {
    var title: String
    var note: String?
    var hint: String
    var identifier: String
    var focus: LibraryTileFocus
    var press: () -> Bool

    final class Element: NSView {
        var press: () -> Bool = { false }
        var title = ""
        /// The tile this element shows (`library.<name>`) and the grid's focus order.
        var tileID = ""
        weak var focus: LibraryTileFocus?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        // NSView drops a stored AXTitle for button roles; answer it directly.
        override func accessibilityTitle() -> String? { title }
        override func accessibilityLabel() -> String? { title }
        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .button }
        override func accessibilityPerformPress() -> Bool {
            if !press() { NSSound.beep() }
            return true
        }

        // Keyboard: Tab / Shift-Tab reach every tile (key view loop), Space / Return press it,
        // and the focus ring shows which tile has focus. Assistive apps can move focus here.
        override var acceptsFirstResponder: Bool { true }
        override var canBecomeKeyView: Bool { true }
        override func becomeFirstResponder() -> Bool {
            noteFocusRingMaskChanged()
            return true
        }
        override func resignFirstResponder() -> Bool {
            noteFocusRingMaskChanged()
            return true
        }
        override var focusRingMaskBounds: NSRect { bounds }
        override func drawFocusRingMask() {
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        override func keyDown(with event: NSEvent) {
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if mods.isEmpty, [49, 36, 76].contains(event.keyCode) {   // Space, Return, keypad Enter
                _ = accessibilityPerformPress()
            } else if event.keyCode == 48, mods.subtracting(.shift).isEmpty, let focus {
                focus.move(from: self, id: tileID, backward: mods.contains(.shift))   // Tab / Shift-Tab
            } else {
                super.keyDown(with: event)
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // A tile scrolled into view for a pending Tab takes focus once it is on the window.
            if window != nil, !tileID.isEmpty { focus?.register(self, id: tileID) }
        }
        override func isAccessibilityFocused() -> Bool { window?.firstResponder === self }
        override func setAccessibilityFocused(_ focused: Bool) {
            if focused { window?.makeFirstResponder(self) }
        }
    }

    func makeNSView(context: Context) -> Element { Element() }

    func updateNSView(_ v: Element, context: Context) {
        v.press = press
        v.title = title
        v.setAccessibilityValue(note ?? "")
        v.setAccessibilityHelp(hint)
        v.setAccessibilityIdentifier(identifier)
        v.tileID = identifier
        v.focus = focus
        focus.register(v, id: identifier)
    }
}
