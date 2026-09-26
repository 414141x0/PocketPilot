#if DEBUG
import AgentCore
import DeviceLink
import OSLog

/// Asks the configured pilot for one decision on the current screen without performing it,
/// so a model or API key can be checked end to end with nothing on the phone changing.
/// Debug builds only.
///
/// Launch with POCKETPILOT_PILOT_PROBE set to the goal to decide for.
enum PilotProbe {
    static func run(goal: String, pairing: PairingFile, pilot: any Pilot) async {
        let log = Logger(subsystem: "dev.typealias.PocketPilot", category: "PilotProbe")
        do {
            let phone = try await Phone.connect(pairing: pairing)
            let screen = try await phone.observe()
            let app = try? await phone.frontmostApp()
            let start = ContinuousClock.now
            let decision = try await pilot.decide(Step(goal: goal, screen: screen, app: app))
            log.info("\(String(describing: type(of: pilot)), privacy: .public) decided in \(start.duration(to: .now), privacy: .public): \(decision.thought, privacy: .public) → \(decision.action.description, privacy: .public) (not performed)")
        } catch {
            log.error("probe failed: \(String(describing: error), privacy: .public)")
        }
    }
}
#endif
