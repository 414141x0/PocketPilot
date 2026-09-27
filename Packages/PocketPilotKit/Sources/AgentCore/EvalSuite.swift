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
    public var apps: [String]
    public var pass: EvalPass

    public init(id: String, goal: String, maxSteps: Int = 20, apps: [String] = [], pass: EvalPass = EvalPass()) {
        self.id = id
        self.goal = goal
        self.maxSteps = maxSteps
        self.apps = apps
        self.pass = pass
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        goal = try container.decode(String.self, forKey: .goal)
        maxSteps = try container.decodeIfPresent(Int.self, forKey: .maxSteps) ?? 20
        apps = try container.decodeIfPresent([String].self, forKey: .apps) ?? []
        pass = try container.decodeIfPresent(EvalPass.self, forKey: .pass)
            ?? container.decodeIfPresent(EvalPass.self, forKey: .expect)
            ?? EvalPass()
    }

    enum CodingKeys: String, CodingKey {
        case id, goal, maxSteps, apps, pass, expect
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(goal, forKey: .goal)
        try container.encode(maxSteps, forKey: .maxSteps)
        try container.encode(apps, forKey: .apps)
        try container.encode(pass, forKey: .pass)
    }

    public var timeout: Duration { .seconds(maxSteps * 30) }

    /// Every app the goal needs must be installed; a cross-app goal missing one is skipped, not failed.
    public func requiredAppsAreInstalled(in installed: [InstalledApp]) -> Bool {
        apps.allSatisfy { name in
            installed.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }
    }
}

public struct EvalPass: Sendable, Codable, Equatable {
    public var summaryContains: [String]
    public var summaryContainsAny: [String]
    public var summaryMatchesRegex: String?
    public var summaryMinLength: Int?
    public var frontmostApp: String?

    public init(
        summaryContains: [String] = [],
        summaryContainsAny: [String] = [],
        summaryMatchesRegex: String? = nil,
        summaryMinLength: Int? = nil,
        frontmostApp: String? = nil
    ) {
        self.summaryContains = summaryContains
        self.summaryContainsAny = summaryContainsAny
        self.summaryMatchesRegex = summaryMatchesRegex
        self.summaryMinLength = summaryMinLength
        self.frontmostApp = frontmostApp
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        summaryContains = try container.decodeIfPresent([String].self, forKey: .summaryContains) ?? []
        summaryContainsAny = try container.decodeIfPresent([String].self, forKey: .summaryContainsAny) ?? []
        summaryMatchesRegex = try container.decodeIfPresent(String.self, forKey: .summaryMatchesRegex)
        summaryMinLength = try container.decodeIfPresent(Int.self, forKey: .summaryMinLength)
        frontmostApp = try container.decodeIfPresent(String.self, forKey: .frontmostApp)
            ?? container.decodeIfPresent(String.self, forKey: .finalApp)
    }

    enum CodingKeys: String, CodingKey {
        case summaryContains, summaryContainsAny, summaryMatchesRegex, summaryMinLength, frontmostApp, finalApp
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(summaryContains, forKey: .summaryContains)
        try container.encode(summaryContainsAny, forKey: .summaryContainsAny)
        try container.encodeIfPresent(summaryMatchesRegex, forKey: .summaryMatchesRegex)
        try container.encodeIfPresent(summaryMinLength, forKey: .summaryMinLength)
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
        if let minLength = pass.summaryMinLength, summary.count < minLength {
            reasons.append("summary shorter than \(minLength)")
        }
        if let pattern = pass.summaryMatchesRegex {
            let range = NSRange(summary.startIndex..., in: summary)
            let regex = try? NSRegularExpression(pattern: pattern)
            if regex?.firstMatch(in: summary, options: [], range: range) == nil {
                reasons.append("regex \(pattern) did not match")
            }
        }
        return EvalJudgement(passed: reasons.isEmpty, reasons: reasons)
    }
}

extension EvalSuite {
    /// `all`/`1` runs every goal; otherwise a comma-separated id list.
    public func filtered(by selection: String) -> [EvalGoal] {
        let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "all" || trimmed == "1" { return goals }
        let ids = Set(trimmed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        return goals.filter { ids.contains($0.id) }
    }
}
