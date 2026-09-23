import AgentCore
import DeviceLink
import Foundation
import Testing

@Suite struct PairingFileTests {
    @Test func acceptsPairingRecord() throws {
        let record: [String: Any] = [
            "HostID": "HOST", "SystemBUID": "BUID", "UDID": "00008120-TEST",
            "HostCertificate": Data([1]), "HostPrivateKey": Data([2]), "DeviceCertificate": Data([3]),
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: record, format: .xml, options: 0)

        #expect(try PairingFile(data: data).udid == "00008120-TEST")
    }

    @Test func rejectsOtherPropertyLists() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: ["Name": "nope"], format: .xml, options: 0)

        #expect(throws: DeviceError.pairingRejected) { try PairingFile(data: data) }
    }
}
