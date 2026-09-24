public import AgentCore
public import Foundation
public import FoundationModels
import PilotSchema

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
        let budget = max(0, model.contextSize - fixedCost - Self.imageAllowance)

        // Budget the text alone: counting tokens for a prompt with an image attachment fails
        // on current iOS 27 seeds, while responding to the same prompt succeeds.
        var historyLimit = maxHistoryTurns
        var elementLimit = 60
        while try await model.tokenCount(for: Prompt { step.brief(historyLimit: historyLimit, elementLimit: elementLimit) }) > budget {
            if elementLimit > 20 {
                elementLimit -= 10
            } else if historyLimit > 1 {
                historyLimit -= 1
            } else {
                break
            }
        }

        let image = await step.screen.markedScreenshot().image
        let prompt = Prompt {
            step.brief(historyLimit: historyLimit, elementLimit: elementLimit)
            Attachment(image).label("screenshot")
        }
        let session = LanguageModelSession(model: model, instructions: Self.instructions)
        let response = try await session.respond(to: prompt, generating: Reply.self)
        return PilotDecisionSchema.map(response.content)
    }

    /// Tokens reserved for the screenshot, which the model cannot count ahead of time.
    static let imageAllowance = 1_500

    /// Exposed so tests can prove every FoundationModels-backed pilot uses the same schema.
    public static var decisionSchema: GenerationSchema { Reply.generationSchema }

    static func mapDecision(_ reply: Reply) -> Decision {
        PilotDecisionSchema.map(reply)
    }
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
