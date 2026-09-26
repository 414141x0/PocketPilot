#if DEBUG
import AgentCore
import DeviceLink
import OSLog

/// Opens one device session and keeps using it, to learn whether an established session
/// outlives the Wi-Fi association that let it connect. Debug builds only.
///
/// Launch with POCKETPILOT_LINK_PROBE=1 while joined to Wi-Fi, then leave the network mid-run.
enum LinkProbe {
    static func run(pairing: PairingFile, rounds: Int = 40, interval: Duration = .seconds(3)) async {
        let log = Logger(subsystem: "dev.typealias.PocketPilot", category: "LinkProbe")
        let phone: Phone
        do {
            phone = try await Phone.connect(pairing: pairing)
        } catch {
            log.error("connect failed: \(error.description, privacy: .public)")
            return
        }
        log.info("connected")
        for round in 1...rounds {
            let start = ContinuousClock.now
            do {
                let screen = try await phone.observe()
                log.info("#\(round) ok elements=\(screen.elements.count) in \(start.duration(to: .now), privacy: .public)")
            } catch {
                log.error("#\(round) failed: \(error.description, privacy: .public)")
            }
            try? await Task.sleep(for: interval)
        }
    }
}
#endif
