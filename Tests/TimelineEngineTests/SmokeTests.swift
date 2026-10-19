import Testing
import Foundation
import TSCProjKit
@testable import TimelineEngine

@MainActor @Test func emptyStackCannotUndo() throws {
    let project = try Project(data: Data(#"{"editRate":705600000}"#.utf8))
    let stack = UndoStack(project: project)
    #expect(!stack.canUndo && !stack.canRedo)
}
