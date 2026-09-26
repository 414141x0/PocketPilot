#if DEBUG
import AgentCore
import DeviceLink
import Foundation
import OSLog

/// Runs the E1 eval suite from Home under read-only policy.
/// Debug builds only. Launch with `POCKETPILOT_EVAL=1`.
enum EvalProbe {
    static func run(pairing: PairingFile, pilot: any Pilot) async {
        let log = Logger(subsystem: "dev.typealias.PocketPilot", category: "Eval")
        do {
            let suite = try EvalSuite.load()
            guard !suite.goals.isEmpty else {
                log.error("EvalSuite.json has no goals yet (waiting on E1)")
                return
            }
            let phone = try await Phone.connect(pairing: pairing)
            var results: [Result] = []
            for (index, goal) in suite.goals.enumerated() {
                if index > 0 {
                    try await phone.perform(.press(.home))
                    try await Task.sleep(for: .milliseconds(700))
                }
                StepRecorder.reset()
                var steps = 0
                let started = ContinuousClock.now
                let outcome = try await Agent(
                    device: phone,
                    pilot: pilot,
                    policy: .readOnly,
                    maxSteps: goal.maxSteps,
                    preparation: [.press(.home), .press(.home)],
                    startsAt: "Home Screen"
                ).run(goal.goal) { event in
                    if case .observed(let step) = event {
                        steps += 1
                        Task { await StepRecorder.record(step) }
                    }
                }
                let seconds = started.duration(to: .now)
                let frontmost = try? await phone.frontmostApp()
                let judgement = goal.judge(outcome: outcome, frontmost: frontmost)
                let summary: String
                switch outcome {
                case .completed(let text): summary = text
                case .abandoned(let reason): summary = reason
                case .outOfSteps: summary = "out of steps"
                }
                let secondsValue = Double(seconds.components.seconds) + Double(seconds.components.attoseconds) / 1e18
                results.append(Result(
                    id: goal.id,
                    passed: judgement.passed,
                    outcome: outcome.displayLine,
                    summary: summary,
                    steps: steps,
                    seconds: secondsValue,
                    frontmost: frontmost?.briefName,
                    reasons: judgement.reasons
                ))
                let mark = judgement.passed ? "PASS" : "FAIL"
                log.notice("\(mark, privacy: .public) \(goal.id, privacy: .public) \(steps, privacy: .public) steps \(secondsValue, privacy: .public)s \(frontmost?.briefName ?? "nil", privacy: .public) — \(summary, privacy: .public)")
            }
            try write(results)
            let passed = results.filter(\.passed).count
            log.notice("eval \(passed, privacy: .public)/\(results.count, privacy: .public) passed")
        } catch {
            log.error("eval failed: \(String(describing: error), privacy: .public)")
        }
    }

    private struct Result: Encodable {
        var id: String
        var passed: Bool
        var outcome: String
        var summary: String
        var steps: Int
        var seconds: Double
        var frontmost: String?
        var reasons: [String]
    }

    private static func write(_ results: [Result]) throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "eval")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let name = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = directory.appending(path: "\(name).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(results).write(to: url)
        Logger(subsystem: "dev.typealias.PocketPilot", category: "Eval").notice("wrote \(url.path, privacy: .public)")
    }
}
#endif
