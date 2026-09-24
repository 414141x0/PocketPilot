import Network

enum WiFi {
    /// Whether a Wi-Fi interface is currently usable.
    static func isUp() async -> Bool {
        let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
        defer { monitor.cancel() }
        for await path in monitor.paths {
            return path.status == .satisfied
        }
        return false
    }
}

private extension NWPathMonitor {
    var paths: AsyncStream<NWPath> {
        AsyncStream { continuation in
            pathUpdateHandler = { continuation.yield($0) }
            continuation.onTermination = { [weak self] _ in self?.cancel() }
            start(queue: .global(qos: .userInitiated))
        }
    }
}
