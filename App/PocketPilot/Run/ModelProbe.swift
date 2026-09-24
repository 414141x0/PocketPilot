#if DEBUG
import AgentCore
import DeviceLink
import OSLog
import SystemPilot

/// Captures one real screen and reports how the on-device model handles it. Debug builds only.
enum ModelProbe {
    static func run(pairing: PairingFile) async {
        let log = Logger(subsystem: "dev.typealias.PocketPilot", category: "ModelProbe")
        do {
            let screen = try await Phone.connect(pairing: pairing).observe()
            log.info("screenshot \(screen.screenshot.width)x\(screen.screenshot.height), \(screen.elements.count) elements")
            for line in await SystemPilot.diagnose(screen: screen) {
                log.info("\(line, privacy: .public)")
            }
        } catch {
            log.error("probe failed: \(error.description, privacy: .public)")
        }
    }
}
#endif
