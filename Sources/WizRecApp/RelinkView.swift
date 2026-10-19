import PlayerKit
import SwiftUI

/// Callbacks of the missing-media sheet.
struct RelinkActions {
    /// Pick a replacement file for one source.
    var locate: (Int64) -> Void
    /// Pick a folder; every missing file found there by name is relinked.
    var searchFolder: () -> Void
    var close: () -> Void
}

/// Lists the project's missing media (typical for projects made on another Mac or PC)
/// and relinks them one by one or from a folder.
struct RelinkView: View {
    let model: EditorDocumentModel
    let actions: RelinkActions
    let status: String?

    var body: some View {
        let _ = model.revision
        VStack(alignment: .leading, spacing: 12) {
            Text(model.missing.isEmpty ? "All media found" : "Missing media")
                .font(.title3.bold())
            Text(model.missing.isEmpty
                 ? "Every file this project uses is on this Mac."
                 : "\(model.missing.count) file\(model.missing.count == 1 ? " is" : "s are") not where the project expects. "
                   + "Locate each file, or search a folder that holds them (for projects made on another computer).")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !model.missing.isEmpty {
                List(model.missing) { m in
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text((m.src.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent)
                                .font(.callout.weight(.medium))
                            Text(m.src).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button("Locate…") { actions.locate(m.id) }
                    }
                }
                .frame(minHeight: 160)
            }
            if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
            HStack {
                if !model.missing.isEmpty { Button("Search Folder…") { actions.searchFolder() } }
                Spacer()
                Button("Done") { actions.close() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
