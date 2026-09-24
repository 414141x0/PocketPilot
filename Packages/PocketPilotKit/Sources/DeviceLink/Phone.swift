public import AgentCore
import Foundation
import ImageIO

/// This iPhone as an agent ``Device``: CoreDevice input through the bridge,
/// and ScreenCaptureKit frames when the user shares the display.
public struct Phone: Device {
    private let session: BridgeSession
    private let display: DisplayCapture?

    /// Connects to this device through LocalDevVPN.
    ///
    /// Pass a running ``DisplayCapture`` for fast, settle-aware screenshots; without one,
    /// the phone falls back to CoreDevice screenshots.
    public static func connect(pairing: PairingFile, display: DisplayCapture? = nil) async throws(DeviceError) -> Phone {
        Phone(session: try await BridgeSession.open(pairing), display: display)
    }

    /// Captures the settled screen, then reads accessibility and on-screen text concurrently.
    ///
    /// Accessibility supplies meaning but no geometry; text recognition supplies geometry.
    /// Without accessibility, recognized text alone is still a usable screen.
    public func observe() async throws(DeviceError) -> Screen {
        let screenshot = try await screenshot()
        async let nodes = try? session.accessibilityNodes()
        let text = await screenshot.recognizedText()
        return Screen(screenshot: screenshot, merging: await nodes ?? [], onto: text)
    }

    public func installedApps() async throws(DeviceError) -> [InstalledApp] {
        try await session.installedApps()
    }

    public func perform(_ gesture: Gesture) async throws(DeviceError) {
        switch gesture {
        case .tap(let point): try await session.tap(point)
        case .longPress(let point, let duration): try await session.longPress(point, for: duration)
        case .swipe(let start, let end, let duration): try await session.swipe(from: start, to: end, over: duration)
        case .type(let text): try await session.type(text)
        case .press(let button): try await session.press(button)
        case .key(let key): try await session.press(key)
        case .launch(let bundleID): try await session.launch(bundleID)
        }
    }

    private func screenshot() async throws(DeviceError) -> Screenshot {
        if let display {
            try? await display.settled()
            do {
                return try display.screenshot()
            } catch {
                // Fall through to CoreDevice when the stream has stopped or has no frame yet.
            }
        }
        guard let image = await Self.decode(try await session.screenshot()) else {
            throw .service("The device returned an unreadable screenshot.")
        }
        return Screenshot(image: image)
    }

    @concurrent
    private static func decode(_ png: Data) async -> CGImage? {
        CGImageSourceCreateWithData(png as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    }
}
