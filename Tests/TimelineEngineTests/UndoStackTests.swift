import Foundation
import Testing
import TSCProjKit
@testable import TimelineEngine

/// Sets the project title; can be told to fail on apply or revert.
@MainActor
private final class SetTitle: EditCommand {
    let title: String
    var failApply = false
    var failRevert = false
    private var old: JSON??
    var name: String { "Rename \(title)" }

    init(_ title: String) { self.title = title }

    func apply(to project: Project) throws {
        if failApply { throw EditError.invalid("boom") }
        old = .some(project.root["title"])
        project.root["title"] = .string(title)
    }

    func revert(on project: Project) throws {
        if failRevert { throw EditError.invalid("boom") }
        guard let old else { throw EditError.invalid("not applied") }
        project.root["title"] = old
        self.old = nil
    }
}

@MainActor private func newStack(limit: Int = 500) throws -> UndoStack {
    UndoStack(project: try Project(data: Data(#"{"title" : "a", "editRate" : 705600000}"#.utf8)), limit: limit)
}

@MainActor private func title(_ s: UndoStack) -> String? { s.project.root["title"]?.string }

@MainActor @Test func emptyStackCannotUndoOrRedo() throws {
    let stack = try newStack()
    #expect(!stack.canUndo && !stack.canRedo)
    #expect(stack.undoName == nil && stack.redoName == nil)
    try stack.undo()
    try stack.redo()
    #expect(stack.changeCount == 0)
}

@MainActor @Test func performUndoRedo() throws {
    let stack = try newStack()
    try stack.perform(SetTitle("b"))
    #expect(title(stack) == "b")
    #expect(stack.canUndo && !stack.canRedo)
    #expect(stack.undoName == "Rename b")

    try stack.undo()
    #expect(title(stack) == "a")
    #expect(!stack.canUndo && stack.canRedo)
    #expect(stack.redoName == "Rename b")

    try stack.redo()
    #expect(title(stack) == "b")
    #expect(stack.canUndo && !stack.canRedo)
}

@MainActor @Test func undoRestoresExactBytes() throws {
    let stack = try newStack()
    let before = stack.project.serialized()
    try stack.perform(SetTitle("b"))
    try stack.perform(SetTitle("c"))
    try stack.undo()
    try stack.undo()
    #expect(stack.project.serialized() == before)
}

@MainActor @Test func performClearsRedo() throws {
    let stack = try newStack()
    try stack.perform(SetTitle("b"))
    try stack.perform(SetTitle("c"))
    try stack.undo()
    #expect(stack.canRedo)
    try stack.perform(SetTitle("d"))
    #expect(!stack.canRedo)
    #expect(title(stack) == "d")
    try stack.undo()
    #expect(title(stack) == "b")
}

@MainActor @Test func limitDropsOldestCommands() throws {
    let stack = try newStack(limit: 2)
    for t in ["b", "c", "d"] { try stack.perform(SetTitle(t)) }
    try stack.undo()
    try stack.undo()
    #expect(!stack.canUndo)
    #expect(title(stack) == "b")  // "b" itself can no longer be undone
}

@MainActor @Test func changeCountBumpsOnEveryChange() throws {
    let stack = try newStack()
    try stack.perform(SetTitle("b"))
    #expect(stack.changeCount == 1)
    try stack.undo()
    #expect(stack.changeCount == 2)
    try stack.redo()
    #expect(stack.changeCount == 3)
    try stack.redo()  // nothing to redo: no change
    #expect(stack.changeCount == 3)
}

@MainActor @Test func failingApplyLeavesStackAndProjectUntouched() throws {
    let stack = try newStack()
    try stack.perform(SetTitle("b"))
    try stack.undo()
    let before = stack.project.serialized()
    let bad = SetTitle("x")
    bad.failApply = true
    #expect(throws: EditError.self) { try stack.perform(bad) }
    #expect(stack.project.serialized() == before)
    #expect(stack.changeCount == 2)
    #expect(!stack.canUndo && stack.canRedo)  // redo survives a failed perform
    #expect(stack.redoName == "Rename b")
}

@MainActor @Test func failingUndoOrRedoKeepsHistory() throws {
    let stack = try newStack()
    let cmd = SetTitle("b")
    try stack.perform(cmd)
    cmd.failRevert = true
    #expect(throws: EditError.self) { try stack.undo() }
    #expect(stack.canUndo && !stack.canRedo && stack.changeCount == 1)

    cmd.failRevert = false
    try stack.undo()
    cmd.failApply = true
    #expect(throws: EditError.self) { try stack.redo() }
    #expect(!stack.canUndo && stack.canRedo && stack.changeCount == 2)
}

@MainActor @Test func undoStackDrivesRealCommands() throws {
    let p = try makeProject(tracks: tracks(track(0, [leaf(10, start: 0, dur: 100)])))
    let stack = UndoStack(project: p)
    let before = p.serialized()
    try stack.perform(SplitClip(clipID: 10, at: 40))
    try stack.perform(MoveClip(clipID: 11, toTrack: 0, start: 200))
    try stack.perform(TrimClip(clipID: 10, edge: .end, to: 20))
    let edited = p.serialized()
    try stack.undo(); try stack.undo(); try stack.undo()
    #expect(p.serialized() == before)
    try stack.redo(); try stack.redo(); try stack.redo()
    #expect(p.serialized() == edited)
}
