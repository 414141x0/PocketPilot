import AgentCore
import CoreGraphics
import DeviceLink
import Foundation
import Observation

/// Owns one agent run at a time and publishes its progress to the UI.
@Observable
final class RunModel {
    enum Phase: Equatable {
        case idle
        case connecting
        case running(step: Int)
        case finished(Agent.Outcome)
        case failed(String)

        /// What to tell the user once a run has ended.
        var conclusion: String? {
            switch self {
            case .finished(.completed(let summary)): summary
            case .finished(.abandoned(let reason)): reason
            case .finished(.outOfSteps): String(localized: "Stopped after reaching the step limit.")
            case .failed(let message): message
            case .idle, .connecting, .running: nil
            }
        }
    }

    struct Entry: Identifiable, Equatable {
        let id: Int
        let thought: String
        let action: String
        var failure: String?
    }

    private(set) var phase = Phase.idle
    private(set) var entries: [Entry] = []
    private(set) var latestScreenshot: CGImage?
    private var task: Task<Void, Never>?
    private let connection = Connection()

    var isRunning: Bool { task != nil }
    var connectionState: Connection.State { connection.state }

    /// Connects on first use, then drives the chosen pilot toward `goal`.
    func start(_ goal: String, pairing: PairingFile, pilot: any Pilot) {
        guard !isRunning else { return }
        entries = []
        latestScreenshot = nil
        phase = .connecting
        task = Task {
            defer { task = nil }
            do {
                let phone = try await connection.phone(pairing: pairing)
                let outcome = try await Agent(device: phone, pilot: pilot).run(goal) { record($0) }
                phase = .finished(outcome)
            } catch is CancellationError {
                phase = .idle
            } catch let error as DeviceError where !error.isRecoverable {
                connection.reset()
                phase = .failed(error.description)
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
        case .observed(let screen, let step):
            phase = .running(step: step)
            latestScreenshot = screen.screenshot.image
        case .decided(let decision):
            entries.append(Entry(id: entries.count, thought: decision.thought, action: String(describing: decision.action)))
        case .failed(_, let reason):
            entries[entries.index(before: entries.endIndex)].failure = reason
        }
    }
}
