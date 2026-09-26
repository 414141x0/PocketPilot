public import AgentCore
public import Foundation

/// A pilot that asks Google Gemini, through the Interactions API, to choose device actions.
///
/// Each step is one stateless interaction: the brief and marked screenshot go in, a decision
/// comes back as schema-constrained JSON. `store` is off so screenshots of the user's phone
/// are not kept server-side. References (checked 2026-09-26):
/// https://ai.google.dev/api/interactions-api and https://ai.google.dev/gemini-api/docs/structured-output
public struct GeminiPilot: Pilot {
    /// Defaults to gemini-3.8-flash, Google's current Flash model; 2.5 models are limited to
    /// accounts that already used them (https://ai.google.dev/gemini-api/docs/models).
    public let model: String
    private let apiKey: String
    private let session: URLSession
    /// Delay before retrying on 429 / 5xx. Configurable for unit tests.
    var retryDelay: Duration

    public init(
        apiKey: String,
        model: String = "gemini-3.8-flash",
        session: URLSession = .shared,
        retryDelay: Duration = .seconds(1)
    ) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
        self.retryDelay = retryDelay
    }

    public func decide(_ step: Step) async throws -> Decision {
        var input: [[String: Any]] = [
            ["type": "text", "text": step.brief()]
        ]
        if let jpegData = await step.screen.markedScreenshot().jpeg() {
            input.append([
                "type": "image",
                "mime_type": "image/jpeg",
                "data": jpegData.base64EncodedString()
            ])
        }

        let body: [String: Any] = [
            "model": model,
            "system_instruction": Self.instructions,
            "input": input,
            "response_format": [
                "type": "text",
                "mime_type": "application/json",
                "schema": Self.decisionJsonSchema
            ],
            // Gemini 3 rejects "minimal"; low keeps each step quick. Sampling knobs such as
            // temperature are not accepted on Gemini 3 and later, so none are sent.
            "generation_config": ["thinking_level": "low"],
            "store": false
        ]

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The API key is sent ONLY in the x-goog-api-key header, never in the URL to avoid log leakage.
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await executeWithRetry(request)
        return try Self.parseDecision(from: data)
    }

    private func executeWithRetry(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var attempts = 0
        while true {
            attempts += 1
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                throw GeminiPilotError.network(error.localizedDescription)
            }

            guard let http = response as? HTTPURLResponse else {
                throw GeminiPilotError.invalidResponse
            }

            if (200...299).contains(http.statusCode) {
                return (data, http)
            }

            let errorMessage = parseErrorMessage(from: data) ?? "HTTP \(http.statusCode)"

            if [400, 401, 403].contains(http.statusCode) {
                throw GeminiPilotError.rejected(errorMessage)
            }

            if (http.statusCode == 429 || (500...599).contains(http.statusCode)) && attempts == 1 {
                try? await Task.sleep(for: retryDelay)
                continue
            }

            if http.statusCode == 429 {
                throw GeminiPilotError.rateLimited(errorMessage)
            } else if (500...599).contains(http.statusCode) {
                throw GeminiPilotError.serverError(errorMessage)
            } else {
                throw GeminiPilotError.rejected(errorMessage)
            }
        }
    }

    private func parseErrorMessage(from data: Data) -> String? {
        if let errorResponse = try? JSONDecoder().decode(GeminiErrorResponse.self, from: data),
           let message = errorResponse.error?.message, !message.isEmpty {
            return message
        }
        return String(data: data, encoding: .utf8)?.prefix(200).description
    }

    static let endpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions")!

    static func parseDecision(from data: Data) throws -> Decision {
        let response: Interaction
        do {
            response = try JSONDecoder().decode(Interaction.self, from: data)
        } catch {
            throw GeminiPilotError.malformedResponse("Not an interaction: \(error.localizedDescription)")
        }
        guard response.status == "completed" else {
            throw GeminiPilotError.malformedResponse("Interaction ended with status \(response.status ?? "missing")")
        }
        let text = (response.steps ?? [])
            .filter { $0.type == "model_output" }
            .flatMap { $0.content ?? [] }
            .filter { $0.type == "text" }
            .compactMap(\.text)
            .joined()
        guard !text.isEmpty else {
            throw GeminiPilotError.malformedResponse("No model output text")
        }

        guard let textData = text.data(using: .utf8) else {
            throw GeminiPilotError.malformedResponse("Candidate text is not valid UTF-8")
        }

        do {
            let reply = try JSONDecoder().decode(Reply.self, from: textData)
            return Decision(thought: reply.thought, action: reply.action.toAction())
        } catch {
            throw GeminiPilotError.malformedResponse("Failed to decode decision JSON: \(error.localizedDescription)")
        }
    }

    /// The decision schema, within the subset the Interactions API accepts (anyOf and enum, no const).
    static var decisionJsonSchema: [String: Any] {
        [
            "type": "object",
        "properties": [
            "thought": [
                "type": "string",
                "description": "one short sentence"
            ],
            "action": [
                "anyOf": actionSchemas
            ]
        ],
        "required": ["thought", "action"],
        "additionalProperties": false
        ]
    }

    private static var actionSchemas: [[String: Any]] {
        [
            actionSchema("tap", ["element_id": ["type": "integer"]]),
            actionSchema("tap_point", ["x": ["type": "integer"], "y": ["type": "integer"]]),
            actionSchema("long_press", ["element_id": ["type": "integer"]]),
            actionSchema("scroll", [
                "direction": ["type": "string", "enum": ["up", "down", "left", "right"]],
                "element_id": ["type": "integer"]
            ], optional: ["element_id"]),
            actionSchema("drag", [
                "from_x": ["type": "integer"],
                "from_y": ["type": "integer"],
                "to_x": ["type": "integer"],
                "to_y": ["type": "integer"]
            ]),
            actionSchema("type", [
                "text": ["type": "string"],
                "replacing": ["type": "boolean"]
            ]),
            actionSchema("press", [
                "button": ["type": "string", "enum": ["home", "lock", "volumeUp", "volumeDown"]]
            ]),
            actionSchema("key", [
                "key": ["type": "string", "enum": KeyboardKey.allCases.map(\.rawValue)]
            ]),
            actionSchema("open", [
                "app": ["type": "string", "description": "App name as on the Home Screen"]
            ]),
            actionSchema("wait", ["seconds": ["type": "number"]]),
            actionSchema("done", ["summary": ["type": "string"]]),
            actionSchema("give_up", ["reason": ["type": "string"]])
        ]
    }

    /// One action branch. The kind is a single-value enum because the schema subset has no `const`.
    private static func actionSchema(_ kind: String, _ properties: [String: Any] = [:], optional: Set<String> = []) -> [String: Any] {
        var props = properties
        props["kind"] = ["type": "string", "enum": [kind]]
        return [
            "type": "object",
            "properties": props,
            "required": props.keys.filter { !optional.contains($0) }.sorted(),
            "additionalProperties": false
        ]
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
        case drag(fromX: Int, fromY: Int, toX: Int, toY: Int)
        case type(text: String, replacing: Bool)
        case press(button: HardwareButton)
        case key(KeyboardKey)
        case open(app: String)
        case wait(seconds: Double)
        case done(summary: String)
        case giveUp(reason: String)

        private enum DiscriminatorKeys: String, CodingKey { case kind }
        private enum CodingKeys: String, CodingKey {
            case kind, x, y, direction, text, replacing, button, key, app, seconds, summary, reason
            case elementId = "element_id"
            case fromX = "from_x", fromY = "from_y", toX = "to_x", toY = "to_y"
        }

        init(from decoder: any Decoder) throws {
            let kind = try decoder.container(keyedBy: DiscriminatorKeys.self).decode(String.self, forKey: .kind)
            let c = try decoder.container(keyedBy: CodingKeys.self)
            switch kind {
            case "tap":
                self = .tap(elementId: try c.decode(Int.self, forKey: .elementId))
            case "tap_point":
                self = .tapPoint(x: try c.decode(Int.self, forKey: .x), y: try c.decode(Int.self, forKey: .y))
            case "long_press":
                self = .longPress(elementId: try c.decode(Int.self, forKey: .elementId))
            case "scroll":
                self = .scroll(
                    direction: try c.decode(Direction.self, forKey: .direction),
                    elementId: try c.decodeIfPresent(Int.self, forKey: .elementId)
                )
            case "drag":
                self = .drag(
                    fromX: try c.decode(Int.self, forKey: .fromX),
                    fromY: try c.decode(Int.self, forKey: .fromY),
                    toX: try c.decode(Int.self, forKey: .toX),
                    toY: try c.decode(Int.self, forKey: .toY)
                )
            case "type":
                self = .type(
                    text: try c.decode(String.self, forKey: .text),
                    replacing: try c.decodeIfPresent(Bool.self, forKey: .replacing) ?? false
                )
            case "press":
                self = .press(button: try c.decode(HardwareButton.self, forKey: .button))
            case "key":
                self = .key(try c.decode(KeyboardKey.self, forKey: .key))
            case "open":
                self = .open(app: try c.decode(String.self, forKey: .app))
            case "wait":
                let seconds: Double
                if let d = try? c.decode(Double.self, forKey: .seconds) {
                    seconds = d
                } else {
                    seconds = Double(try c.decode(Int.self, forKey: .seconds))
                }
                self = .wait(seconds: seconds)
            case "done":
                self = .done(summary: try c.decode(String.self, forKey: .summary))
            case "give_up":
                self = .giveUp(reason: try c.decode(String.self, forKey: .reason))
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
            case .drag(let fromX, let fromY, let toX, let toY):
                .drag(from: .point(Point(grid: fromX, fromY)), to: .point(Point(grid: toX, toY)))
            case .type(let text, let replacing): .type(text, replacing: replacing)
            case .press(let btn): .press(btn)
            case .key(let key): .key(key)
            case .open(let app): .open(app: app)
            case .wait(let seconds): .wait(seconds: seconds)
            case .done(let summary): .done(summary: summary)
            case .giveUp(let reason): .giveUp(reason: reason)
            }
        }
    }
}

/// The parts of an Interactions API response a single-turn decision needs.
private struct Interaction: Decodable {
    struct Step: Decodable {
        struct Content: Decodable {
            var type: String?
            var text: String?
        }
        var type: String?
        var content: [Content]?
    }
    var status: String?
    var steps: [Step]?
}

private struct GeminiErrorResponse: Decodable {
    struct ErrorDetail: Decodable {
        var code: Int?
        var message: String?
        var status: String?
    }
    var error: ErrorDetail?
}

public enum GeminiPilotError: LocalizedError, Sendable, Equatable {
    case rejected(String)
    case rateLimited(String)
    case serverError(String)
    case malformedResponse(String)
    case network(String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .rejected(let message):
            "Gemini rejected the API key/request: \(message)"
        case .rateLimited(let message):
            "Gemini rate limit exceeded: \(message)"
        case .serverError(let message):
            "Gemini server error: \(message)"
        case .malformedResponse(let message):
            "Gemini response was malformed: \(message)"
        case .network(let message):
            "Network error communicating with Gemini: \(message)"
        case .invalidResponse:
            "Invalid response received from Gemini"
        }
    }
}
