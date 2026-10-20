import AppKit
import PlayerKit
import TSCProjKit
import UniformTypeIdentifiers

/// A `.cmproj` package or `.tscproj` file, read-write (M2).
///
/// - Reads once through `ProjectBundle`; writes only when the user saves:
///   Save = `saveWithBackup` in place, Save As = `ProjectBundle.saveAs` (package copy).
///   No autosave, no versions, no drafts.
/// - New Project creates an untitled package in a temporary folder; its first save is a Save As.
/// - Dirty state comes from the undo history (`EditorDocumentModel.tracker`).
@objc(ProjectDocument)
final class ProjectDocument: NSDocument {
    /// Our imported type identifiers (declared in the app's Info.plist).
    nonisolated static let cmprojType = "com.devswizard.wizrec.cmproj"
    nonisolated static let tscprojType = "com.devswizard.wizrec.tscproj"

    static var contentTypes: [UTType] {
        [UTType(cmprojType), UTType(tscprojType),
         UTType(filenameExtension: "cmproj"), UTType(filenameExtension: "tscproj")]
            .compactMap { $0 }
    }

    private(set) var model: EditorDocumentModel?
    /// "Camtasia won't show WizRec backgrounds" after a save, once per document session.
    private let backgroundNotice = BackgroundSaveNotice()

    override class var autosavesInPlace: Bool { false }
    override class var autosavesDrafts: Bool { false }
    override class var preservesVersions: Bool { false }
    override class var readableTypes: [String] { [cmprojType, tscprojType] }
    override class var writableTypes: [String] { [cmprojType, tscprojType] }
    override class func isNativeType(_ type: String) -> Bool { true }
    override nonisolated func canAsynchronouslyWrite(to url: URL, ofType typeName: String,
                                                     for saveOperation: NSDocument.SaveOperationType) -> Bool { false }

    override init() {
        super.init()
        hasUndoManager = false
    }

    /// New Project: an empty 1920×1080 30 fps package in a temporary folder.
    func makeUntitled() throws {
        fileType = Self.cmprojType
        model = try EditorDocumentModel.untitled()
    }

    override nonisolated func read(from url: URL, ofType typeName: String) throws {
        try onMain { self.model = try EditorDocumentModel(url: url) }
    }

    // MARK: Writing

    override nonisolated func writableTypes(for saveOperation: NSDocument.SaveOperationType) -> [String] {
        (try? onMain { () -> [String] in
            guard let model = self.model, !model.isUntitled else { return [Self.cmprojType] }
            return [model.bundle.isPackage ? Self.cmprojType : Self.tscprojType]
        }) ?? [Self.cmprojType]
    }

    override func fileNameExtension(forType typeName: String, saveOperation: NSDocument.SaveOperationType) -> String? {
        typeName == Self.tscprojType ? "tscproj" : "cmproj"
    }

    override func prepareSavePanel(_ savePanel: NSSavePanel) -> Bool {
        savePanel.allowedContentTypes = writableTypes(for: .saveAsOperation).compactMap { UTType($0) }
        savePanel.isExtensionHidden = false
        savePanel.treatsFilePackagesAsDirectories = false
        return true
    }

    /// Our own write path: never NSDocument's temp-copy-and-swap (it would copy all media).
    override nonisolated func writeSafely(to url: URL, ofType typeName: String,
                                          for saveOperation: NSDocument.SaveOperationType) throws {
        try onMain { try self.write(url, operation: saveOperation) }
    }

    private func write(_ url: URL, operation: NSDocument.SaveOperationType) throws {
        guard let model else { throw Self.error("Nothing to save.") }
        switch operation {
        case .saveOperation where !model.isUntitled && Self.same(url, model.bundle.isPackage ? model.bundle.directory : model.bundle.projectFile):
            try model.save()
        case .saveOperation, .saveAsOperation:
            let current = model.bundle.isPackage ? model.bundle.directory : model.bundle.projectFile
            if Self.same(url, current) && !model.isUntitled {
                try model.save()
                break
            }
            // The save panel already asked whether to replace an existing item: move it to the Trash.
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            }
            let lost = try model.saveAs(to: url)
            if !lost.isEmpty {
                let names = lost.prefix(5).map { ($0.src as NSString).lastPathComponent }.joined(separator: ", ")
                DispatchQueue.main.async {
                    let a = NSAlert()
                    a.messageText = "Some media no longer resolves"
                    a.informativeText = "This .tscproj refers to media by relative path, and \(lost.count) file(s) "
                        + "are not next to the new location: \(names). Use File ▸ Relink Missing Media, or save as a .cmproj package."
                    a.runModal()
                }
            }
        default:
            throw Self.error("WizRec does not save copies or autosave in this version.")
        }
        updateChangeCount(.changeCleared)
        noteUnsignedBackgrounds(in: model)
    }

    /// Non-blocking notice above the canvas when the saved project uses WizRec backgrounds.
    private func noteUnsignedBackgrounds(in model: EditorDocumentModel) {
        guard let wc = windowControllers.lazy.compactMap({ $0 as? EditorWindowController }).first else { return }
        let enabled = AppPreferences.load(from: .standard).warnUnsignedBackgrounds
        guard enabled, !backgroundNotice.wasShown, !wc.options.isScripted else { return }
        let names = BackgroundSaveNotice.unsignedBackgrounds(in: model.bundle)
        if backgroundNotice.shouldShow(unsignedBackgrounds: names, scripted: wc.options.isScripted, enabled: enabled) {
            wc.ui.show(BackgroundSaveNotice.text, seconds: 12)
        }
    }

    override func data(ofType typeName: String) throws -> Data { throw Self.error("Use Save.") }

    override func autosave(withImplicitCancellability autosavingIsImplicitlyCancellable: Bool,
                           completionHandler: @escaping (Error?) -> Void) {
        completionHandler(nil)
    }
    override var hasUnautosavedChanges: Bool { false }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(saveTo(_:)), #selector(revertToSaved(_:)), #selector(duplicate(_:)), #selector(rename(_:)),
             #selector(move(_:)), #selector(lock(_:)), #selector(unlock(_:)), #selector(browseVersions(_:)):
            return false
        default:
            return super.validateUserInterfaceItem(item)
        }
    }

    /// Mirrors the model's dirty state into NSDocument (title-bar dot, close confirmation).
    func refreshEditedState() {
        guard let model else { return }
        let edited = model.isDirty || model.isUntitled && model.undo.canUndo
        if edited != isDocumentEdited { updateChangeCount(edited ? .changeDone : .changeCleared) }
    }

    override func makeWindowControllers() {
        guard let model else { return }
        addWindowController(EditorWindowController(document: self, model: model, options: AppEnvironment.options))
    }

    /// Window close (and closing during quit): ask before cancelling running exports, then
    /// continue with NSDocument's usual unsaved-changes review.
    override func canClose(withDelegate delegate: Any, shouldClose shouldCloseSelector: Selector?,
                           contextInfo: UnsafeMutableRawPointer?) {
        guard let wc = windowControllers.lazy.compactMap({ $0 as? EditorWindowController }).first,
              wc.exportsBlockingClose > 0 else {
            super.canClose(withDelegate: delegate, shouldClose: shouldCloseSelector, contextInfo: contextInfo)
            return
        }
        let context = CloseContext(delegate: delegate, selector: shouldCloseSelector, info: contextInfo)
        wc.confirmCancellingExports { [weak self] ok in
            guard let self else { return }
            if ok {
                self.canClose(withDelegate: context.delegate, shouldClose: context.selector, contextInfo: context.info)
            } else {
                self.reply(false, to: context)
            }
        }
    }

    /// NSDocument's close callback arguments, kept across the alert.
    private struct CloseContext {
        let delegate: Any
        let selector: Selector?
        let info: UnsafeMutableRawPointer?
    }

    /// Calls `- (void)document:(NSDocument *)doc shouldClose:(BOOL)flag contextInfo:(void *)info` on the delegate.
    private func reply(_ flag: Bool, to c: CloseContext) {
        guard let sel = c.selector, let obj = c.delegate as? NSObject, obj.responds(to: sel) else { return }
        typealias Fn = @convention(c) (NSObject, Selector, NSDocument, ObjCBool, UnsafeMutableRawPointer?) -> Void
        let fn = unsafeBitCast(obj.method(for: sel), to: Fn.self)
        fn(obj, sel, self, ObjCBool(flag), c.info)
    }

    override func close() {
        for wc in windowControllers { (wc as? EditorWindowController)?.shutdown() }
        model?.discardUntitled()
        super.close()
    }

    // MARK: Helpers

    private static func same(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.resolvingSymlinksInPath().path == b.standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func error(_ text: String) -> NSError {
        NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [NSLocalizedDescriptionKey: text])
    }
}

/// Runs `body` on the main actor. NSDocument calls readers and writers on the main thread
/// here (no concurrent reading, `canAsynchronouslyWrite` false); this traps if it ever does not.
nonisolated func onMain<T: Sendable>(_ body: @MainActor () throws -> T) throws -> T {
    try MainActor.assumeIsolated(body)
}
