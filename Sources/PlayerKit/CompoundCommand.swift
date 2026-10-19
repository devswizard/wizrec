import TimelineEngine
import TSCProjKit

/// Several edits as one undo step (e.g. Add Track + Add to Timeline).
///
/// Steps are built lazily, in order, the first time the command is applied, so a
/// step can use ids produced by earlier steps (`AddSource.sourceID`). Redo re-applies
/// the same step instances. A failing step reverts the steps already applied, so the
/// project is left unchanged on throw.
@MainActor
public final class CompoundCommand: EditCommand {
    public let name: String
    /// Builds step `i` from the steps applied so far.
    public typealias Builder = (_ project: Project, _ done: [any EditCommand]) throws -> any EditCommand
    private let builders: [Builder]
    public private(set) var steps: [any EditCommand] = []

    public init(name: String, _ builders: [Builder]) {
        self.name = name
        self.builders = builders
    }

    public func apply(to project: Project) throws {
        var applied: [any EditCommand] = []
        do {
            for (i, build) in builders.enumerated() {
                let step = i < steps.count ? steps[i] : try build(project, applied)
                try step.apply(to: project)
                applied.append(step)
            }
        } catch {
            for step in applied.reversed() { try? step.revert(on: project) }
            throw error
        }
        steps = applied
    }

    public func revert(on project: Project) throws {
        for step in steps.reversed() { try step.revert(on: project) }
    }
}
