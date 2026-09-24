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
    /// PiP keep-alive. Internal so RunView can host its source layer.
    let keeper = BackgroundKeeper()
    /// The latest Live Activity update; each new one waits for it so updates land in order.
    private var activityUpdate: Task<Void, Never>?
    private var currentStep = 0
    private var lastThought = ""
    private var lastAction = ""

    init() {
        keeper.onPause = { [weak self] in self?.stop() }
    }

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
        task = Task {
            defer { task = nil }
            await runActivity.start(goal: goal)
            keeper.start()
            do {
                let phone = try await connection.phone(pairing: pairing)
                let outcome = try await Agent(device: phone, pilot: pilot).run(goal) { record($0) }
                phase = .finished(outcome)
                await endActivity(phase.conclusion ?? "")
            } catch where Task.isCancelled {
                phase = .idle
                await endActivity(String(localized: "Run stopped."))
            } catch let error as DeviceError where !error.isRecoverable {
                Self.log.error("Run failed: \(error.description, privacy: .public)")
                connection.reset()
                phase = .failed(error.description)
                await endActivity(error.description)
            } catch {
                Self.log.error("Run failed: \(String(describing: error), privacy: .public)")
                phase = .failed(String(describing: error))
                await endActivity(String(describing: error))
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
            updateActivity()
        case .decided(let decision):
            let action = String(describing: decision.action)
            entries.append(Entry(id: entries.count, thought: decision.thought, action: action))
            lastThought = decision.thought
            lastAction = action
            updateActivity()
        case .failed(_, let reason):
            if let last = entries.indices.last { entries[last].failure = reason }
        }
    }
}

extension RunModel: RunControl {}

extension RunModel {
    private func updateActivity() {
        let previous = activityUpdate
        let (step, thought, action) = (currentStep, lastThought, lastAction)
        activityUpdate = Task {
            await previous?.value
            await runActivity.update(step: step, thought: thought, action: action)
            await MainActor.run { keeper.render(step: step, thought: thought, action: action) }
        }
    }

    /// Ends the activity after any update still in flight, so a late update can't outlive the run.
    private func endActivity(_ conclusion: String) async {
        await activityUpdate?.value
        await runActivity.end(conclusion: conclusion)
        keeper.stop()
    }
}
