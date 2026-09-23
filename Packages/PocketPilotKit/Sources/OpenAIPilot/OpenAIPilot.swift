public import AgentCore
public import Foundation
public import OpenAI

/// A pilot that queries OpenAI's Responses API to choose device actions.
public struct OpenAIPilot: Pilot {
    public let model: String
    private let client: any OpenAIProtocol

    public init(apiKey: String, model: String = "gpt-5.1", session: URLSession = .shared) {
        self.model = model
        let configuration = OpenAI.Configuration(token: apiKey)
        self.client = OpenAI(configuration: configuration, session: session)
    }

    init(model: String = "gpt-5.1", client: any OpenAIProtocol) {
        self.model = model
        self.client = client
    }

    public func decide(_ step: Step) async throws -> Decision {
        var contentItems: [InputContent] = []
        if let jpegData = await step.screen.screenshot.jpeg() {
            contentItems.append(.inputImage(InputImage(imageData: jpegData, detail: .high)))
        }
        contentItems.append(.inputText(.init(_type: .inputText, text: step.brief())))

        let message = EasyInputMessage(role: .user, content: .inputItemContentList(contentItems))
        let decisionTool = Self.makeDecisionTool()
        let query = CreateModelResponseQuery(
            input: .inputItemList([.inputMessage(message)]),
            model: model,
            instructions: Self.instructions,
            toolChoice: .ToolChoiceFunction(.init(_type: .function, name: decisionTool.name)),
            tools: [.functionTool(decisionTool)]
        )

        let response = try await client.responses.createResponse(query: query)
        return try Self.parseDecision(from: response)
    }

    static func parseDecision(from response: ResponseObject) throws -> Decision {
        for item in response.output {
            if case .functionToolCall(let call) = item, call.name == "submit_decision" {
                guard let data = call.arguments.data(using: .utf8) else {
                    throw OpenAIPilotError.invalidArguments(call.arguments)
                }
                let decoded = try JSONDecoder().decode(Reply.self, from: data)
                return Decision(thought: decoded.thought, action: decoded.action.toAction())
            }
        }
        throw OpenAIPilotError.missingDecisionToolCall
    }

    static func makeDecisionTool() -> FunctionTool {
        let anyOf: [JSONSchema] = [
            actionSchema("tap", ["element_id": .init(.type(.integer))]),
            actionSchema("tap_point", ["x": .init(.type(.integer)), "y": .init(.type(.integer))]),
            actionSchema("long_press", ["element_id": .init(.type(.integer))]),
            actionSchema("scroll", [
                "direction": .init(.type(.string), .enumValues(["up", "down", "left", "right"])),
                "element_id": .init(.type(.types(["integer", "null"])))
            ]),
            actionSchema("type", ["text": .init(.type(.string))]),
            actionSchema("press", ["button": .init(.type(.string), .enumValues(["home", "lock", "volumeUp", "volumeDown"]))]),
            actionSchema("open", ["bundle_id": .init(.type(.string))]),
            actionSchema("wait", ["seconds": .init(.type(.number))]),
            actionSchema("done", ["summary": .init(.type(.string))]),
            actionSchema("give_up", ["reason": .init(.type(.string))]),
        ]

        let schema = JSONSchema(
            .type(.object),
            .properties([
                "thought": JSONSchema(.type(.string), .description("one short sentence")),
                "action": JSONSchema(.anyOf(anyOf))
            ]),
            .required(["thought", "action"]),
            .additionalProperties(.boolean(false))
        )
        return FunctionTool(name: "submit_decision", description: "Submit agent decision.", parameters: schema, strict: true)
    }

    private static func actionSchema(_ kind: String, _ properties: [String: JSONSchema] = [:]) -> JSONSchema {
        var props = properties
        props["kind"] = .init(.const(kind))
        return .init(.properties(props), .required(Array(props.keys)), .additionalProperties(.boolean(false)))
    }

    private struct Reply: Decodable {
        var thought: String
        var action: ActionChoice
    }

    enum ActionChoice: Decodable {
        case tap(elementId: Int)
        case tapPoint(x: Int, y: Int)
        case longPress(elementId: Int)
        case scroll(direction: Direction, elementId: Int?)
        case type(text: String)
        case press(button: HardwareButton)
        case open(bundleId: String)
        case wait(seconds: Double)
        case done(summary: String)
        case giveUp(reason: String)

        private enum DiscriminatorKeys: String, CodingKey { case kind }
        private enum CodingKeys: String, CodingKey {
            case kind, x, y, direction, text, button, seconds, summary, reason
            case elementId = "element_id"
            case bundleId = "bundle_id"
        }

        init(from decoder: any Decoder) throws {
            let kind = try decoder.container(keyedBy: DiscriminatorKeys.self).decode(String.self, forKey: .kind)
            let c = try decoder.container(keyedBy: CodingKeys.self)
            switch kind {
            case "tap": self = .tap(elementId: try c.decode(Int.self, forKey: .elementId))
            case "tap_point": self = .tapPoint(x: try c.decode(Int.self, forKey: .x), y: try c.decode(Int.self, forKey: .y))
            case "long_press": self = .longPress(elementId: try c.decode(Int.self, forKey: .elementId))
            case "scroll":
                let rawDir = try c.decode(String.self, forKey: .direction)
                guard let dir = Direction(rawValue: rawDir) else {
                    throw DecodingError.dataCorruptedError(forKey: .direction, in: c, debugDescription: "Invalid direction: \(rawDir)")
                }
                self = .scroll(direction: dir, elementId: try c.decodeIfPresent(Int.self, forKey: .elementId))
            case "type": self = .type(text: try c.decode(String.self, forKey: .text))
            case "press":
                let rawBtn = try c.decode(String.self, forKey: .button)
                guard let btn = HardwareButton(rawValue: rawBtn) else {
                    throw DecodingError.dataCorruptedError(forKey: .button, in: c, debugDescription: "Invalid button: \(rawBtn)")
                }
                self = .press(button: btn)
            case "open": self = .open(bundleId: try c.decode(String.self, forKey: .bundleId))
            case "wait": self = .wait(seconds: try c.decode(Double.self, forKey: .seconds))
            case "done": self = .done(summary: try c.decode(String.self, forKey: .summary))
            case "give_up": self = .giveUp(reason: try c.decode(String.self, forKey: .reason))
            default:
                throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "Unknown action kind: \(kind)")
            }
        }

        func toAction() -> Action {
            switch self {
            case .tap(let id): .tap(.element(id))
            case .tapPoint(let x, let y): .tap(.point(Point(grid: x, y)))
            case .longPress(let id): .longPress(.element(id))
            case .scroll(let dir, let id): .scroll(dir, in: id.map { .element($0) })
            case .type(let text): .type(text)
            case .press(let btn): .press(btn)
            case .open(let bundleId): .open(bundleID: bundleId)
            case .wait(let seconds): .wait(seconds: seconds)
            case .done(let summary): .done(summary: summary)
            case .giveUp(let reason): .giveUp(reason: reason)
            }
        }
    }
}

public enum OpenAIPilotError: LocalizedError, Sendable {
    case missingDecisionToolCall
    case invalidArguments(String)

    public var errorDescription: String? {
        switch self {
        case .missingDecisionToolCall: "OpenAI response did not contain the expected submit_decision tool call"
        case .invalidArguments(let args): "Failed to decode decision tool arguments: \(args)"
        }
    }
}
