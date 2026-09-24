import ActivityKit
import RunActivity

/// Drives the run's Live Activity so RunModel stays readable.
/// Best effort: if activities are disabled, the run proceeds without one.
/// Stateless by design: ActivityKit's Activity is non-Sendable with nonisolated
/// async methods, so the value is looked up fresh per call and never stored
/// across an isolation boundary.
struct RunActivity: Sendable {
    init() {
        // A previous launch may have died mid-run; never leave its banner behind.
        Task {
            await Self.endStaleActivities()
        }
    }

    nonisolated func start(goal: String) async {
        await Self.endStaleActivities()
        _ = try? Activity.request(
            attributes: RunAttributes(goal: goal),
            content: ActivityContent(state: RunAttributes.ContentState(step: 0, action: "", thought: ""), staleDate: nil)
        )
    }

    nonisolated func update(step: Int, thought: String, action: String) async {
        guard let activity = Activity<RunAttributes>.activities.first else { return }
        await activity.update(
            ActivityContent(
                state: RunAttributes.ContentState(step: step, action: action, thought: thought), staleDate: nil
            )
        )
    }

    nonisolated func end(conclusion: String) async {
        guard let activity = Activity<RunAttributes>.activities.first else { return }
        let lastStep = activity.contentState.step
        await activity.end(
            ActivityContent(
                state: RunAttributes.ContentState(step: lastStep, action: "", thought: conclusion), staleDate: nil
            ),
            dismissalPolicy: .default
        )
    }

    private static func endStaleActivities() async {
        for stale in Activity<RunAttributes>.activities {
            await stale.end(nil, dismissalPolicy: .immediate)
        }
    }
}
