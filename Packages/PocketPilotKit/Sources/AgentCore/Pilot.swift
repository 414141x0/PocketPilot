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

    public init(goal: String, screen: Screen, history: [Turn] = []) {
        self.goal = goal
        self.screen = screen
        self.history = history
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
