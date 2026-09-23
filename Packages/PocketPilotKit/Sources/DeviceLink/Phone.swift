public import AgentCore
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

    public func observe() async throws(DeviceError) -> Screen {
        Screen(screenshot: try await screenshot())
    }

    public func perform(_ gesture: Gesture) async throws(DeviceError) {
        switch gesture {
        case .tap(let point): try await session.tap(point)
        case .longPress(let point, let duration): try await session.longPress(point, for: duration)
        case .swipe(let start, let end, let duration): try await session.swipe(from: start, to: end, over: duration)
        case .type(let text): try await session.type(text)
        case .press(let button): try await session.press(button)
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
        let png = try await session.screenshot()
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw .service("The device returned an unreadable screenshot.") }
        return Screenshot(image: image)
    }
}
