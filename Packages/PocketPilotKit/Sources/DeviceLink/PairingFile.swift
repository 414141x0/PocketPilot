public import AgentCore
public import Foundation

/// The lockdown pairing record that lets this app talk to its own device as a trusted host.
///
/// Users create it once on a computer (for example with idevice's pairing tool or
/// Jitterbug) and import it; it is the only credential PocketPilot needs.
public struct PairingFile: Sendable, Hashable {
    /// The raw property list, handed unchanged to the native bridge.
    public let data: Data
    public let udid: String?

    /// Validates that `data` is a pairing record before anything touches the network.
    public init(data: Data) throws(DeviceError) {
        guard let record = try? PropertyListDecoder().decode(Record.self, from: data) else {
            throw .pairingRejected
        }
        self.data = data
        udid = record.udid
    }

    private struct Record: Decodable {
        let hostID: String
        let systemBUID: String
        let hostCertificate: Data
        let hostPrivateKey: Data
        let deviceCertificate: Data
        let udid: String?

        enum CodingKeys: String, CodingKey {
            case hostID = "HostID"
            case systemBUID = "SystemBUID"
            case hostCertificate = "HostCertificate"
            case hostPrivateKey = "HostPrivateKey"
            case deviceCertificate = "DeviceCertificate"
            case udid = "UDID"
        }
    }
}
