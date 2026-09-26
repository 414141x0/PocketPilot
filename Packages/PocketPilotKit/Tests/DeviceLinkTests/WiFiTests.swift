import Foundation
import Testing
@testable import AgentCore
@testable import DeviceLink

@Suite struct WiFiTests {
    @Test func wifiOffDescriptionExplainsJoinedRequirementAndGuidance() {
        let error = DeviceError.wifiOff
        #expect(!error.isRecoverable)
        #expect(error.description.contains("Join Wi-Fi to continue"))
        #expect(error.description.contains("while joined to a Wi-Fi network"))
        #expect(error.description.contains("another phone's hotspot works too"))
        #expect(error.description.contains("then reconnect LocalDevVPN"))
        #expect(!error.description.contains("Airplane Mode on"))
    }

    @Test func neverSatisfiedStreamReturnsFalseWithinSettle() async {
        let (stream, continuation) = AsyncStream<Bool>.makeStream()
        continuation.yield(false)

        let start = ContinuousClock().now
        let isUp = await WiFi.isUp(
            paths: stream,
            settle: .milliseconds(100),
            onFinish: { continuation.finish() }
        )
        let elapsed = ContinuousClock().now - start

        #expect(!isUp)
        #expect(elapsed >= .milliseconds(90) && elapsed < .milliseconds(500))
    }

    @Test func delayedSatisfiedStreamReturnsTrueImmediately() async {
        let (stream, continuation) = AsyncStream<Bool>.makeStream()
        continuation.yield(false)

        Task {
            try? await Task.sleep(for: .milliseconds(20))
            continuation.yield(true)
        }

        let start = ContinuousClock().now
        let isUp = await WiFi.isUp(
            paths: stream,
            settle: .seconds(2),
            onFinish: { continuation.finish() }
        )
        let elapsed = ContinuousClock().now - start

        #expect(isUp)
        #expect(elapsed < .milliseconds(500))
    }
}
