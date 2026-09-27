import Foundation
import Testing
@testable import AgentCore

@Suite struct EvalSuiteTests {
    @Test func decodesPassOrExpectKeys() throws {
        let json = """
        {"goals":[{"id":"w","goal":"Report today's high in Weather. Do not change anything.","maxSteps":12,"expect":{"summaryContains":["high"],"frontmostApp":"Weather"}}]}
        """
        let suite = try JSONDecoder().decode(EvalSuite.self, from: Data(json.utf8))
        #expect(suite.goals[0].pass.summaryContains == ["high"])
        #expect(suite.goals[0].pass.frontmostApp == "Weather")
        #expect(suite.goals[0].maxSteps == 12)
    }

    @Test func passRequiresCompletedSummaryAndFrontmost() {
        let goal = EvalGoal(
            id: "w",
            goal: "g",
            pass: EvalPass(summaryContains: ["72"], summaryContainsAny: ["°", "high"], frontmostApp: "Weather")
        )
        let weather = FrontmostApp(name: "Weather", bundleID: "com.apple.weather")
        #expect(goal.judge(outcome: .completed(summary: "High 72°"), frontmost: weather).passed)
        #expect(!goal.judge(outcome: .completed(summary: "Looks cloudy"), frontmost: weather).passed)
        #expect(!goal.judge(outcome: .completed(summary: "High 72°"), frontmost: FrontmostApp(name: "Clock", bundleID: "com.apple.mobiletimer")).passed)
        #expect(!goal.judge(outcome: .outOfSteps, frontmost: weather).passed)
        #expect(!goal.judge(outcome: .abandoned(reason: "read-only: kept choosing changes"), frontmost: weather).passed)
    }

    @Test func bundledSuiteLoadsFifteenGoals() throws {
        let suite = try EvalSuite.load()
        #expect(suite.goals.count == 15)
        #expect(suite.goals[0].id == "settings-about-version")
        #expect(suite.goals[0].pass.frontmostApp == "Settings")
        #expect(suite.goals[0].pass.summaryMatchesRegex == "\\d+\\.\\d+")
        #expect(suite.filtered(by: "weather-today-high,clock-world-cities").map(\.id) == ["weather-today-high", "clock-world-cities"])
        #expect(suite.filtered(by: "all").count == 15)
    }

    @Test func skipsWhenRequiredAppMissing() {
        let goal = EvalGoal(id: "x", goal: "g", apps: ["Stocks"])
        #expect(!goal.requiredAppsAreInstalled(in: [InstalledApp(name: "Clock", bundleID: "com.apple.mobiletimer")]))
        #expect(goal.requiredAppsAreInstalled(in: [InstalledApp(name: "Stocks", bundleID: "com.apple.stocks")]))
    }

    @Test func regexAndMinLengthPass() {
        let goal = EvalGoal(
            id: "w",
            goal: "g",
            pass: EvalPass(summaryMatchesRegex: "-?\\d+\\s?°", summaryMinLength: 4, frontmostApp: "Weather")
        )
        let weather = FrontmostApp(name: "Weather", bundleID: "com.apple.weather")
        #expect(goal.judge(outcome: .completed(summary: "High 24°"), frontmost: weather).passed)
        #expect(!goal.judge(outcome: .completed(summary: "nice"), frontmost: weather).passed)
    }
}
