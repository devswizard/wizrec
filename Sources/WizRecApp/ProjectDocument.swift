import AppKit
import PlayerKit
import UniformTypeIdentifiers

/// A `.cmproj` package or `.tscproj` file, opened read-only (M1).
///
/// Never writes: no autosave, no versions, no save actions; the bundle is read
/// once through `ProjectBundle`.
@objc(ProjectDocument)
final class ProjectDocument: NSDocument {
    /// Our imported type identifiers (declared in the app's Info.plist).
    static let cmprojType = "com.devswizard.wizrec.cmproj"
    static let tscprojType = "com.devswizard.wizrec.tscproj"

    static var contentTypes: [UTType] {
        [UTType(cmprojType), UTType(tscprojType),
         UTType(filenameExtension: "cmproj"), UTType(filenameExtension: "tscproj")]
            .compactMap { $0 }
    }

    private(set) var model: PlayerDocumentModel?

    override class var autosavesInPlace: Bool { false }
    override class var autosavesDrafts: Bool { false }
    override class var preservesVersions: Bool { false }
    override class var readableTypes: [String] { [cmprojType, tscprojType] }
    override class var writableTypes: [String] { [] }
    override class func isNativeType(_ type: String) -> Bool { false }

    /// NSDocument may call this off the main thread in principle; the model lives on the main actor.
    override nonisolated func read(from url: URL, ofType typeName: String) throws {
        if Thread.isMainThread {
            try MainActor.assumeIsolated { try load(url) }
        } else {
            try DispatchQueue.main.sync { try MainActor.assumeIsolated { try load(url) } }
        }
    }

    private func load(_ url: URL) throws {
        model = try PlayerDocumentModel(url: url)
    }

    private nonisolated var readOnlyError: NSError {
        NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError, userInfo: [
            NSLocalizedDescriptionKey: "WizRec opens projects read-only in this version.",
        ])
    }

    override func data(ofType typeName: String) throws -> Data { throw readOnlyError }
    override func write(to url: URL, ofType typeName: String) throws { throw readOnlyError }
    override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
                       completionHandler: @escaping (Error?) -> Void) {
        completionHandler(readOnlyError)
    }
    override func autosave(withImplicitCancellability autosavingIsImplicitlyCancellable: Bool,
                           completionHandler: @escaping (Error?) -> Void) {
        completionHandler(nil)
    }
    override var hasUnautosavedChanges: Bool { false }
    override var isDocumentEdited: Bool { false }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(save(_:)), #selector(saveAs(_:)), #selector(saveTo(_:)), #selector(revertToSaved(_:)),
             #selector(duplicate(_:)), #selector(rename(_:)), #selector(move(_:)), #selector(lock(_:)),
             #selector(unlock(_:)), #selector(browseVersions(_:)):
            return false
        default:
            return super.validateUserInterfaceItem(item)
        }
    }

    override func makeWindowControllers() {
        guard let model else { return }
        addWindowController(PlayerWindowController(model: model, options: AppEnvironment.options))
    }

    override func close() {
        for wc in windowControllers { (wc as? PlayerWindowController)?.shutdown() }
        super.close()
    }
}
