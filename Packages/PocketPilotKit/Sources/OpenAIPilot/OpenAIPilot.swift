public import AgentCore
public import Foundation
import CoreGraphics
public import OpenAI

/// A pilot that queries OpenAI's Responses API to choose device actions.
public struct OpenAIPilot: Pilot {
    public let apiKey: String
    public let model: String
    private let client: any OpenAIProtocol

    public init(apiKey: String, model: String = "gpt-5.1", session: URLSession = .shared) {
        self.apiKey = apiKey
        self.model = model
        let configuration = OpenAI.Configuration(token: apiKey)
        self.client = OpenAI(configuration: configuration, session: session)
    }

    /// Internal initializer for dependency injection and testing.
    init(apiKey: String, model: String = "gpt-5.1", client: any OpenAIProtocol) {
        self.apiKey = apiKey
        self.model = model
        self.client = client
    }

    public func decide(_ step: Step) async throws -> Decision {
        let systemInstructions = """
        You are an autonomous iOS agent operating an iPhone on-device.
        Your goal is to achieve the user's objective by observing the screen and returning exactly one action.
        You have accessibility tree outlines with integer grid coordinates (0...1000) and screenshots.
        Always explain your thinking in `thought`, then select the most appropriate action.
        """

        let userPrompt = """
        Goal: \(step.goal)

        History:
        \(step.historyOutline.isEmpty ? "(first step)" : step.historyOutline)

        Screen Elements:
        \(step.screen.outline())
        """

        var contentItems: [InputContent] = []

        if let jpegData = await step.screen.screenshot.jpeg() {
            let inputImage = InputImage(imageData: jpegData, detail: .high)
            contentItems.append(.inputImage(inputImage))
        }

        let textContent = Components.Schemas.InputTextContent(_type: .inputText, text: userPrompt)
        contentItems.append(.inputText(textContent))

        let message = EasyInputMessage(role: .user, content: .inputItemContentList(contentItems))
        let inputItem = InputItem.inputMessage(message)

        let decisionTool = Self.makeDecisionTool()
        let query = CreateModelResponseQuery(
            input: .inputItemList([inputItem]),
            model: model,
            instructions: systemInstructions,
            toolChoice: .ToolChoiceFunction(.init(_type: .function, name: decisionTool.name)),
            tools: [.functionTool(decisionTool)]
        )

        let response = try await client.responses.createResponse(query: query)
        return try await Self.parseDecision(from: response)
    }

    @concurrent
    private static func parseDecision(from response: ResponseObject) async throws -> Decision {
        for item in response.output {
            if case .functionToolCall(let call) = item, call.name == "submit_decision" {
                guard let data = call.arguments.data(using: .utf8) else {
                    throw OpenAIPilotError.invalidArguments(call.arguments)
                }
                let decoded = try JSONDecoder().decode(Payload.self, from: data)
                return try decoded.toDecision()
            }
        }
        throw OpenAIPilotError.missingDecisionToolCall
    }

    private static func makeDecisionTool() -> FunctionTool {
        let schema = JSONSchema(
            .type(.object),
            .properties([
                "thought": JSONSchema(.type(.string), .description("Reasoning explaining why this action was chosen")),
                "action": JSONSchema(
                    .type(.object),
                    .properties([
                        "kind": JSONSchema(
                            .type(.string),
                            .enumValues(["tap", "longPress", "scroll", "type", "press", "open", "wait", "done", "giveUp"]),
                            .description("The action kind to perform")
                        ),
                        "element_id": JSONSchema(.type(.integer), .description("Target accessibility element ID from outline")),
                        "x": JSONSchema(.type(.integer), .description("X coordinate on 1000x1000 grid")),
                        "y": JSONSchema(.type(.integer), .description("Y coordinate on 1000x1000 grid")),
                        "direction": JSONSchema(
                            .type(.string),
                            .enumValues(["up", "down", "left", "right"]),
                            .description("Scroll direction")
                        ),
                        "text": JSONSchema(.type(.string), .description("Text string to type")),
                        "button": JSONSchema(
                            .type(.string),
                            .enumValues(["home", "lock", "volumeUp", "volumeDown"]),
                            .description("Hardware button")
                        ),
                        "bundle_id": JSONSchema(.type(.string), .description("App bundle identifier to launch")),
                        "seconds": JSONSchema(.type(.number), .description("Seconds to wait")),
                        "summary": JSONSchema(.type(.string), .description("Success summary for done action")),
                        "reason": JSONSchema(.type(.string), .description("Failure reason for giveUp action"))
                    ]),
                    .required(["kind"]),
                    .additionalProperties(.boolean(false))
                )
            ]),
            .required(["thought", "action"]),
            .additionalProperties(.boolean(false))
        )

        return FunctionTool(
            name: "submit_decision",
            description: "Submit the decided agent action and rationale.",
            parameters: schema,
            strict: true
        )
    }

    private struct Payload: Decodable {
        var thought: String
        var action: ActionPayload

        func toDecision() throws -> Decision {
            Decision(thought: thought, action: try action.toAction())
        }
    }

    private struct ActionPayload: Decodable {
        var kind: String
        var element_id: Int?
        var x: Int?
        var y: Int?
        var direction: String?
        var text: String?
        var button: String?
        var bundle_id: String?
        var seconds: Double?
        var summary: String?
        var reason: String?

        func toAction() throws -> Action {
            switch kind {
            case "tap":
                if let element_id {
                    return .tap(.element(element_id))
                } else if let x, let y {
                    return .tap(.point(Point(grid: x, y)))
                }
                throw OpenAIPilotError.missingTarget("tap requires element_id or (x, y)")

            case "longPress":
                if let element_id {
                    return .longPress(.element(element_id))
                } else if let x, let y {
                    return .longPress(.point(Point(grid: x, y)))
                }
                throw OpenAIPilotError.missingTarget("longPress requires element_id or (x, y)")

            case "scroll":
                guard let rawDir = direction, let dir = Direction(rawValue: rawDir) else {
                    throw OpenAIPilotError.invalidArgument("scroll requires direction up/down/left/right")
                }
                let target = element_id.map { Target.element($0) }
                return .scroll(dir, in: target)

            case "type":
                return .type(text ?? "")

            case "press":
                guard let rawBtn = button, let btn = HardwareButton(rawValue: rawBtn) else {
                    throw OpenAIPilotError.invalidArgument("press requires valid hardware button")
                }
                return .press(btn)

            case "open":
                guard let bundle_id, !bundle_id.isEmpty else {
                    throw OpenAIPilotError.invalidArgument("open requires bundle_id")
                }
                return .open(bundleID: bundle_id)

            case "wait":
                return .wait(seconds: seconds ?? 1.0)

            case "done":
                return .done(summary: summary ?? "")

            case "giveUp":
                return .giveUp(reason: reason ?? "")

            default:
                throw OpenAIPilotError.invalidArgument("Unknown action kind: \(kind)")
            }
        }
    }
}

public enum OpenAIPilotError: LocalizedError, Sendable {
    case missingDecisionToolCall
    case invalidArguments(String)
    case missingTarget(String)
    case invalidArgument(String)

    public var errorDescription: String? {
        switch self {
        case .missingDecisionToolCall:
            "OpenAI response did not contain the expected submit_decision tool call"
        case .invalidArguments(let args):
            "Failed to decode decision tool arguments: \(args)"
        case .missingTarget(let reason):
            "Missing action target: \(reason)"
        case .invalidArgument(let reason):
            "Invalid action argument: \(reason)"
        }
    }
}
