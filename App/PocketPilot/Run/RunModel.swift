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

    /// Gestures performed before the first observation: leave PocketPilot for the first
    /// Home Screen page (its own interface is never the target of a run, and a second Home
    /// press from the Home Screen always returns to page one).
    private static let preparation: [Gesture] = [.press(.home), .press(.home)]

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

    /// Probe a live session after the app resumes; reconnect if the tunnel died.
    func refreshSession(pairing: PairingFile) async {
        guard !isRunning else { return }
        await connection.refresh(pairing: pairing)
    }

    /// Connects on first use, then drives the chosen pilot toward `goal`.
    func start(_ goal: String, pairing: PairingFile, pilot: any Pilot) {
        guard !isRunning else { return }
        entries = []
        #if DEBUG
        StepRecorder.reset()
        #endif
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
                for gesture in Self.preparation {
                    try await phone.perform(gesture)
                    // Two quick Home presses open the App Switcher; let each one land.
                    try await Task.sleep(for: .milliseconds(700))
                }
                // Hide the PiP status card before the first observation so the pilot never sees it.
                await stashPiPCard(phone: phone)
                let outcome = try await Agent(device: PiPShieldedDevice(base: phone), pilot: pilot, startsAt: "Home Screen").run(goal) { record($0) }
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

    /// Flings the PiP status card into the left screen edge so the pilot's screenshots stay clean.
    /// Best effort: logs the outcome and never fails the run.
    @MainActor
    private func stashPiPCard(phone: any Device) async {
        var pipActive = false
        for _ in 0..<50 where !Task.isCancelled {
            if keeper.isPictureInPictureActive {
                pipActive = true
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard pipActive else {
            Self.log.info("pip stash skipped: pip never became active")
            return
        }
        do {
            // A fast flick stashes; a slow drag just moves the card. Retry once, faster.
            // PiP reports active before its window finishes animating in, so wait for the card to appear.
            var card: Element?
            for _ in 0..<6 where !Task.isCancelled {
                card = try await phone.observe().elements.first(where: Self.isPiPCard)
                if card != nil { break }
                try await Task.sleep(for: .milliseconds(500))
            }
            for (attempt, duration) in [Duration.milliseconds(120), .milliseconds(60)].enumerated() {
                if attempt > 0 {
                    card = try await phone.observe().elements.first(where: Self.isPiPCard)
                }
                guard let card else {
                    Self.log.info("\(attempt == 0 ? "pip stash: card never appeared" : "pip stash succeeded", privacy: .public)")
                    return
                }
                // The window spans most of the width; a long, fast flick from its middle stashes it.
                let start = Point(x: max(card.frame.center.x, 0.5), y: card.frame.center.y)
                try await phone.perform(.swipe(from: start, to: Point(x: 0, y: start.y), duration: duration))
                try await Task.sleep(for: .milliseconds(600))
            }
            let screen = try await phone.observe()
            if screen.elements.contains(where: Self.isPiPCard) {
                Self.log.error("pip stash failed: card still visible after retry")
            } else {
                Self.log.info("pip stash succeeded")
            }
        } catch {
            Self.log.error("pip stash failed: \(String(describing: error), privacy: .public)")
        }
    }

    private static func isPiPCard(_ element: Element) -> Bool {
        element.label.localizedCaseInsensitiveContains(BackgroundKeeper.cardMarker)
            || element.value?.localizedCaseInsensitiveContains(BackgroundKeeper.cardMarker) == true
    }

    private func record(_ event: Agent.Event) {
        Self.log.info("\(String(describing: event), privacy: .public)")
        switch event {
        case .observed(let step):
            #if DEBUG
            Task { await StepRecorder.record(step) }
            #endif
            phase = .running(step: step.number)
            currentStep = step.number
            latestScreenshot = step.screen.screenshot.image
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
            await MainActor.run { keeper.render(step: step, action: action) }
        }
    }

    /// Ends the activity after any update still in flight, so a late update can't outlive the run.
    private func endActivity(_ conclusion: String) async {
        await activityUpdate?.value
        await runActivity.end(conclusion: conclusion)
        keeper.stop()
    }
}
