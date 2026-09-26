import Network

enum WiFi {
    /// Whether a Wi-Fi interface is currently usable, settling up to `settle` duration for initial path events.
    static func isUp(settle: Duration = .milliseconds(1500)) async -> Bool {
        let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
        defer { monitor.cancel() }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await path in monitor.paths {
                    if path.status == .satisfied {
                        return true
                    }
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: settle)
                return false
            }
            for await result in group {
                if result {
                    group.cancelAll()
                    return true
                }
            }
            return false
        }
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
