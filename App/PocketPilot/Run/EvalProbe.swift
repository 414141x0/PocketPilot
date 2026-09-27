#if DEBUG
import AgentCore
import DeviceLink
import Foundation
import OSLog
import Synchronization

/// Runs the E1 eval suite from Home under read-only policy.
/// Debug builds only. Launch with `POCKETPILOT_EVAL=all` or `POCKETPILOT_EVAL=<id>,<id>`.
enum EvalProbe {
    private struct TimeoutError: Error {}

    static func run(pairing: PairingFile, pilot: any Pilot) async {
        let log = Logger(subsystem: "dev.typealias.PocketPilot", category: "Eval")
        let selection = ProcessInfo.processInfo.environment["POCKETPILOT_EVAL"] ?? "all"
        do {
            let suite = try EvalSuite.load()
            let goals = suite.filtered(by: selection)
            guard !goals.isEmpty else {
                log.error("no eval goals selected (POCKETPILOT_EVAL=\(selection, privacy: .public))")
                return
            }
            var phone = try await Phone.connect(pairing: pairing)
            let installed = (try? await phone.installedApps()) ?? []
            let pilotName = String(describing: type(of: pilot))
            let reportURL = try reportURL()
            // Written after every goal, so a lost session mid-suite keeps what already ran.
            var results: [Result] = [] {
                didSet { try? write(results, pilot: pilotName, to: reportURL) }
            }
            for (index, goal) in goals.enumerated() {
                if index > 0 {
                    try? await phone.perform(.press(.home))
                    try? await Task.sleep(for: .milliseconds(700))
                }
                if !goal.requiredAppsAreInstalled(in: installed) {
                    results.append(Result(id: goal.id, passed: false, skipped: true, outcome: "skipped: not installed", summary: "skipped: not installed", steps: 0, seconds: 0, frontmost: nil, reasons: ["skipped: not installed"]))
                    log.notice("SKIP \(goal.id, privacy: .public) skipped: not installed")
                    continue
                }
                StepRecorder.reset()
                // Counted from the agent's event handler, which runs off this task.
                let observed = Mutex(0)
                var steps: Int { observed.withLock { $0 } }
                let started = ContinuousClock.now
                let outcome: Agent.Outcome
                let device = phone
                do {
                    outcome = try await withTimeout(goal.timeout) {
                        try await Agent(
                            device: device,
                            pilot: pilot,
                            policy: .readOnly,
                            maxSteps: goal.maxSteps,
                            preparation: [.press(.home), .press(.home)],
                            startsAt: "Home Screen"
                        ).run(goal.goal) { event in
                            if case .observed(let step) = event {
                                observed.withLock { $0 += 1 }
                                Task { await StepRecorder.record(step) }
                            }
                        }
                    }
                } catch is TimeoutError {
                    let secondsValue = elapsedSeconds(since: started)
                    results.append(Result(id: goal.id, passed: false, skipped: false, outcome: "timeout", summary: "timeout", steps: steps, seconds: secondsValue, frontmost: nil, reasons: ["timeout"]))
                    log.notice("FAIL \(goal.id, privacy: .public) timeout after \(secondsValue, privacy: .public)s")
                    continue
                } catch {
                    // A lost session fails this goal only; reconnect and carry on with the rest.
                    let secondsValue = elapsedSeconds(since: started)
                    let reason = "error: \(error)"
                    results.append(Result(id: goal.id, passed: false, skipped: false, outcome: reason, summary: reason, steps: steps, seconds: secondsValue, frontmost: nil, reasons: [reason]))
                    log.notice("FAIL \(goal.id, privacy: .public) \(reason, privacy: .public)")
                    if let fresh = try? await Phone.connect(pairing: pairing) { phone = fresh }
                    continue
                }
                let secondsValue = elapsedSeconds(since: started)
                let frontmost = (try? await phone.frontmostApp())?.resolved(using: installed)
                let judgement = goal.judge(outcome: outcome, frontmost: frontmost)
                let summary: String
                switch outcome {
                case .completed(let text): summary = text
                case .abandoned(let reason): summary = reason
                case .outOfSteps: summary = "out of steps"
                }
                results.append(Result(
                    id: goal.id,
                    passed: judgement.passed,
                    skipped: false,
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
            log.notice("wrote \(reportURL.path, privacy: .public)")
            log.notice("\(summaryLine(pilot: pilotName, results: results), privacy: .public)")
        } catch {
            log.error("eval failed: \(String(describing: error), privacy: .public)")
        }
    }

    static func summaryLine(pilot: String, results: [Result]) -> String {
        let skipped = results.filter(\.skipped).count
        let judged = results.filter { !$0.skipped }
        let passed = judged.filter(\.passed).count
        let steps = judged.map { Double($0.steps) }
        let rates = judged.map { $0.steps == 0 ? $0.seconds : $0.seconds / Double($0.steps) }
        return "EVAL \(pilot) pass \(passed)/\(judged.count) (skipped \(skipped)), median steps \(median(steps).formatted(.number.precision(.fractionLength(0)))), median s/step \(median(rates).formatted(.number.precision(.fractionLength(1))))"
    }

    struct Result: Encodable, Sendable {
        var id: String
        var passed: Bool
        var skipped: Bool
        var outcome: String
        var summary: String
        var steps: Int
        var seconds: Double
        var frontmost: String?
        var reasons: [String]
    }

    private static func elapsedSeconds(since started: ContinuousClock.Instant) -> Double {
        let duration = started.duration(to: .now)
        return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private static func withTimeout<T: Sendable>(_ limit: Duration, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: limit)
                throw TimeoutError()
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }

    /// tmp/eval/<timestamp>.json for this suite run.
    private static func reportURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "eval")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let name = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return directory.appending(path: "\(name).json")
    }

    private static func write(_ results: [Result], pilot: String, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(Report(pilot: pilot, results: results)).write(to: url, options: .atomic)
    }

    private struct Report: Encodable {
        var pilot: String
        var results: [Result]
    }
}
#endif
