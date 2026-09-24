import AgentCore
import CoreGraphics
import DeviceLink
import Foundation
import Observation
import OSLog
import RunActivity

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

    private static let log = Logger(subsystem: "dev.typealias.PocketPilot", category: "Run")

    private(set) var phase = Phase.idle
    private(set) var entries: [Entry] = []
    private(set) var latestScreenshot: CGImage?
    private var task: Task<Void, Never>?
    private let connection = Connection()
    private let runActivity = LiveActivityController()
    private var currentStep = 0
    private var lastThought = ""
    private var lastAction = ""

    var isRunning: Bool { task != nil }
    var connectionState: Connection.State { connection.state }

    /// Connects on first use, then drives the chosen pilot toward `goal`.
    func start(_ goal: String, pairing: PairingFile, pilot: any Pilot) {
        guard !isRunning else { return }
        entries = []
        latestScreenshot = nil
        currentStep = 0
        lastThought = ""
        lastAction = ""
        phase = .connecting
        Task { await runActivity.start(goal: goal) }
        task = Task {
            defer { task = nil }
            do {
                let phone = try await connection.phone(pairing: pairing)
                let outcome = try await Agent(device: phone, pilot: pilot).run(goal) { record($0) }
                phase = .finished(outcome)
                await runActivity.end(conclusion: phase.conclusion ?? "")
            } catch where Task.isCancelled {
                phase = .idle
                await runActivity.end(conclusion: String(localized: "Run stopped."))
            } catch let error as DeviceError where !error.isRecoverable {
                Self.log.error("Run failed: \(error.description, privacy: .public)")
                connection.reset()
                phase = .failed(error.description)
                await runActivity.end(conclusion: error.description)
            } catch {
                Self.log.error("Run failed: \(String(describing: error), privacy: .public)")
                phase = .failed(String(describing: error))
                await runActivity.end(conclusion: String(describing: error))
            }
        }
    }

    /// Cancels the current run; its task clears itself once the agent unwinds.
    func stop() {
        task?.cancel()
    }

    private func record(_ event: Agent.Event) {
        Self.log.info("\(String(describing: event), privacy: .public)")
        switch event {
        case .observed(let screen, let step):
            phase = .running(step: step)
            currentStep = step
            latestScreenshot = screen.screenshot.image
            Task { await runActivity.update(step: step, thought: lastThought, action: lastAction) }
        case .decided(let decision):
            let action = String(describing: decision.action)
            entries.append(Entry(id: entries.count, thought: decision.thought, action: action))
            lastThought = decision.thought
            lastAction = action
            Task { await runActivity.update(step: currentStep, thought: lastThought, action: lastAction) }
        case .failed(_, let reason):
            if let last = entries.indices.last { entries[last].failure = reason }
        }
    }
}

extension RunModel: RunControl {}
