import Testing
import Foundation
import CoreGraphics
import OpenAI
@testable import AgentCore
@testable import OpenAIPilot

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct OpenAIPilotTests {
    private func makeStubbedSession(jsonResponse: String) -> URLSession {
        StubURLProtocol.requestHandler = { request in
            let url = request.url ?? URL(string: "https://api.openai.com/v1/responses")!
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (response, Data(jsonResponse.utf8))
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeDummyScreen() -> Screen {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 400, space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let cgImage = context.makeImage()!
        let screenshot = Screenshot(image: cgImage)
        let element = Element(id: 42, role: .button, label: "Submit", frame: Rect(x: 0.1, y: 0.2, width: 0.3, height: 0.1))
        return Screen(screenshot: screenshot, elements: [element])
    }

    private func makeResponseJSON(actionJSON: String) -> String {
        """
        {
            "id": "resp_test",
            "object": "response",
            "created_at": 1727100000,
            "tool_choice": "auto",
            "model": "gpt-5.1",
            "output": [
                {
                    "type": "function_call",
                    "call_id": "call_1",
                    "name": "submit_decision",
                    "arguments": "{\\"thought\\":\\"Test thought\\",\\"action\\":\(actionJSON.replacingOccurrences(of: "\"", with: "\\\""))}"
                }
            ],
            "parallel_tool_calls": false,
            "tools": [],
            "metadata": {}
        }
        """
    }

    @Test func verifiesStrictAnyOfSchemaShape() throws {
        let tool = OpenAIPilot.makeDecisionTool()
        #expect(tool.name == "submit_decision")
        #expect(tool.strict == true)

        let data = try JSONEncoder().encode(tool.parameters)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        let required = json["required"] as? [String] ?? []
        #expect(required.contains("thought"))
        #expect(required.contains("action"))
        #expect(json["additionalProperties"] as? Bool == false)

        let properties = json["properties"] as! [String: Any]
        let actionProp = properties["action"] as! [String: Any]
        let anyOf = actionProp["anyOf"] as! [[String: Any]]

        #expect(anyOf.count == 12)
        for sub in anyOf {
            let subReq = sub["required"] as? [String] ?? []
            #expect(subReq.contains("kind"))
            #expect(sub["additionalProperties"] as? Bool == false)
            let subProps = sub["properties"] as! [String: Any]
            // In OpenAI strict mode, every property in properties must be listed in required
            for key in subProps.keys {
                #expect(subReq.contains(key))
            }
        }
    }

    static let decodeCases: [(String, Action)] = [
        ("{\"kind\":\"tap\",\"element_id\":42}", .tap(.element(42))),
        ("{\"kind\":\"tap_point\",\"x\":500,\"y\":250}", .tap(.point(Point(grid: 500, 250)))),
        ("{\"kind\":\"long_press\",\"element_id\":12}", .longPress(.element(12))),
        ("{\"kind\":\"scroll\",\"direction\":\"down\",\"element_id\":3}", .scroll(.down, in: .element(3))),
        ("{\"kind\":\"scroll\",\"direction\":\"up\",\"element_id\":null}", .scroll(.up, in: nil)),
        ("{\"kind\":\"drag\",\"from_x\":200,\"from_y\":800,\"to_x\":200,\"to_y\":300}", .drag(from: .point(Point(grid: 200, 800)), to: .point(Point(grid: 200, 300)))),
        ("{\"kind\":\"type\",\"text\":\"hello\",\"replacing\":false}", .type("hello", replacing: false)),
        ("{\"kind\":\"type\",\"text\":\"hello\",\"replacing\":true}", .type("hello", replacing: true)),
        ("{\"kind\":\"press\",\"button\":\"lock\"}", .press(.lock)),
        ("{\"kind\":\"press\",\"button\":\"home\"}", .press(.home)),
        ("{\"kind\":\"open\",\"app\":\"Settings\"}", .open(app: "Settings")),
        ("{\"kind\":\"key\",\"key\":\"return\"}", .key(.return)),
        ("{\"kind\":\"wait\",\"seconds\":1.5}", .wait(seconds: 1.5)),
        ("{\"kind\":\"done\",\"summary\":\"Finished\"}", .done(summary: "Finished")),
        ("{\"kind\":\"give_up\",\"reason\":\"Stuck\"}", .giveUp(reason: "Stuck"))
    ]

    @Test(arguments: decodeCases)
    func decodesAllActionVariantsExhaustively(_ actionJSON: String, _ expectedAction: Action) async throws {
        let session = makeStubbedSession(jsonResponse: makeResponseJSON(actionJSON: actionJSON))
        let pilot = OpenAIPilot(apiKey: "sk-test", session: session)
        let step = Step(goal: "Goal", screen: makeDummyScreen())
        let decision = try await pilot.decide(step)
        #expect(decision.thought == "Test thought")
        #expect(decision.action == expectedAction)
    }

    @Test func throwsWhenToolCallMissing() async {
        let jsonResponse = """
        {
            "id": "resp_empty",
            "object": "response",
            "created_at": 1727100000,
            "tool_choice": "auto",
            "model": "gpt-5.1",
            "output": [],
            "parallel_tool_calls": false,
            "tools": [],
            "metadata": {}
        }
        """

        let session = makeStubbedSession(jsonResponse: jsonResponse)
        let pilot = OpenAIPilot(apiKey: "sk-test", session: session)
        let step = Step(goal: "Finish", screen: makeDummyScreen())

        await #expect(throws: OpenAIPilotError.self) {
            try await pilot.decide(step)
        }
    }

    @Test func throwsWhenToolArgumentsInvalid() async {
        let jsonResponse = """
        {
            "id": "resp_bad",
            "object": "response",
            "created_at": 1727100000,
            "tool_choice": "auto",
            "model": "gpt-5.1",
            "output": [
                {
                    "type": "function_call",
                    "call_id": "call_bad",
                    "name": "submit_decision",
                    "arguments": "not-valid-json"
                }
            ],
            "parallel_tool_calls": false,
            "tools": [],
            "metadata": {}
        }
        """

        let session = makeStubbedSession(jsonResponse: jsonResponse)
        let pilot = OpenAIPilot(apiKey: "sk-test", session: session)
        let step = Step(goal: "Finish", screen: makeDummyScreen())

        await #expect(throws: DecodingError.self) {
            try await pilot.decide(step)
        }
    }
}
