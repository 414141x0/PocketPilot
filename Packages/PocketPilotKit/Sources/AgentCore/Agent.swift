/// Drives a ``Device`` toward a goal by alternating observation, decision, and action.
///
/// ```swift
/// let agent = Agent(device: phone, pilot: OpenAIPilot(apiKey: key))
/// let outcome = try await agent.run("Turn on Low Power Mode") { event in
///     log.append(event)
/// }
/// ```
///
/// `run` executes on the caller's actor and suspends for every device and model
/// call, so a `@MainActor` view model can drive it directly. Cancel the calling
/// task to stop the run.
public struct Agent: Sendable {
    public var device: any Device
    public var pilot: any Pilot
    public var maxSteps: Int
    /// Time given to the UI to finish animating before the next observation.
    public var settle: Duration

    public init(device: some Device, pilot: some Pilot, maxSteps: Int = 40, settle: Duration = .milliseconds(700)) {
        self.device = device
        self.pilot = pilot
        self.maxSteps = maxSteps
        self.settle = settle
    }

    public enum Event: Sendable {
        case observed(Screen, step: Int)
        case decided(Decision)
        case failed(Action, reason: String)
    }

    public enum Outcome: Sendable, Hashable {
        case completed(summary: String)
        case abandoned(reason: String)
        case outOfSteps
    }

    public func run(_ goal: String, onEvent: (Event) -> Void = { _ in }) async throws -> Outcome {
        var history: [Turn] = []
        while history.count < maxSteps {
            try Task.checkCancellation()

            let step = Step(goal: goal, screen: try await device.observe(), history: history)
            onEvent(.observed(step.screen, step: step.number))

            let decision = try await pilot.decide(step)
            onEvent(.decided(decision))

            switch decision.action {
            case .done(let summary): return .completed(summary: summary)
            case .giveUp(let reason): return .abandoned(reason: reason)
            case .wait(let seconds): try await Task.sleep(for: .seconds(seconds))
            default: break
            }

            var turn = Turn(decision: decision)
            if let failure = try await perform(decision.action, on: step.screen) {
                turn.failure = failure
                onEvent(.failed(decision.action, reason: failure))
            }
            history.append(turn)
            try await Task.sleep(for: settle)
        }
        return .outOfSteps
    }

    /// Performs `action`, returning a description of any failure the pilot can recover from.
    /// Failures that make further progress impossible are thrown.
    private func perform(_ action: Action, on screen: Screen) async throws -> String? {
        do {
            guard let gesture = try action.gesture(on: screen) else { return nil }
            try await device.perform(gesture)
            return nil
        } catch let error as ResolutionError {
            return error.description
        } catch let error as DeviceError where error.isRecoverable {
            return error.description
        }
    }
}

extension DeviceError: CustomStringConvertible {
    /// Whether the next step may succeed where this one failed.
    public var isRecoverable: Bool {
        switch self {
        case .timedOut, .service: true
        case .tunnelUnavailable, .pairingRejected, .developerImageMissing: false
        }
    }

    public var description: String {
        switch self {
        case .tunnelUnavailable: "LocalDevVPN is not connected."
        case .pairingRejected: "The pairing file was rejected by the device."
        case .developerImageMissing: "The Developer Disk Image is not mounted."
        case .timedOut: "The device did not respond in time."
        case .service(let message): message
        }
    }
}
