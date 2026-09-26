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

    /// Scans every TCP port on the tunnel address, many at a time; refused ports answer at once.
    /// Launch with POCKETPILOT_PROBE=full.
    static func scanAll(host: String = "10.7.0.1", width: Int = 128) async {
        let log = Logger(subsystem: "dev.typealias.PocketPilot", category: "Probe")
        let start = ContinuousClock.now
        var ports = (UInt16(1)...UInt16.max).makeIterator()
        var open: [UInt16] = []
        var silent = 0
        await withTaskGroup(of: (UInt16, String).self) { group in
            for _ in 0..<width {
                guard let port = ports.next() else { break }
                group.addTask { (port, await connect(host: host, port: port)) }
            }
            for await (port, outcome) in group {
                if outcome == "open" {
                    open.append(port)
                    log.info("port \(port): open")
                } else if outcome == "timed out" {
                    silent += 1
                }
                if let next = ports.next() {
                    group.addTask { (next, await connect(host: host, port: next)) }
                }
            }
        }
        var report = ["full scan of \(host) in \(start.duration(to: .now)): open=\(open.sorted().map(String.init).joined(separator: ",")) timedOut=\(silent)"]
        for port in open.sorted() {
            for greeting in Greeting.allCases {
                report.append("port \(port) \(greeting): \(await fingerprint(host: host, port: port, greeting: greeting))")
            }
        }
        for line in report { log.info("\(line, privacy: .public)") }
        try? report.joined(separator: "\n").write(to: resultURL, atomically: true, encoding: .utf8)
    }

    /// Present in the app's tmp directory to run the full scan on launch without a Mac attached;
    /// the result lands in `resultURL` for `devicectl device copy from` later.
    static let requestURL = URL.temporaryDirectory.appending(path: "probe-full.request")
    static let resultURL = URL.temporaryDirectory.appending(path: "probe-result.txt")

    /// What to send after connecting, to learn which protocol a port speaks.
    enum Greeting: CaseIterable, CustomStringConvertible {
        case silent, remotePairing, http2

        var bytes: Data {
            switch self {
            case .silent:
                return Data()
            case .remotePairing:
                // The same handshake our bridge sends to 49152: "RPPairing", u16 BE length, JSON.
                let json = Data(#"{"message":{"plain":{"_0":{"request":{"_0":{"handshake":{"_0":{"hostOptions":{"attemptPairVerify":true},"wireProtocolVersion":19}}}}}}},"originatedBy":"host","sequenceNumber":0}"#.utf8)
                return Data("RPPairing".utf8) + [UInt8(json.count >> 8), UInt8(json.count & 0xFF)] + json
            case .http2:
                // Client preface plus an empty SETTINGS frame, as RemoteXPC (RSD) expects.
                return Data("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8) + [0, 0, 0, 4, 0, 0, 0, 0, 0]
            }
        }

        var description: String {
            switch self {
            case .silent: "silent"
            case .remotePairing: "rppairing"
            case .http2: "http2"
            }
        }
    }

    /// Connects, sends the greeting, and reports the first bytes that come back within two seconds.
    private static func fingerprint(host: String, port: UInt16, greeting: Greeting) async -> String {
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
                case .ready:
                    if !greeting.bytes.isEmpty {
                        connection.send(content: greeting.bytes, completion: .contentProcessed { _ in })
                    }
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 64) { data, _, isComplete, error in
                        if let data, !data.isEmpty { finish(describe(data)) }
                        else if let error { finish("error \(error)") }
                        else if isComplete { finish("closed with no data") }
                    }
                case .failed(let error), .waiting(let error): finish("connect \(error)")
                default: break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { finish("no reply") }
        }
    }

    private static func describe(_ data: Data) -> String {
        let hex = data.prefix(48).map { String(format: "%02x", $0) }.joined()
        let text = String(decoding: data.prefix(48).map { (32...126).contains($0) ? $0 : 46 }, as: UTF8.self)
        return "\(data.count)B hex=\(hex) ascii=\(text)"
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
