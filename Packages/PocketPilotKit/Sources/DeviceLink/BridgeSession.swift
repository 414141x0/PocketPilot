import AgentCore
import Foundation
import OSLog
import PilotBridge

let log = Logger(subsystem: "dev.typealias.PocketPilot", category: "DeviceLink")

/// A CoreDevice session with this iPhone, reached through LocalDevVPN's loopback tunnel.
///
/// Every operation is queued on the bridge's worker thread and completes exactly once,
/// so each call suspends on a continuation that the C callback resumes.
final class BridgeSession: Sendable {
    /// Owned exclusively by this object; the bridge serializes all work on it internally.
    nonisolated(unsafe) private let handle: OpaquePointer

    /// The address LocalDevVPN reflects back to this device.
    static let tunnelAddress = "10.7.0.1"

    private init(handle: OpaquePointer) {
        self.handle = handle
    }

    deinit {
        pp_session_close(handle)
    }

    static func open(_ pairing: PairingFile, host: String = tunnelAddress) async throws(DeviceError) -> BridgeSession {
        var session: BridgeSession?
        try await complete { callback, context in
            let handle = pairing.data.withUnsafeBytes { bytes in
                pp_session_open(bytes.baseAddress?.assumingMemoryBound(to: UInt8.self), bytes.count, host, callback, context)
            }
            session = handle.map(BridgeSession.init)
        }
        guard let session else { throw .service("The bridge could not allocate a session.") }
        return session
    }

    func tap(_ point: Point) async throws(DeviceError) {
        try await complete { pp_tap(handle, point.x, point.y, $0, $1) }
    }

    func longPress(_ point: Point, for duration: Duration) async throws(DeviceError) {
        try await complete { pp_long_press(handle, point.x, point.y, duration.milliseconds, $0, $1) }
    }

    func swipe(from start: Point, to end: Point, over duration: Duration) async throws(DeviceError) {
        try await complete { pp_swipe(handle, start.x, start.y, end.x, end.y, duration.milliseconds, $0, $1) }
    }

    func type(_ text: String) async throws(DeviceError) {
        try await complete { pp_type_text(handle, text, $0, $1) }
    }

    func press(_ button: HardwareButton) async throws(DeviceError) {
        try await complete { pp_press(handle, PP_Button(button), $0, $1) }
    }

    func press(_ key: KeyboardKey) async throws(DeviceError) {
        try await complete { pp_press_key(handle, key.usage, $0, $1) }
    }

    func launch(_ bundleID: String) async throws(DeviceError) {
        try await complete { pp_launch_app(handle, bundleID, $0, $1) }
    }

    /// The accessibility hierarchy, flattened, without geometry.
    func accessibilityNodes() async throws(DeviceError) -> [AccessibilityNode] {
        let json = try await bytes { pp_ax_snapshot(handle, $0, $1) }
        do {
            let nodes = try JSONDecoder().decode([AccessibilityNode].self, from: json)
            #if DEBUG
            let roles = Set(nodes.map { $0.role ?? "<none>" }).sorted()
            log.info("accessibility roles: \(roles.joined(separator: " | "), privacy: .public)")
            #endif
            return nodes
        } catch {
            throw .service("Unreadable accessibility snapshot: \(error)")
        }
    }

    func installedApps() async throws(DeviceError) -> [InstalledApp] {
        let json = try await bytes { pp_list_apps(handle, $0, $1) }
        do {
            return try JSONDecoder().decode([InstalledApp].self, from: json)
        } catch {
            throw .service("Unreadable app list: \(error)")
        }
    }

    /// A PNG of the display, used when ScreenCaptureKit is unavailable.
    func screenshot() async throws(DeviceError) -> Data {
        try await bytes { pp_screenshot(handle, $0, $1) }
    }
}

// MARK: - Callback bridging

private final class Completion<Value: Sendable>: Sendable {
    let continuation: CheckedContinuation<Result<Value, DeviceError>, Never>
    init(_ continuation: CheckedContinuation<Result<Value, DeviceError>, Never>) { self.continuation = continuation }
}

private func complete(_ start: (PP_CompletionCallback, UnsafeMutableRawPointer) -> Void) async throws(DeviceError) {
    try await withCheckedContinuation { continuation in
        let context = Unmanaged.passRetained(Completion<Void>(continuation)).toOpaque()
        start({ context, error, message in
            let completion = Unmanaged<Completion<Void>>.fromOpaque(context!).takeRetainedValue()
            completion.continuation.resume(returning: DeviceError(error, message).map(Result.failure) ?? .success(()))
        }, context)
    }
    .get()
}

private func bytes(_ start: (PP_BytesCallback, UnsafeMutableRawPointer) -> Void) async throws(DeviceError) -> Data {
    try await withCheckedContinuation { continuation in
        let context = Unmanaged.passRetained(Completion<Data>(continuation)).toOpaque()
        start({ context, bytes, count, error, message in
            let completion = Unmanaged<Completion<Data>>.fromOpaque(context!).takeRetainedValue()
            let result: Result<Data, DeviceError> = DeviceError(error, message).map(Result.failure)
                ?? .success(bytes.map { Data(bytes: $0, count: count) } ?? Data())
            completion.continuation.resume(returning: result)
        }, context)
    }
    .get()
}

extension DeviceError {
    /// The Swift error for a bridge result, or `nil` for success.
    init?(_ error: PP_Error, _ message: UnsafePointer<CChar>?) {
        let detail = message.map(String.init(cString:)) ?? "Unknown bridge failure."
        guard error != PP_Error_Ok else { return nil }
        log.error("Bridge error \(error.rawValue): \(detail, privacy: .public)")
        self = switch error {
        case PP_Error_Connection: .connectionFailed(detail)
        case PP_Error_SessionClosed: .disconnected
        default: .service(detail)
        }
    }
}

private extension PP_Button {
    init(_ button: HardwareButton) {
        self = switch button {
        case .home: PP_Button_Home
        case .lock: PP_Button_Lock
        case .volumeUp: PP_Button_VolumeUp
        case .volumeDown: PP_Button_VolumeDown
        }
    }
}

private extension KeyboardKey {
    /// The USB HID keyboard usage.
    var usage: UInt64 {
        switch self {
        case .return: 0x28
        case .escape: 0x29
        case .delete: 0x2A
        case .tab: 0x2B
        }
    }
}

private extension Duration {
    var milliseconds: UInt32 {
        let (seconds, attoseconds) = components
        return UInt32(clamping: seconds * 1000 + attoseconds / 1_000_000_000_000_000)
    }
}
