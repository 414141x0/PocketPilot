import Foundation

/// Policy configuring execution constraints for an agent run.
public struct RunPolicy: Sendable, Hashable {
    /// When true, all actions that could mutate device state are refused.
    public var readOnly: Bool

    public init(readOnly: Bool = false) {
        self.readOnly = readOnly
    }

    public static let `default` = RunPolicy()
    public static let readOnly = RunPolicy(readOnly: true)

    /// Whether this run operates in read-only mode for the given goal.
    public func isReadOnly(for goal: String) -> Bool {
        if readOnly { return true }
        let lower = goal.lowercased()
        return lower.contains("do not change")
            || lower.contains("don't change")
            || lower.contains("dont change")
            || lower.contains("do not modify")
            || lower.contains("don't modify")
            || lower.contains("dont modify")
            || lower.contains("read-only")
            || lower.contains("read only")
    }
}
