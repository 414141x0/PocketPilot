import Testing
import Foundation
import CoreGraphics
@testable import AgentCore
@testable import SystemPilot

@Suite struct SystemPilotTests {
    @Test func mapsTapElementAction() async throws {
        let payload = SystemDecisionPayload(
            thought: "Tap on settings item",
            kind: "tap",
            elementID: 15
        )

        let decision = try await SystemPilot.mapDecision(payload)
        #expect(decision.thought == "Tap on settings item")
        #expect(decision.action == .tap(.element(15)))
    }

    @Test func mapsTapGridCoordinates() async throws {
        let payload = SystemDecisionPayload(
            thought: "Tap top-right corner",
            kind: "tap",
            gridX: 950,
            gridY: 50
        )

        let decision = try await SystemPilot.mapDecision(payload)
        #expect(decision.thought == "Tap top-right corner")
        #expect(decision.action == .tap(.point(Point(x: 0.95, y: 0.05))))
    }

    @Test func mapsLongPressAction() async throws {
        let payload = SystemDecisionPayload(
            thought: "Hold item to drag",
            kind: "longPress",
            elementID: 7
        )

        let decision = try await SystemPilot.mapDecision(payload)
        #expect(decision.action == .longPress(.element(7)))
    }

    @Test func mapsScrollAction() async throws {
        let payload = SystemDecisionPayload(
            thought: "Scroll list down",
            kind: "scroll",
            elementID: 3,
            scrollDirection: "down"
        )

        let decision = try await SystemPilot.mapDecision(payload)
        #expect(decision.action == .scroll(.down, in: .element(3)))
    }

    @Test func mapsTypeTextAction() async throws {
        let payload = SystemDecisionPayload(
            thought: "Type query",
            kind: "type",
            text: "Hello World"
        )

        let decision = try await SystemPilot.mapDecision(payload)
        #expect(decision.action == .type("Hello World"))
    }

    @Test func mapsPressButtonAction() async throws {
        let payload = SystemDecisionPayload(
            thought: "Lock the phone",
            kind: "press",
            button: "lock"
        )

        let decision = try await SystemPilot.mapDecision(payload)
        #expect(decision.action == .press(.lock))
    }

    @Test func mapsOpenAppAction() async throws {
        let payload = SystemDecisionPayload(
            thought: "Launch Safari",
            kind: "open",
            bundleID: "com.apple.mobilesafari"
        )

        let decision = try await SystemPilot.mapDecision(payload)
        #expect(decision.action == .open(bundleID: "com.apple.mobilesafari"))
    }

    @Test func mapsWaitAction() async throws {
        let payload = SystemDecisionPayload(
            thought: "Wait for page reload",
            kind: "wait",
            waitSeconds: 2.5
        )

        let decision = try await SystemPilot.mapDecision(payload)
        #expect(decision.action == .wait(seconds: 2.5))
    }

    @Test func mapsDoneAndGiveUpActions() async throws {
        let donePayload = SystemDecisionPayload(
            thought: "Task completed successfully",
            kind: "done",
            summaryOrReason: "Message sent"
        )
        let doneDecision = try await SystemPilot.mapDecision(donePayload)
        #expect(doneDecision.action == .done(summary: "Message sent"))
        #expect(doneDecision.action.isTerminal == true)

        let giveUpPayload = SystemDecisionPayload(
            thought: "Cannot proceed",
            kind: "giveUp",
            summaryOrReason: "Network blocked"
        )
        let giveUpDecision = try await SystemPilot.mapDecision(giveUpPayload)
        #expect(giveUpDecision.action == .giveUp(reason: "Network blocked"))
        #expect(giveUpDecision.action.isTerminal == true)
    }

    @Test func throwsOnMissingTapTarget() async {
        let payload = SystemDecisionPayload(
            thought: "Tap nothing",
            kind: "tap"
        )

        await #expect(throws: SystemPilotError.self) {
            try await SystemPilot.mapDecision(payload)
        }
    }

    @Test func throwsOnInvalidScrollDirection() async {
        let payload = SystemDecisionPayload(
            thought: "Bad scroll",
            kind: "scroll",
            scrollDirection: "sideways"
        )

        await #expect(throws: SystemPilotError.self) {
            try await SystemPilot.mapDecision(payload)
        }
    }
}
