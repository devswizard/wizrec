import Foundation

/// What quitting the app does with documents that have unsaved edits.
public enum UnsavedEditsOnQuit: Equatable, Sendable {
    /// Ask before quitting (save / don't save / cancel): interactive use.
    case ask
    /// Quit (or close) without asking and drop the edits, after logging one line (`discardNotice`).
    /// Timed runs (`--quit-after`) must never wait for the user.
    case discard

    /// The line logged when a quit discards edits in `documents` (display names), or nil when
    /// nothing is edited.
    public static func discardNotice(documents: [String]) -> String? {
        guard !documents.isEmpty else { return nil }
        let names = documents.joined(separator: ", ")
        return "WizRec: --quit-after: quitting without saving; discarded unsaved edits in \(names)"
    }
}

extension LaunchOptions {
    /// `--quit-after` runs discard unsaved edits on every quit or window close (timed, ⌘Q, ⌘W);
    /// all other runs ask, scripted steps without `--quit-after` included.
    public var unsavedEditsOnQuit: UnsavedEditsOnQuit { quitAfter == nil ? .ask : .discard }
}
