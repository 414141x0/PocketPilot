/// The phone, as the agent sees and touches it.
public protocol Device: Sendable {
    func observe() async throws(DeviceError) -> Observation
    func perform(_ gesture: Gesture) async throws(DeviceError)
}

public enum DeviceError: Error, Sendable, Hashable {
    /// LocalDevVPN is not connected, so the device cannot reach itself.
    case tunnelUnavailable
    /// The pairing file is missing, malformed, or no longer trusted by the device.
    case pairingRejected
    /// The Developer Disk Image is not mounted, so CoreDevice services are absent.
    case developerImageMissing
    case timedOut
    /// A device service failed; `message` is the underlying description.
    case service(String)
}
