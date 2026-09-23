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

    @Test func decodesTapElementAction() async throws {
        let jsonResponse = """
        {
            "id": "resp_123",
            "object": "response",
            "created_at": 1727100000,
            "model": "gpt-5.1",
            "output": [
                {
                    "type": "function_call",
                    "call_id": "call_1",
                    "name": "submit_decision",
                    "arguments": "{\\"thought\\":\\"Found Submit button\\",\\"action\\":{\\"kind\\":\\"tap\\",\\"element_id\\":42}}"
                }
            ],
            "parallel_tool_calls": false,
            "tools": [],
            "metadata": {}
        }
        """

        let session = makeStubbedSession(jsonResponse: jsonResponse)
        let pilot = OpenAIPilot(apiKey: "sk-test", model: "gpt-5.1", session: session)
        let step = Step(goal: "Tap submit", screen: makeDummyScreen())

        let decision = try await pilot.decide(step)
        #expect(decision.thought == "Found Submit button")
        #expect(decision.action == .tap(.element(42)))
    }

    @Test func decodesTapCoordinatesAction() async throws {
        let jsonResponse = """
        {
            "id": "resp_124",
            "object": "response",
            "created_at": 1727100000,
            "model": "gpt-5.1",
            "output": [
                {
                    "type": "function_call",
                    "call_id": "call_2",
                    "name": "submit_decision",
                    "arguments": "{\\"thought\\":\\"Tapping screen center\\",\\"action\\":{\\"kind\\":\\"tap\\",\\"x\\":500,\\"y\\":500}}"
                }
            ],
            "parallel_tool_calls": false,
            "tools": [],
            "metadata": {}
        }
        """

        let session = makeStubbedSession(jsonResponse: jsonResponse)
        let pilot = OpenAIPilot(apiKey: "sk-test", model: "gpt-5.1", session: session)
        let step = Step(goal: "Tap center", screen: makeDummyScreen())

        let decision = try await pilot.decide(step)
        #expect(decision.thought == "Tapping screen center")
        #expect(decision.action == .tap(.point(Point(x: 0.5, y: 0.5))))
    }

    @Test func decodesScrollAndTypeActions() async throws {
        let jsonResponse = """
        {
            "id": "resp_125",
            "object": "response",
            "created_at": 1727100000,
            "model": "gpt-5.1",
            "output": [
                {
                    "type": "function_call",
                    "call_id": "call_3",
                    "name": "submit_decision",
                    "arguments": "{\\"thought\\":\\"Scroll down to view more\\",\\"action\\":{\\"kind\\":\\"scroll\\",\\"direction\\":\\"down\\"}}"
                }
            ],
            "parallel_tool_calls": false,
            "tools": [],
            "metadata": {}
        }
        """

        let session = makeStubbedSession(jsonResponse: jsonResponse)
        let pilot = OpenAIPilot(apiKey: "sk-test", model: "gpt-5.1", session: session)
        let step = Step(goal: "Scroll", screen: makeDummyScreen())

        let decision = try await pilot.decide(step)
        #expect(decision.action == .scroll(.down, in: nil))
    }

    @Test func decodesDoneAction() async throws {
        let jsonResponse = """
        {
            "id": "resp_126",
            "object": "response",
            "created_at": 1727100000,
            "model": "gpt-5.1",
            "output": [
                {
                    "type": "function_call",
                    "call_id": "call_4",
                    "name": "submit_decision",
                    "arguments": "{\\"thought\\":\\"Goal accomplished\\",\\"action\\":{\\"kind\\":\\"done\\",\\"summary\\":\\"Task finished\\"}}"
                }
            ],
            "parallel_tool_calls": false,
            "tools": [],
            "metadata": {}
        }
        """

        let session = makeStubbedSession(jsonResponse: jsonResponse)
        let pilot = OpenAIPilot(apiKey: "sk-test", model: "gpt-5.1", session: session)
        let step = Step(goal: "Finish", screen: makeDummyScreen())

        let decision = try await pilot.decide(step)
        #expect(decision.action == .done(summary: "Task finished"))
        #expect(decision.action.isTerminal == true)
    }

    @Test func throwsWhenToolCallMissing() async {
        let jsonResponse = """
        {
            "id": "resp_127",
            "object": "response",
            "created_at": 1727100000,
            "model": "gpt-5.1",
            "output": [],
            "parallel_tool_calls": false,
            "tools": [],
            "metadata": {}
        }
        """

        let session = makeStubbedSession(jsonResponse: jsonResponse)
        let pilot = OpenAIPilot(apiKey: "sk-test", model: "gpt-5.1", session: session)
        let step = Step(goal: "Finish", screen: makeDummyScreen())

        await #expect(throws: OpenAIPilotError.self) {
            try await pilot.decide(step)
        }
    }
}
