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
            let doc = try openUntitledDocumentAndDisplay(true)
            if doc.windowControllers.isEmpty { doc.makeWindowControllers() }
            let editor = doc.windowControllers.lazy.compactMap { $0 as? EditorWindowController }.first
            editor?.importFiles([url], place: true, at: 0)
            completionHandler(doc, false, nil)
        } catch {
            completionHandler(nil, false, error)
        }
    }
}

/// File ▸ Open filter: projects and media by extension, plus folders to browse into.
final class OpenPanelFilter: NSObject, NSOpenSavePanelDelegate {
    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        if OpenableFile(url) != nil { return true }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return values?.isDirectory == true && values?.isPackage != true
    }
}
