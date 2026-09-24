#if os(iOS)
import RunActivity
import Testing

@Suite struct RunActivityTests {
    @Test func contentStateRoundTripsThroughJSON() throws {
        let state = RunAttributes.ContentState(step: 3, action: "tap [2]", thought: "Next: tap Submit")
        let decoded = try JSONDecoder().decode(RunAttributes.ContentState.self, from: JSONEncoder().encode(state))
        #expect(decoded == state)
    }

    @Test func attributesRoundTripThroughJSON() throws {
        let attributes = RunAttributes(goal: "File the expense report")
        let decoded = try JSONDecoder().decode(RunAttributes.self, from: JSONEncoder().encode(attributes))
        #expect(decoded.goal == attributes.goal)
    }
}
#endif
