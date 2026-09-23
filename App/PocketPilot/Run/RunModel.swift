import AgentCore
import Observation

/// Owns one agent run at a time and publishes its progress to the UI.
@Observable
final class RunModel {
    enum Phase: Equatable {
        case idle
        case running(step: Int)
        case finished(Agent.Outcome)
        case failed(String)
    }

    struct Entry: Identifiable, Equatable {
        let id: Int
        let thought: String
        let action: String
        var failure: String?
    }

    private(set) var phase = Phase.idle
    private(set) var entries: [Entry] = []
    private var task: Task<Void, Never>?

    var isRunning: Bool { task != nil }

    func start(_ goal: String, with agent: Agent) {
        guard !isRunning else { return }
        entries = []
        phase = .running(step: 0)
        task = Task {
            defer { task = nil }
            do {
                let outcome = try await agent.run(goal) { record($0) }
                phase = .finished(outcome)
            } catch is CancellationError {
                phase = .idle
            } catch {
                phase = .failed(String(describing: error))
            }
        }
    }

    /// Cancels the current run; its task clears itself once the agent unwinds.
    func stop() {
        task?.cancel()
    }

    private func record(_ event: Agent.Event) {
        switch event {
        case .observed(_, let step):
            phase = .running(step: step)
        case .decided(let decision):
            entries.append(Entry(id: entries.count, thought: decision.thought, action: String(describing: decision.action)))
        case .failed(_, let reason):
            entries[entries.index(before: entries.endIndex)].failure = reason
        }
    }
}
