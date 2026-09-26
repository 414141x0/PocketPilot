import Testing
@testable import AgentCore
@testable import PilotSchema

@Suite struct PilotSchemaTests {
    @Test func mapsEveryChoice() {
        let cases: [(Choice, Action)] = [
            (.tap(element: 15), .tap(.element(15))),
            (.tapPoint(x: 950, y: 50), .tap(.point(Point(grid: 950, 50)))),
            (.longPress(element: 7), .longPress(.element(7))),
            (.scroll(direction: .down, element: 3), .scroll(.down, in: .element(3))),
            (.scroll(direction: .up, element: nil), .scroll(.up, in: nil)),
            (
                .drag(fromX: 200, fromY: 500, toX: 800, toY: 500),
                .drag(from: .point(Point(grid: 200, 500)), to: .point(Point(grid: 800, 500)))
            ),
            (.type(text: "Hello World", replacing: false), .type("Hello World", replacing: false)),
            (.type(text: "Replace me", replacing: true), .type("Replace me", replacing: true)),
            (.press(button: .home), .press(.home)),
            (.press(button: .lock), .press(.lock)),
            (.press(button: .volumeUp), .press(.volumeUp)),
            (.press(button: .volumeDown), .press(.volumeDown)),
            (.key(name: .return), .key(.return)),
            (.key(name: .tab), .key(.tab)),
            (.key(name: .escape), .key(.escape)),
            (.key(name: .delete), .key(.delete)),
            (.open(app: "Safari"), .open(app: "Safari")),
            (.wait(seconds: 2.5), .wait(seconds: 2.5)),
            (.done(summary: "Success"), .done(summary: "Success")),
            (.giveUp(reason: "Blocked"), .giveUp(reason: "Blocked")),
        ]

        for (choice, action) in cases {
            let decision = PilotDecisionSchema.map(Reply(thought: "Why", action: choice))
            #expect(decision == Decision(thought: "Why", action: action))
        }
    }
}
