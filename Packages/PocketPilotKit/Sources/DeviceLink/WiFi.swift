import Network

public enum WiFi {
    /// Whether a Wi-Fi interface is currently usable, settling up to `settle` duration for initial path events.
    public static func isUp(settle: Duration = .milliseconds(1500)) async -> Bool {
        let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
        let stream = AsyncStream<Bool> { continuation in
            let task = Task {
                for await path in monitor.paths {
                    continuation.yield(path.status == .satisfied)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
                monitor.cancel()
            }
        }
        return await isUp(
            paths: stream,
            settle: settle,
            onFinish: { monitor.cancel() }
        )
    }

    /// Internal implementation supporting dependency injection for testing.
    static func isUp<S: AsyncSequence & Sendable>(
        paths: S,
        settle: Duration = .milliseconds(1500),
        onFinish: (@Sendable () -> Void)? = nil
    ) async -> Bool where S.Element == Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    for try await isSatisfied in paths {
                        if isSatisfied {
                            return true
                        }
                    }
                } catch {
                    return false
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: settle)
                return false
            }
            let up = await group.next() ?? false
            onFinish?()
            group.cancelAll()
            return up
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
