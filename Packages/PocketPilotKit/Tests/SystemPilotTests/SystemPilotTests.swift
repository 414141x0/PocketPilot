import Testing
import Foundation
@testable import AgentCore
@testable import PilotSchema
@testable import SystemPilot

@Suite struct SystemPilotTests {
    @Test func mapsTapElementAction() {
        let reply = Reply(thought: "Tap settings", action: .tap(element: 15))
        let decision = SystemPilot.mapDecision(reply)
        #expect(decision.thought == "Tap settings")
        #expect(decision.action == .tap(.element(15)))
    }

    @Test func mapsTapGridCoordinates() {
        let reply = Reply(thought: "Tap corner", action: .tapPoint(x: 950, y: 50))
        let decision = SystemPilot.mapDecision(reply)
        #expect(decision.action == .tap(.point(Point(grid: 950, 50))))
    }

    @Test func mapsLongPressAction() {
        let reply = Reply(thought: "Hold item", action: .longPress(element: 7))
        let decision = SystemPilot.mapDecision(reply)
        #expect(decision.action == .longPress(.element(7)))
    }

    @Test func mapsScrollActionWithAndWithoutTarget() {
        let replyWithTarget = Reply(thought: "Scroll list", action: .scroll(direction: .down, element: 3))
        let decision1 = SystemPilot.mapDecision(replyWithTarget)
        #expect(decision1.action == .scroll(.down, in: .element(3)))

        let replyNoTarget = Reply(thought: "Scroll page", action: .scroll(direction: .up, element: nil))
        let decision2 = SystemPilot.mapDecision(replyNoTarget)
        #expect(decision2.action == .scroll(.up, in: nil))
    }

    @Test func mapsDragAction() {
        let reply = Reply(thought: "Drag slider", action: .drag(fromX: 200, fromY: 500, toX: 800, toY: 500))
        let decision = SystemPilot.mapDecision(reply)
        #expect(decision.action == .drag(from: .point(Point(grid: 200, 500)), to: .point(Point(grid: 800, 500))))
    }

    @Test func mapsTypeTextAction() {
        let reply = Reply(thought: "Enter text", action: .type(text: "Hello World"))
        let decision = SystemPilot.mapDecision(reply)
        #expect(decision.action == .type("Hello World"))
    }

    @Test func mapsPressButtonActions() {
        let replyLock = Reply(thought: "Lock phone", action: .press(button: .lock))
        #expect(SystemPilot.mapDecision(replyLock).action == .press(.lock))

        let replyHome = Reply(thought: "Go home", action: .press(button: .home))
        #expect(SystemPilot.mapDecision(replyHome).action == .press(.home))

        let replyVolUp = Reply(thought: "Volume up", action: .press(button: .volumeUp))
        #expect(SystemPilot.mapDecision(replyVolUp).action == .press(.volumeUp))

        let replyVolDown = Reply(thought: "Volume down", action: .press(button: .volumeDown))
        #expect(SystemPilot.mapDecision(replyVolDown).action == .press(.volumeDown))
    }

    @Test func mapsOpenAppAction() {
        let reply = Reply(thought: "Open Safari", action: .open(app: "Safari"))
        let decision = SystemPilot.mapDecision(reply)
        #expect(decision.action == .open(app: "Safari"))
    }

    @Test func mapsWaitAction() {
        let reply = Reply(thought: "Wait briefly", action: .wait(seconds: 2.5))
        let decision = SystemPilot.mapDecision(reply)
        #expect(decision.action == .wait(seconds: 2.5))
    }

    @Test func mapsDoneAndGiveUpActions() {
        let replyDone = Reply(thought: "Finished", action: .done(summary: "Success"))
        let decisionDone = SystemPilot.mapDecision(replyDone)
        #expect(decisionDone.action == .done(summary: "Success"))
        #expect(decisionDone.action.isTerminal == true)

        let replyGiveUp = Reply(thought: "Cannot finish", action: .giveUp(reason: "Blocked"))
        let decisionGiveUp = SystemPilot.mapDecision(replyGiveUp)
        #expect(decisionGiveUp.action == .giveUp(reason: "Blocked"))
        #expect(decisionGiveUp.action.isTerminal == true)
    }
}
