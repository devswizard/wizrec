import AppKit
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

    override func beginOpenPanel(_ openPanel: NSOpenPanel, forTypes inTypes: [String]?,
                                 completionHandler: @escaping (Int) -> Void) {
        openPanel.allowedContentTypes = ProjectDocument.contentTypes
        openPanel.treatsFilePackagesAsDirectories = false
        openPanel.allowsMultipleSelection = true
        openPanel.begin { completionHandler($0.rawValue) }
    }
}
