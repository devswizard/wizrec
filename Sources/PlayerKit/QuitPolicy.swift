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

/// A document the quit policy inspects and, in `--quit-after` runs, marks clean (the app's
/// `ProjectDocument`; tests use stand-ins).
@MainActor
public protocol QuitReviewedDocument: AnyObject {
    /// Name shown in the discard notice (the window title).
    var quitDisplayName: String { get }
    /// Whether the document has unsaved edits.
    var hasUnsavedEdits: Bool { get }
    /// Drops the edits for this quit: the document must report no unsaved edits afterwards,
    /// so neither NSDocument's review nor the close asks or saves.
    func discardEditsForQuit()
}

extension UnsavedEditsOnQuit {
    /// Applies the policy to every open document before a quit (the timed quit and the
    /// unsaved-documents review of ⌘Q). `.ask` changes nothing. `.discard` marks every edited
    /// document clean, in order, and returns the one notice line to log (nil when none was
    /// edited, e.g. on the second call of the same quit).
    @MainActor
    public func prepareQuit(_ documents: [any QuitReviewedDocument]) -> String? {
        guard self == .discard else { return nil }
        let edited = documents.filter(\.hasUnsavedEdits)
        let line = Self.discardNotice(documents: edited.map(\.quitDisplayName))
        for doc in edited { doc.discardEditsForQuit() }
        return line
    }
}
