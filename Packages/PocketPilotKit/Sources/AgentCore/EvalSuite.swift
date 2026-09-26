import Foundation

/// Read-only eval goals loaded from `EvalSuite.json` (E1 spec, E2 runner).
public struct EvalSuite: Sendable, Codable, Equatable {
    public var goals: [EvalGoal]

    public init(goals: [EvalGoal]) {
        self.goals = goals
    }

    /// `tmp/eval/suite.json` if present, otherwise the bundled `EvalSuite.json`.
    public static func load() throws -> EvalSuite {
        let override = FileManager.default.temporaryDirectory.appending(path: "eval/suite.json")
        if FileManager.default.isReadableFile(atPath: override.path) {
            return try JSONDecoder().decode(EvalSuite.self, from: Data(contentsOf: override))
        }
        guard let url = Bundle.module.url(forResource: "EvalSuite", withExtension: "json") else {
            throw EvalSuiteError.missing
        }
        return try JSONDecoder().decode(EvalSuite.self, from: Data(contentsOf: url))
    }
}

public enum EvalSuiteError: Error {
    case missing
}

public struct EvalGoal: Sendable, Codable, Equatable {
    public var id: String
    public var goal: String
    public var maxSteps: Int
    public var pass: EvalPass

    public init(id: String, goal: String, maxSteps: Int = 20, pass: EvalPass = EvalPass()) {
        self.id = id
        self.goal = goal
        self.maxSteps = maxSteps
        self.pass = pass
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        goal = try container.decode(String.self, forKey: .goal)
        maxSteps = try container.decodeIfPresent(Int.self, forKey: .maxSteps) ?? 20
        pass = try container.decodeIfPresent(EvalPass.self, forKey: .pass)
            ?? container.decodeIfPresent(EvalPass.self, forKey: .expect)
            ?? EvalPass()
    }

    enum CodingKeys: String, CodingKey {
        case id, goal, maxSteps, pass, expect
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(goal, forKey: .goal)
        try container.encode(maxSteps, forKey: .maxSteps)
        try container.encode(pass, forKey: .pass)
    }
}

public struct EvalPass: Sendable, Codable, Equatable {
    public var summaryContains: [String]
    public var summaryContainsAny: [String]
    public var frontmostApp: String?

    public init(
        summaryContains: [String] = [],
        summaryContainsAny: [String] = [],
        frontmostApp: String? = nil
    ) {
        self.summaryContains = summaryContains
        self.summaryContainsAny = summaryContainsAny
        self.frontmostApp = frontmostApp
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        summaryContains = try container.decodeIfPresent([String].self, forKey: .summaryContains) ?? []
        summaryContainsAny = try container.decodeIfPresent([String].self, forKey: .summaryContainsAny) ?? []
        frontmostApp = try container.decodeIfPresent(String.self, forKey: .frontmostApp)
    }

    enum CodingKeys: String, CodingKey {
        case summaryContains, summaryContainsAny, frontmostApp
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(summaryContains, forKey: .summaryContains)
        try container.encode(summaryContainsAny, forKey: .summaryContainsAny)
        try container.encodeIfPresent(frontmostApp, forKey: .frontmostApp)
    }
}

public struct EvalJudgement: Sendable, Equatable {
    public var passed: Bool
    public var reasons: [String]
}

extension EvalGoal {
    /// Pass is judged on the done-summary text and the final frontmost app.
    public func judge(outcome: Agent.Outcome, frontmost: FrontmostApp?) -> EvalJudgement {
        var reasons: [String] = []
        let summary: String
        switch outcome {
        case .completed(let text):
            summary = text
        case .abandoned(let reason):
            summary = reason
            reasons.append("outcome abandoned")
        case .outOfSteps:
            summary = ""
            reasons.append("out of steps")
        }
        let lower = summary.lowercased()
        for needle in pass.summaryContains where !lower.contains(needle.lowercased()) {
            reasons.append("summary missing \(needle)")
        }
        if !pass.summaryContainsAny.isEmpty,
           !pass.summaryContainsAny.contains(where: { lower.contains($0.lowercased()) }) {
            reasons.append("summary matched none of \(pass.summaryContainsAny.joined(separator: ", "))")
        }
        if let expected = pass.frontmostApp {
            let actual = frontmost?.briefName
            if actual?.caseInsensitiveCompare(expected) != .orderedSame {
                reasons.append("frontmost \(actual ?? "nil") != \(expected)")
            }
        }
        return EvalJudgement(passed: reasons.isEmpty, reasons: reasons)
    }
}
