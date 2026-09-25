import Foundation

/// A model that looks at the screen and decides what to do next.
///
/// Pilots are stateless policies: every call receives the goal, the current
/// screen, and the full history, so conformers stay simple value types
/// and the loop owns all state.
public protocol Pilot: Sendable {
    func decide(_ step: Step) async throws -> Decision
}

/// Everything a ``Pilot`` needs to choose the next action.
public struct Step: Sendable {
    public var goal: String
    public var screen: Screen
    public var history: [Turn]
    /// The latest facts the pilot asked to remember with a `Keep:` line, if any.
    public var remembered: String?

    public init(goal: String, screen: Screen, history: [Turn] = [], remembered: String? = nil) {
        self.goal = goal
        self.screen = screen
        self.history = history
        self.remembered = remembered
    }

    public var number: Int { history.count + 1 }
}

/// A pilot's choice, with the short rationale shown to the user.
public struct Decision: Sendable, Hashable, Codable {
    public var thought: String
    public var action: Action

    public init(thought: String = "", action: Action) {
        self.thought = thought
        self.action = action
    }
}

extension Decision {
    /// The facts after the last `Keep:` in the thought, to the end of that line, capped at
    /// 200 characters. Models often write it inline, so it needn't start a line.
    public var keepFacts: String? {
        guard let marker = thought.range(of: "Keep:", options: [.backwards, .caseInsensitive]) else { return nil }
        let facts = thought[marker.upperBound...].prefix { !$0.isNewline }.trimmingCharacters(in: .whitespaces)
        return facts.isEmpty ? nil : String(facts.prefix(200))
    }
}

/// A completed step: what was decided and whether the device carried it out.
public struct Turn: Sendable, Hashable {
    public var decision: Decision
    /// Why the action could not be performed, fed back so the pilot can recover.
    public var failure: String?

    public init(decision: Decision, failure: String? = nil) {
        self.decision = decision
        self.failure = failure
    }
}
