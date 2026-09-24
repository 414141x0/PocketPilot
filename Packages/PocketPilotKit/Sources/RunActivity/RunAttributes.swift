#if os(iOS)
import ActivityKit

/// Fixed attributes for the run Live Activity; the per-step part is ContentState.
/// Shared by the app and the widget extension through this target.
public struct RunAttributes: ActivityAttributes {
    public struct ContentState: Sendable, Hashable, Codable {
        public var step: Int
        public var action: String
        public var thought: String

        public init(step: Int, action: String, thought: String) {
            self.step = step
            self.action = action
            self.thought = thought
        }
    }

    public var goal: String

    public init(goal: String) {
        self.goal = goal
    }
}
#endif
