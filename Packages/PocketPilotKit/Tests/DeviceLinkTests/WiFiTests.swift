import Testing
@testable import AgentCore
@testable import DeviceLink

@Suite struct WiFiTests {
    @Test func wifiOffDescriptionExplainsJoinedRequirementAndWorkaround() {
        let error = DeviceError.wifiOff
        #expect(!error.isRecoverable)
        #expect(error.description.contains("Join Wi-Fi to continue"))
        #expect(error.description.contains("while joined to a Wi-Fi network"))
        #expect(error.description.contains("Airplane Mode on"))
    }

    @Test func isUpSettlesWithCustomDuration() async {
        // In headless testing without Wi-Fi interface, isUp settles and returns false cleanly.
        let isUp = await WiFi.isUp(settle: .milliseconds(50))
        // Either true (if host has active Wi-Fi) or false, but does not hang or crash.
        _ = isUp
    }
}
