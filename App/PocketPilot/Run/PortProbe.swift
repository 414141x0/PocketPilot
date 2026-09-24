#if DEBUG
import BackgroundTasks
import Network
import Foundation
import OSLog

/// Reports which TCP ports on the tunnel address accept connections, for diagnosing
/// how this iOS version exposes its developer services. Debug builds only.
nonisolated enum PortProbe {
    static let ports: [UInt16] = [62078] + Array(49152...49200)

    static func run(host: String = "10.7.0.1") async {
        let log = Logger(subsystem: "dev.typealias.PocketPilot", category: "Probe")
        let resources = BGTaskScheduler.supportedResources
        log.info("continued-processing resources: gpu=\(resources.contains(.gpu)) raw=\(resources.rawValue)")
        for address in ["127.0.0.1", "10.7.1.1", host] {
            let outcome = await connect(host: address, port: 62078)
            log.info("\(address, privacy: .public):62078 → \(outcome, privacy: .public)")
        }
        var open: [UInt16] = []
        for port in ports {
            let outcome = await connect(host: host, port: port)
            if port == 62078 || outcome == "open" { log.info("port \(port): \(outcome, privacy: .public)") }
            if outcome == "open" { open.append(port) }
        }
        log.info("open ports on \(host, privacy: .public): \(open.map(String.init).joined(separator: ","), privacy: .public)")
    }

    private static func connect(host: String, port: UInt16) async -> String {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            let once = OnceFlag()
            let finish: @Sendable (String) -> Void = { outcome in
                guard once.claim() else { return }
                connection.cancel()
                continuation.resume(returning: outcome)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish("open")
                case .failed(let error), .waiting(let error): finish("\(error)")
                default: break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { finish("timed out") }
        }
    }
}

nonisolated private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    /// True exactly once; guarded by `lock`.
    func claim() -> Bool {
        lock.withLock {
            defer { claimed = true }
            return !claimed
        }
    }
}
#endif
