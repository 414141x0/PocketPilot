import CoreGraphics
import Foundation
import Testing
@testable import AgentCore
@testable import GeminiPilot

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var req = request
        if req.httpBody == nil, let bodyData = Self.extractBodyData(from: request) {
            req.httpBody = bodyData
        }
        Self.lastRequest = req
        guard let handler = Self.requestHandler else {
            fatalError("MockURLProtocol handler not set")
        }
        do {
            let (response, data) = try handler(req)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    private static func extractBodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read > 0 {
                data.append(buffer, count: read)
            } else {
                break
            }
        }
        return data
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct GeminiPilotTests {
    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeDummyScreen() -> Screen {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(
            data: nil,
            width: 100,
            height: 100,
            bitsPerComponent: 8,
            bytesPerRow: 400,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        let cgImage = context.makeImage()!
        let screenshot = Screenshot(image: cgImage)
        let element = Element(id: 42, role: .button, label: "Submit", frame: Rect(x: 0.1, y: 0.2, width: 0.3, height: 0.1))
        return Screen(screenshot: screenshot, elements: [element])
    }

    private func makeStep(screen: Screen? = nil) -> Step {
        Step(
            goal: "Open Settings",
            screen: screen ?? makeDummyScreen(),
            history: [],
            mentionedApps: ["Settings"]
        )
    }

    private func makeGeminiSuccessResponse(thought: String, actionJSON: String) -> Data {
        let replyJSON = """
        {
          "thought": "\(thought)",
          "action": \(actionJSON)
        }
        """
        let escapedReply = replyJSON
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")

        let geminiResponse = """
        {
          "candidates": [
            {
              "content": {
                "parts": [
                  {
                    "text": "\(escapedReply)"
                  }
                ],
                "role": "model"
              },
              "finishReason": "STOP"
            }
          ]
        }
        """
        return geminiResponse.data(using: .utf8)!
    }

    @Test func requestShapeCarriesKeyInHeaderNotURLImagePartAndSchema() async throws {
        let session = makeSession()
        let apiKey = "test-secret-gemini-key"
        let pilot = GeminiPilot(apiKey: apiKey, model: "gemini-2.5-flash", session: session, retryDelay: .milliseconds(1))

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let data = self.makeGeminiSuccessResponse(thought: "Opening Settings", actionJSON: #"{"kind":"open","app":"Settings"}"#)
            return (response, data)
        }

        let step = makeStep()
        _ = try await pilot.decide(step)

        guard let request = MockURLProtocol.lastRequest else {
            Issue.record("Expected request to be recorded")
            return
        }

        // 1. API key MUST be in header only, NOT in URL
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == apiKey)
        #expect(request.url?.query == nil)
        #expect(!request.url!.absoluteString.contains(apiKey))

        // 2. URL matches expected endpoint
        #expect(request.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent")
        #expect(request.httpMethod == "POST")

        // 3. Inspect body structure
        guard let bodyData = request.httpBody,
              let bodyObj = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
            Issue.record("Expected JSON body")
            return
        }

        // system_instruction present
        let systemInstruction = bodyObj["system_instruction"] as? [String: Any]
        #expect(systemInstruction != nil)

        // contents with user role
        guard let contents = bodyObj["contents"] as? [[String: Any]],
              let firstContent = contents.first,
              let parts = firstContent["parts"] as? [[String: Any]] else {
            Issue.record("Expected contents and parts in body")
            return
        }
        #expect(firstContent["role"] as? String == "user")

        // Contains text part and inline_data image part
        let hasTextPart = parts.contains { ($0["text"] as? String) != nil }
        let hasImagePart = parts.contains { part in
            guard let inline = part["inline_data"] as? [String: Any] else { return false }
            return inline["mime_type"] as? String == "image/jpeg" && (inline["data"] as? String) != nil
        }
        #expect(hasTextPart)
        #expect(hasImagePart)

        // generationConfig with schema
        guard let genConfig = bodyObj["generationConfig"] as? [String: Any] else {
            Issue.record("Expected generationConfig in body")
            return
        }
        #expect(genConfig["responseMimeType"] as? String == "application/json")
        let schema = genConfig["responseJsonSchema"] as? [String: Any]
        #expect(schema != nil)
        #expect(schema?["type"] as? String == "object")
    }

    @Test func decodesAllActionKindsIncludingReplacing() async throws {
        let testCases: [(json: String, expected: Action)] = [
            (#"{"kind":"tap","element_id":42}"#, .tap(.element(42))),
            (#"{"kind":"tap_point","x":250,"y":500}"#, .tap(.point(Point(grid: 250, 500)))),
            (#"{"kind":"long_press","element_id":7}"#, .longPress(.element(7))),
            (#"{"kind":"scroll","direction":"down","element_id":3}"#, .scroll(.down, in: .element(3))),
            (#"{"kind":"scroll","direction":"up","element_id":null}"#, .scroll(.up, in: nil)),
            (#"{"kind":"drag","from_x":100,"from_y":200,"to_x":300,"to_y":400}"#, .drag(from: .point(Point(grid: 100, 200)), to: .point(Point(grid: 300, 400)))),
            (#"{"kind":"type","text":"Hello World","replacing":true}"#, .type("Hello World", replacing: true)),
            (#"{"kind":"type","text":"Quick","replacing":false}"#, .type("Quick", replacing: false)),
            (#"{"kind":"press","button":"home"}"#, .press(.home)),
            (#"{"kind":"press","button":"lock"}"#, .press(.lock)),
            (#"{"kind":"key","key":"return"}"#, .key(.return)),
            (#"{"kind":"open","app":"Clock"}"#, .open(app: "Clock")),
            (#"{"kind":"wait","seconds":2.5}"#, .wait(seconds: 2.5)),
            (#"{"kind":"wait","seconds":3}"#, .wait(seconds: 3.0)),
            (#"{"kind":"done","summary":"Task finished"}"#, .done(summary: "Task finished")),
            (#"{"kind":"give_up","reason":"Cannot find button"}"#, .giveUp(reason: "Cannot find button")),
        ]

        let session = makeSession()
        let pilot = GeminiPilot(apiKey: "key", session: session, retryDelay: .milliseconds(1))
        let step = makeStep()

        for (actionJSON, expectedAction) in testCases {
            MockURLProtocol.requestHandler = { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let data = self.makeGeminiSuccessResponse(thought: "Thinking...", actionJSON: actionJSON)
                return (response, data)
            }

            let decision = try await pilot.decide(step)
            #expect(decision.thought == "Thinking...")
            #expect(decision.action == expectedAction)
        }
    }

    @Test func errorMappingFor400_401_403() async throws {
        let session = makeSession()
        let pilot = GeminiPilot(apiKey: "bad-key", session: session, retryDelay: .milliseconds(1))
        let step = makeStep()

        let errorStatuses = [400, 401, 403]
        for status in errorStatuses {
            MockURLProtocol.requestHandler = { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
                let errorBody = """
                {
                  "error": {
                    "code": \(status),
                    "message": "API key not valid",
                    "status": "PERMISSION_DENIED"
                  }
                }
                """
                return (response, errorBody.data(using: .utf8)!)
            }

            await #expect(throws: GeminiPilotError.self) {
                try await pilot.decide(step)
            }

            do {
                _ = try await pilot.decide(step)
            } catch let error as GeminiPilotError {
                guard case .rejected(let msg) = error else {
                    Issue.record("Expected .rejected, got \(error)")
                    return
                }
                #expect(msg == "API key not valid")
                #expect(error.localizedDescription.contains("Gemini rejected the API key/request: API key not valid"))
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
    }

    @Test func rateLimiting429WithRetryAndBackoff() async throws {
        let session = makeSession()
        let pilot = GeminiPilot(apiKey: "key", session: session, retryDelay: .milliseconds(5))
        let step = makeStep()

        nonisolated(unsafe) var attempts = 0
        MockURLProtocol.requestHandler = { request in
            attempts += 1
            let response = HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!
            let errorBody = #"{"error":{"code":429,"message":"Resource has been exhausted","status":"RESOURCE_EXHAUSTED"}}"#
            return (response, errorBody.data(using: .utf8)!)
        }

        do {
            _ = try await pilot.decide(step)
            Issue.record("Expected error")
        } catch let error as GeminiPilotError {
            guard case .rateLimited(let msg) = error else {
                Issue.record("Expected .rateLimited, got \(error)")
                return
            }
            #expect(msg == "Resource has been exhausted")
            // Retried once: total 2 attempts
            #expect(attempts == 2)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func serverError500RetriesAndRecovers() async throws {
        let session = makeSession()
        let pilot = GeminiPilot(apiKey: "key", session: session, retryDelay: .milliseconds(5))
        let step = makeStep()

        nonisolated(unsafe) var attempts = 0
        MockURLProtocol.requestHandler = { request in
            attempts += 1
            if attempts == 1 {
                let response = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
                return (response, Data())
            } else {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let data = self.makeGeminiSuccessResponse(thought: "Recovered", actionJSON: #"{"kind":"done","summary":"Recovered"}"#)
                return (response, data)
            }
        }

        let decision = try await pilot.decide(step)
        #expect(attempts == 2)
        #expect(decision.thought == "Recovered")
    }

    @Test func malformedJSONReplyThrows() async throws {
        let session = makeSession()
        let pilot = GeminiPilot(apiKey: "key", session: session, retryDelay: .milliseconds(1))
        let step = makeStep()

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let badJSON = """
            {
              "candidates": [
                {
                  "content": {
                    "parts": [
                      {
                        "text": "{ not valid json here ..."
                      }
                    ]
                  }
                }
              ]
            }
            """
            return (response, badJSON.data(using: .utf8)!)
        }

        do {
            _ = try await pilot.decide(step)
            Issue.record("Expected error")
        } catch let error as GeminiPilotError {
            guard case .malformedResponse = error else {
                Issue.record("Expected .malformedResponse, got \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
