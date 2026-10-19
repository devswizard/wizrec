// Public interface of TimelineEngine, frozen by coordination/CONTRACTS.md.
// Changing anything here needs an API_CHANGE message and the lead's approval.

import Foundation
import Observation
import TSCProjKit

/// A reversible edit on a project. All mutation goes through TSCProjKit's JSON tree.
@MainActor
public protocol EditCommand: AnyObject {
    /// Undo-menu label, e.g. `"Split"`.
    var name: String { get }
    /// Applies the edit. On throw the project is left unchanged.
    func apply(to project: Project) throws
    /// Exactly reverses the last successful `apply` on the same project state.
    func revert(on project: Project) throws
}

public enum EditError: Error, Equatable {
    case clipNotFound(Int64)
    case trackNotFound(Int)
    case invalid(String)
}

/// Linear undo/redo history for one project. Performing a command clears redo.
@MainActor @Observable
public final class UndoStack {
    public let project: Project
    /// Maximum commands kept; oldest dropped first.
    public let limit: Int
    /// Increments on every perform/undo/redo; observe it to refresh views.
    public private(set) var changeCount = 0

    private var done: [any EditCommand] = []
    private var undone: [any EditCommand] = []

    public init(project: Project, limit: Int = 500) {
        self.project = project; self.limit = limit
    }

    public var canUndo: Bool { !done.isEmpty }
    public var canRedo: Bool { !undone.isEmpty }
    public var undoName: String? { done.last?.name }
    public var redoName: String? { undone.last?.name }

    public func perform(_ command: any EditCommand) throws {
        try command.apply(to: project)
        done.append(command)
        if done.count > limit { done.removeFirst(done.count - limit) }
        undone.removeAll()
        changeCount += 1
    }

    public func undo() throws {
        guard let c = done.last else { return }
        try c.revert(on: project)
        done.removeLast(); undone.append(c)
        changeCount += 1
    }

    public func redo() throws {
        guard let c = undone.last else { return }
        try c.apply(to: project)
        undone.removeLast(); done.append(c)
        changeCount += 1
    }
}
