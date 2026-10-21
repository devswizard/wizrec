import AppKit
import PlayerKit
import UniformTypeIdentifiers

/// Maps project files to `ProjectDocument` by extension, so opening works even
/// when another app's type declaration for `.cmproj` wins in Launch Services,
/// and when the binary runs outside the app bundle (no Info.plist types).
final class WizRecDocumentController: NSDocumentController {
    override func typeForContents(of url: URL) throws -> String {
        switch url.pathExtension.lowercased() {
        case "cmproj": return ProjectDocument.cmprojType
        case "tscproj": return ProjectDocument.tscprojType
        default:
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnsupportedSchemeError, userInfo: [
                NSLocalizedDescriptionKey: "WizRec opens .cmproj and .tscproj projects.",
                NSURLErrorKey: url,
            ])
        }
    }

    override func documentClass(forType typeName: String) -> AnyClass? { ProjectDocument.self }
    override var documentClassNames: [String] { [NSStringFromClass(ProjectDocument.self)] }
    override var defaultType: String? { ProjectDocument.cmprojType }

    /// File ▸ New Project: an untitled package in a temporary folder (see `ProjectDocument.makeUntitled`).
    override func makeUntitledDocument(ofType typeName: String) throws -> NSDocument {
        let doc = ProjectDocument()
        try MainActor.assumeIsolated { try doc.makeUntitled() }
        return doc
    }

    /// Quit's unsaved-changes review: `--quit-after` runs drop the edits first, so nothing asks.
    override func reviewUnsavedDocuments(withAlertTitle title: String?, cancellable: Bool, delegate: Any?,
                                         didReviewAllSelector: Selector?, contextInfo: UnsafeMutableRawPointer?) {
        MainActor.assumeIsolated { ProjectDocument.discardUnsavedEditsBeforeQuit(options: AppEnvironment.options) }
        super.reviewUnsavedDocuments(withAlertTitle: title, cancellable: cancellable, delegate: delegate,
                                     didReviewAllSelector: didReviewAllSelector, contextInfo: contextInfo)
    }

    /// Enables files by extension (`OpenableFile`): with Camtasia installed, `.cmproj` files carry
    /// Camtasia's own type, so a content-type filter would grey them out.
    private let openFilter = OpenPanelFilter()

    override func beginOpenPanel(_ openPanel: NSOpenPanel, forTypes inTypes: [String]?,
                                 completionHandler: @escaping (Int) -> Void) {
        openPanel.allowedContentTypes = []
        openPanel.delegate = openFilter
        openPanel.treatsFilePackagesAsDirectories = false
        openPanel.allowsMultipleSelection = true
        openPanel.message = String(localized: "Choose a project, or a video, audio or image file to start a new project with.")
        openPanel.begin { completionHandler($0.rawValue) }
    }

    /// A media file opens as a new untitled project with the file on the timeline at 0;
    /// projects open as usual.
    override func openDocument(withContentsOf url: URL, display displayDocument: Bool,
                               completionHandler: @escaping (NSDocument?, Bool, (any Error)?) -> Void) {
        guard OpenableFile(url) == .media else {
            super.openDocument(withContentsOf: url, display: displayDocument, completionHandler: completionHandler)
            return
        }
        do {
            let editor = try MainActor.assumeIsolated { try newProjectEditor() }
            MainActor.assumeIsolated { editor?.importFiles([url], place: true, at: 0) }
            completionHandler(editor?.document as? NSDocument, false, nil)
        } catch {
            completionHandler(nil, false, error)
        }
    }

    /// A new untitled project, displayed; its editor (nil only if the window did not load).
    @MainActor
    func newProjectEditor() throws -> EditorWindowController? {
        let doc = try openUntitledDocumentAndDisplay(true)
        if doc.windowControllers.isEmpty { doc.makeWindowControllers() }
        return doc.windowControllers.lazy.compactMap { $0 as? EditorWindowController }.first
    }

    /// Opens dropped or chosen files (start screen): each project in its window; all media files
    /// together in one new project, placed one after another from 0. Other files are reported.
    @MainActor
    func openFiles(_ urls: [URL]) {
        let projects = urls.filter { OpenableFile($0) == .project }
        let media = urls.filter { OpenableFile($0) == .media }
        let other = urls.filter { OpenableFile($0) == nil }
        for url in projects {
            openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error { NSApp.presentError(error) }
            }
        }
        if !media.isEmpty {
            do {
                try newProjectEditor()?.importFiles(media, place: true, at: 0)
            } catch {
                NSApp.presentError(error)
            }
        }
        if !other.isEmpty {
            let names = other.prefix(5).map(\.lastPathComponent).joined(separator: ", ")
            let alert = NSAlert()
            alert.messageText = String(localized: "WizRec can’t open \(names)")
            alert.informativeText = String(localized: "Drop a .cmproj or .tscproj project, or a video, audio or image file.")
            alert.runModal()
        }
    }

    /// Scripted and timed runs never add to the recent list (`StartScreenPolicy`); opening a
    /// project again brings it back to the start screen after a Remove from List.
    override func noteNewRecentDocumentURL(_ url: URL) {
        MainActor.assumeIsolated {
            guard StartScreenPolicy.notesRecentDocuments(options: AppEnvironment.options) else { return }
            let path = url.standardizedFileURL.path
            var hidden = StartScreenModel.hidden()
            if hidden.remove(path) != nil {
                UserDefaults.standard.set(Array(hidden).sorted(), forKey: RecentProjects.hiddenKey)
            }
            super.noteNewRecentDocumentURL(url)
        }
    }

    override func clearRecentDocuments(_ sender: Any?) {
        UserDefaults.standard.removeObject(forKey: RecentProjects.hiddenKey)
        super.clearRecentDocuments(sender)
        MainActor.assumeIsolated { StartWindowController.reloadIfShown() }
    }
}

/// File ▸ Open filter: projects and media by extension, plus folders to browse into.
final class OpenPanelFilter: NSObject, NSOpenSavePanelDelegate {
    func panel(_ sender: Any, shouldEnable url: URL) -> Bool { OpenableFile.enablesInOpenPanel(url) }
}
