public import AgentCore
public import Foundation
import CoreGraphics
public import FoundationModels

/// A pilot backed by Apple's on-device FoundationModels SystemLanguageModel.
public struct SystemPilot: Pilot {
    private let model: SystemLanguageModel
    public let maxHistoryTurns: Int

    public init(model: SystemLanguageModel = .default, maxHistoryTurns: Int = 5) {
        self.model = model
        self.maxHistoryTurns = maxHistoryTurns
    }

    public func decide(_ step: Step) async throws -> Decision {
        guard model.isAvailable else {
            throw SystemPilotError.modelUnavailable(model.availability)
        }

        let instructions = """
        You are an on-device iOS assistant that operates an iPhone.
        Observe the screen outline and screenshot image to decide the next action toward the user's goal.
        Provide a concise thought explaining your step, then populate the action fields.
        Coordinates are on a 1000x1000 grid.
        """

        let historySlice = step.history.suffix(maxHistoryTurns)
        let historyText: String
        if historySlice.isEmpty {
            historyText = "(first step)"
        } else {
            historyText = historySlice.enumerated().map { idx, turn in
                var line = "\(idx + 1). \(turn.decision.action)"
                if let failure = turn.failure { line += " — failed: \(failure)" }
                return line
            }.joined(separator: "\n")
        }

        let prompt = Prompt {
            "Goal: \(step.goal)\n\n"
            "History (recent):\n\(historyText)\n\n"
            "Screen Elements:\n\(step.screen.outline())\n\n"
            "Current display screenshot:"
            Attachment(step.screen.screenshot.image).label("screenshot")
        }

        let session = LanguageModelSession(model: model, instructions: instructions)
        let response = try await session.respond(to: prompt, generating: SystemDecisionPayload.self)
        return try await Self.mapDecision(response.content)
    }

    @concurrent
    static func mapDecision(_ payload: SystemDecisionPayload) async throws -> Decision {
        let action: Action
        switch payload.kind {
        case "tap":
            if let elementID = payload.elementID {
                action = .tap(.element(elementID))
            } else if let x = payload.gridX, let y = payload.gridY {
                action = .tap(.point(Point(grid: x, y)))
            } else {
                throw SystemPilotError.missingTarget("tap requires elementID or (gridX, gridY)")
            }

        case "longPress":
            if let elementID = payload.elementID {
                action = .longPress(.element(elementID))
            } else if let x = payload.gridX, let y = payload.gridY {
                action = .longPress(.point(Point(grid: x, y)))
            } else {
                throw SystemPilotError.missingTarget("longPress requires elementID or (gridX, gridY)")
            }

        case "scroll":
            guard let rawDir = payload.scrollDirection, let dir = Direction(rawValue: rawDir) else {
                throw SystemPilotError.invalidAction("scroll requires valid direction (up, down, left, right)")
            }
            let target = payload.elementID.map { Target.element($0) }
            action = .scroll(dir, in: target)

        case "type":
            action = .type(payload.text ?? "")

        case "press":
            guard let rawBtn = payload.button, let btn = HardwareButton(rawValue: rawBtn) else {
                throw SystemPilotError.invalidAction("press requires valid hardware button")
            }
            action = .press(btn)

        case "open":
            guard let bundleID = payload.bundleID, !bundleID.isEmpty else {
                throw SystemPilotError.invalidAction("open requires non-empty bundleID")
            }
            action = .open(bundleID: bundleID)

        case "wait":
            action = .wait(seconds: payload.waitSeconds ?? 1.0)

        case "done":
            action = .done(summary: payload.summaryOrReason ?? "")

        case "giveUp":
            action = .giveUp(reason: payload.summaryOrReason ?? "")

        default:
            throw SystemPilotError.invalidAction("Unknown action kind: \(payload.kind)")
        }

        return Decision(thought: payload.thought, action: action)
    }
}

/// A guided Generable mirror of agent decision that lives inside SystemPilot.
@Generable(description: "An agent action decision for an iOS device")
struct SystemDecisionPayload: Sendable {
    @Guide(description: "Reasoning and thought process explaining why this action was chosen")
    var thought: String

    @Guide(
        description: "Action type to perform",
        .anyOf(["tap", "longPress", "scroll", "type", "press", "open", "wait", "done", "giveUp"])
    )
    var kind: String

    @Guide(description: "Target accessibility element ID from outline (if targeting an element)")
    var elementID: Int?

    @Guide(description: "X coordinate on 1000x1000 grid (0...1000)", .range(0...1000))
    var gridX: Int?

    @Guide(description: "Y coordinate on 1000x1000 grid (0...1000)", .range(0...1000))
    var gridY: Int?

    @Guide(description: "Scroll direction", .anyOf(["up", "down", "left", "right"]))
    var scrollDirection: String?

    @Guide(description: "Text to type")
    var text: String?

    @Guide(description: "Hardware button", .anyOf(["home", "lock", "volumeUp", "volumeDown"]))
    var button: String?

    @Guide(description: "Bundle ID of app to launch")
    var bundleID: String?

    @Guide(description: "Seconds to wait (0.1 to 60.0)")
    var waitSeconds: Double?

    @Guide(description: "Completion summary for done action, or failure reason for giveUp")
    var summaryOrReason: String?
}

public enum SystemPilotError: LocalizedError, Sendable {
    case modelUnavailable(SystemLanguageModel.Availability)
    case missingTarget(String)
    case invalidAction(String)

    public var errorDescription: String? {
        switch self {
        case .modelUnavailable(let availability):
            "System language model is unavailable: \(availability)"
        case .missingTarget(let reason):
            "Missing action target: \(reason)"
        case .invalidAction(let reason):
            "Invalid action configuration: \(reason)"
        }
    }
}
