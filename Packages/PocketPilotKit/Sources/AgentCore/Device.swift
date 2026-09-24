/// The phone, as the agent sees and touches it.
public protocol Device: Sendable {
    func observe() async throws(DeviceError) -> Screen
    func perform(_ gesture: Gesture) async throws(DeviceError)
    /// Apps the agent may open. Devices that can't list apps open by bundle identifier only.
    func installedApps() async throws(DeviceError) -> [InstalledApp]
}

extension Device {
    public func installedApps() async throws(DeviceError) -> [InstalledApp] { [] }
}

public enum DeviceError: Error, Sendable, Hashable {
    /// LocalDevVPN is not connected, so the device cannot reach itself.
    case tunnelUnavailable
    /// iOS only runs its developer-service listeners while Wi-Fi is on, even though traffic stays on the device.
    case wifiOff
    /// Establishing the link failed at a specific stage; `detail` names it.
    case connectionFailed(String)
    /// The pairing file is missing, malformed, or no longer trusted by the device.
    case pairingRejected
    /// The Developer Disk Image is not mounted, so CoreDevice services are absent.
    case developerImageMissing
    /// The link to the device has closed; reconnect before continuing.
    case disconnected
    case timedOut
    /// A device service failed; `message` is the underlying description.
    case service(String)
}
