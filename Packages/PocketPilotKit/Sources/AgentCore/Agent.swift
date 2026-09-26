import Foundation
import OSLog

private let log = Logger(subsystem: "dev.typealias.PocketPilot", category: "AgentCore")

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
    /// Gestures performed before the first observation, for example leaving the app that started the run.
    public var preparation: [Gesture]
    /// Where the device is when observation begins, if the caller knows (for example "Home Screen").
    public var startsAt: String?

    /// How many times the same screen may recur before the pilot is told it is looping.
    static let loopLimit = 3

    /// The longest pause a pilot may request, so a model can't stall a run.
    static let longestWait = 30.0

    public init(
        device: some Device,
        pilot: some Pilot,
        maxSteps: Int = 40,
        settle: Duration = .milliseconds(700),
        preparation: [Gesture] = [],
        startsAt: String? = nil
    ) {
        self.device = device
        self.pilot = pilot
        self.maxSteps = maxSteps
        self.settle = settle
        self.preparation = preparation
        self.startsAt = startsAt
    }

    public enum Event: Sendable {
        /// The exact step handed to the pilot: screen, history, and context.
        case observed(Step)
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
        var previous: Screen?
        var visits: [[Element]: Int] = [:]
        var remembered: String?
        let apps = (try? await device.installedApps()) ?? []
        let mentionedApps = apps.named(in: goal)
        for gesture in preparation {
            try await device.perform(gesture)
            try await Task.sleep(for: settle)
        }
        while history.count < maxSteps {
            try Task.checkCancellation()

            let app = await Self.readFrontmostApp(from: device, apps: apps)
            let screen = try await device.observe()
            if let previous, let last = history.indices.last, history[last].failure == nil,
               history[last].decision.action.expectsChange, screen.looksUnchanged(from: previous) {
                let reason = "The screen did not change."
                history[last].failure = reason
                onEvent(.failed(history[last].decision.action, reason: reason))
            }
            previous = screen
            if let last = history.indices.last, case .type(let text, _) = history[last].decision.action,
               let shown = screen.element(showing: text) {
                history[last].confirmation = "typed, now on screen: [\(shown.id)]; to submit it, key return or tap the confirm button"
            }
            if !screen.elements.isEmpty {
                visits[screen.elements, default: 0] += 1
                if visits[screen.elements] == Self.loopLimit, let last = history.indices.last, history[last].failure == nil {
                    let reason = "You are going in circles: this exact screen has appeared \(Self.loopLimit) times. Try a different approach, or give up."
                    history[last].failure = reason
                    onEvent(.failed(history[last].decision.action, reason: reason))
                }
            }

            let step = Step(goal: goal, screen: screen, history: history, remembered: remembered, mentionedApps: mentionedApps, app: app)
            onEvent(.observed(step))

            let decision = try await pilot.decide(step)
            if let keep = decision.keepFacts { remembered = keep }
            onEvent(.decided(decision))

            switch decision.action {
            case .done(let summary): return .completed(summary: summary)
            case .giveUp(let reason): return .abandoned(reason: reason)
            case .wait(let seconds): try await Task.sleep(for: .seconds(seconds.clamped(to: 0...Self.longestWait)))
            default: break
            }

            var turn = Turn(decision: decision, failure: history.repeatedFailure(of: decision.action))
            if turn.failure == nil {
                turn.failure = try await perform(decision.action, on: step.screen, apps: apps)
            }
            if let failure = turn.failure {
                onEvent(.failed(decision.action, reason: failure))
            }
            history.append(turn)
            try await Task.sleep(for: settle)
        }
        return .outOfSteps
    }

    /// Performs `action`, returning a description of any failure the pilot can recover from.
    /// Failures that make further progress impossible are thrown.
    private func perform(_ action: Action, on screen: Screen, apps: [InstalledApp]) async throws -> String? {
        do {
            if case .type(let text, replacing: true) = action {
                for gesture in [Gesture.selectAll, .key(.delete), .type(text)] {
                    try await device.perform(gesture)
                }
                return nil
            }
            guard let gesture = try action.gesture(on: screen, apps: apps) else { return nil }
            try await device.perform(gesture)
            return nil
        } catch let error as ResolutionError {
            return error.description
        } catch let error as DeviceError where error.isRecoverable {
            return error.description
        }
    }

    private static func readFrontmostApp(from device: any Device, apps: [InstalledApp]) async -> FrontmostApp? {
        let started = ContinuousClock.now
        do {
            let raw = try await device.frontmostApp()
            let app = raw?.resolved(using: apps)
            let ms = Int((ContinuousClock.now - started) / .milliseconds(1))
            log.notice("frontmost app \(app?.briefName ?? "nil", privacy: .public) raw=\(raw?.name ?? "nil", privacy: .public) in \(ms)ms")
            return app
        } catch {
            let ms = Int((ContinuousClock.now - started) / .milliseconds(1))
            log.notice("frontmost app failed in \(ms)ms: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}

extension Action {
    /// Whether performing this action should visibly change the screen.
    /// Typing is excluded: text entered into a field often isn't visible to OCR or accessibility,
    /// and reporting "no change" makes pilots type the same text again.
    var expectsChange: Bool {
        switch self {
        case .wait, .done, .giveUp, .type: false
        default: true
        }
    }
}

extension Screen {
    /// Whether nothing the pilot can see has changed since `earlier`. Screens without elements never compare equal.
    func looksUnchanged(from earlier: Screen) -> Bool {
        !elements.isEmpty && elements == earlier.elements
    }
}

extension Screen {
    /// The element whose text includes `text`, ignoring case and surrounding whitespace.
    func element(showing text: String) -> Element? {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return nil }
        return elements.first { ($0.label + " " + ($0.value ?? "")).lowercased().contains(needle) }
    }
}

extension [Turn] {
    /// Why `action` should be skipped rather than tried a third time in a row.
    func repeatedFailure(of action: Action) -> String? {
        if case .type = action, last?.decision.action == action {
            return "Skipped: this text was already typed. Check the field; continue with key return or the next step."
        }
        guard count >= 2, suffix(2).allSatisfy({ $0.decision.action == action }) else { return nil }
        return "Skipped: this was already tried twice in a row. Choose something different, or give up."
    }
}

extension DeviceError: CustomStringConvertible {
    /// Whether the next step may succeed where this one failed.
    public var isRecoverable: Bool {
        switch self {
        case .timedOut, .service: true
        case .tunnelUnavailable, .wifiOff, .connectionFailed, .pairingRejected, .developerImageMissing, .disconnected: false
        }
    }

    public var description: String {
        switch self {
        case .tunnelUnavailable: "LocalDevVPN is not connected."
        case .wifiOff: "Join Wi-Fi to continue. iOS only lets LocalDevVPN reach this iPhone's developer services while joined to a Wi-Fi network. Join any Wi-Fi network (another phone's hotspot works too), then reconnect LocalDevVPN."
        case .connectionFailed(let detail): "Couldn't connect to this iPhone: \(detail)"
        case .pairingRejected: "The pairing file was rejected by the device."
        case .developerImageMissing: "The Developer Disk Image is not mounted."
        case .disconnected: "The connection to the device closed."
        case .timedOut: "The device did not respond in time."
        case .service(let message): message
        }
    }
}
