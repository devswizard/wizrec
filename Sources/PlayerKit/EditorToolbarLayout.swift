/// The editor window's toolbar items (APP13-2): which exist, which show by default and in what
/// order. The app maps each to an `NSToolbarItem`; the toolbar saves the user's own arrangement.
public enum EditorToolbarLayout {
    /// One customizable item. Raw values are the `NSToolbarItem.Identifier`s (stored by
    /// AppKit when the user customizes the toolbar, so never rename them).
    public enum Item: String, CaseIterable, Sendable {
        case importMedia = "WizRec.toolbar.importMedia"
        case record = "WizRec.toolbar.record"
        case undo = "WizRec.toolbar.undo"
        case redo = "WizRec.toolbar.redo"
        case zoomOut = "WizRec.toolbar.zoomOut"
        case zoomToFit = "WizRec.toolbar.zoomToFit"
        case zoomIn = "WizRec.toolbar.zoomIn"
        case export = "WizRec.toolbar.export"
        /// Canvas crop mode on/off (APP15-1a).
        case cropMode = "WizRec.toolbar.cropMode"
    }

    /// A slot of the default arrangement: an item, or AppKit's flexible or fixed space.
    public enum Slot: Equatable, Sendable {
        case item(Item)
        case flexibleSpace
        case space
    }

    /// Toolbar identifier (also the key of the saved arrangement).
    public static let identifier = "WizRec.EditorToolbar"

    /// Import and Record on the leading side, Undo/Redo after them, the canvas tool (crop mode)
    /// in the middle, Export alone on the trailing edge (ui-workflow.md §3). Zoom items are
    /// available from Customize Toolbar.
    public static let defaultSlots: [Slot] = [
        .item(.importMedia), .item(.record), .space, .item(.undo), .item(.redo), .flexibleSpace, .item(.cropMode),
        .flexibleSpace, .item(.export),
    ]

    /// Every item the customization sheet offers (spaces are added by the app).
    public static let allowedItems: [Item] = Item.allCases
}
