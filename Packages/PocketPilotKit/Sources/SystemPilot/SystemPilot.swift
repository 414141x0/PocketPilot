public import AgentCore
public import Foundation
public import FoundationModels
import CoreGraphics

/// A pilot backed by Apple's on-device FoundationModels SystemLanguageModel.
public struct SystemPilot: Pilot {
    private let model: SystemLanguageModel
    public let maxHistoryTurns: Int
    private let overheadCache: OverheadCache

    public init(model: SystemLanguageModel = .default, maxHistoryTurns: Int = 5) {
        self.model = model
        self.maxHistoryTurns = maxHistoryTurns
        self.overheadCache = OverheadCache()
    }

    public func decide(_ step: Step) async throws -> Decision {
        guard model.isAvailable else {
            throw SystemPilotError.modelUnavailable(model.availability)
        }

        let fixedCost = try await overheadCache.overhead(for: model)
        let budget = max(0, model.contextSize - fixedCost)

        var historyLimit = maxHistoryTurns
        var elementLimit = 60

        let image = await step.screen.markedScreenshot().image
        var prompt = makePrompt(step: step, image: image, historyLimit: historyLimit, elementLimit: elementLimit)
        while try await model.tokenCount(for: prompt) > budget {
            if elementLimit > 20 {
                elementLimit -= 10
            } else if historyLimit > 1 {
                historyLimit -= 1
            } else {
                break
            }
            prompt = makePrompt(step: step, image: image, historyLimit: historyLimit, elementLimit: elementLimit)
        }

        let session = LanguageModelSession(model: model, instructions: Self.instructions)
        let response = try await session.respond(to: prompt, generating: Reply.self)
        return Self.mapDecision(response.content)
    }

    private func makePrompt(step: Step, image: CGImage, historyLimit: Int, elementLimit: Int) -> Prompt {
        Prompt {
            step.brief(historyLimit: historyLimit, elementLimit: elementLimit)
            Attachment(image).label("screenshot")
        }
    }

    static func mapDecision(_ reply: Reply) -> Decision {
        let action: Action = switch reply.action {
        case .tap(let id): .tap(.element(id))
        case .tapPoint(let x, let y): .tap(.point(Point(grid: x, y)))
        case .longPress(let id): .longPress(.element(id))
        case .scroll(let dir, let id): .scroll(dir.toDirection(), in: id.map { .element($0) })
        case .type(let text): .type(text)
        case .press(let btn): .press(btn.toButton())
        case .open(let bundleID): .open(bundleID: bundleID)
        case .wait(let seconds): .wait(seconds: seconds)
        case .done(let summary): .done(summary: summary)
        case .giveUp(let reason): .giveUp(reason: reason)
        }
        return Decision(thought: reply.thought, action: action)
    }
}

@Generable(description: "Agent decision")
struct Reply: Sendable {
    @Guide(description: "one short sentence") var thought: String
    var action: Choice
}

@Generable enum Heading: Sendable {
    case up, down, left, right

    func toDirection() -> Direction {
        switch self {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        }
    }
}

@Generable enum Key: Sendable {
    case home, lock, volumeUp, volumeDown

    func toButton() -> HardwareButton {
        switch self {
        case .home: .home
        case .lock: .lock
        case .volumeUp: .volumeUp
        case .volumeDown: .volumeDown
        }
    }
}

@Generable enum Choice: Sendable {
    case tap(element: Int)
    case tapPoint(x: Int, y: Int)
    case longPress(element: Int)
    case scroll(direction: Heading, element: Int?)
    case type(text: String)
    case press(button: Key)
    case open(bundleID: String)
    case wait(seconds: Double)
    case done(summary: String)
    case giveUp(reason: String)
}

public enum SystemPilotError: LocalizedError, Sendable {
    case modelUnavailable(SystemLanguageModel.Availability)

    public var errorDescription: String? {
        switch self {
        case .modelUnavailable(let availability):
            "System language model is unavailable: \(availability)"
        }
    }
}

private actor OverheadCache {
    private var cached: Int?

    func overhead(for model: SystemLanguageModel) async throws -> Int {
        if let cached { return cached }
        let instructionsTokens = try await model.tokenCount(for: Instructions(SystemPilot.instructions))
        let schemaTokens = try await model.tokenCount(for: Reply.generationSchema)
        let total = instructionsTokens + schemaTokens + 300
        cached = total
        return total
    }
}
