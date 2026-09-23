public import AgentCore
import CoreMedia
import ScreenCaptureKit
import Synchronization
import VideoToolbox

/// The whole display, streamed through ScreenCaptureKit once the user shares it from the system picker.
///
/// Only the newest frame is kept. Frame status doubles as a stillness signal:
/// ScreenCaptureKit stops producing complete frames while nothing on screen changes.
public final class DisplayCapture: Sendable {
    /// Only started and stopped, both of which ScreenCaptureKit synchronizes internally.
    nonisolated(unsafe) private let stream: SCStream
    private let receiver = FrameReceiver()

    /// Presents the system picker for the display and starts streaming what the user shares.
    @MainActor
    public static func start() async throws(CaptureError) -> DisplayCapture {
        let capture = DisplayCapture(filter: try await DisplayPicker().pick())
        do {
            try capture.stream.addStreamOutput(capture.receiver, type: .screen, sampleHandlerQueue: capture.receiver.queue)
            try await capture.stream.startCapture()
        } catch {
            throw CaptureError(error)
        }
        return capture
    }

    private init(filter: SCContentFilter) {
        let configuration = SCStreamConfiguration()
        let scale = Double(min(filter.pointPixelScale, 2))
        configuration.width = Int(filter.contentRect.width * scale)
        configuration.height = Int(filter.contentRect.height * scale)
        stream = SCStream(filter: filter, configuration: configuration, delegate: receiver)
    }

    /// The newest frame.
    public func screenshot() throws(CaptureError) -> Screenshot {
        try receiver.state.withLock { state throws(CaptureError) in
            if let failure = state.failure { throw failure }
            guard let frame = state.frame else { throw .noFrame }
            return Screenshot(image: frame)
        }
    }

    /// Suspends until the screen has not changed for `quiet`, or until `timeout` elapses.
    public func settled(quiet: Duration = .milliseconds(250), timeout: Duration = .seconds(3)) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let stillFor = ContinuousClock.now - receiver.state.withLock(\.lastChange)
            if stillFor >= quiet { return }
            try await Task.sleep(for: quiet - stillFor)
        }
    }

    public func stop() async {
        try? await stream.stopCapture()
    }
}

/// Receives frames on the capture queue and keeps only the newest one.
private final class FrameReceiver: NSObject, SCStreamOutput, SCStreamDelegate, Sendable {
    struct State {
        var frame: CGImage?
        var lastChange = ContinuousClock.now
        var failure: CaptureError?
    }

    let state = Mutex(State())
    let queue = DispatchQueue(label: "PocketPilot.DisplayCapture", qos: .userInitiated)

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.carriesNewFrame, let frame = sampleBuffer.image else { return }
        state.withLock {
            $0.frame = frame
            $0.lastChange = .now
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        state.withLock { $0.failure = CaptureError(error) }
    }
}

public enum CaptureError: Error, Sendable, Hashable {
    /// Screen recording is unsupported or restricted on this device.
    case unavailable
    /// The user dismissed the picker or declined to share the display.
    case declined
    /// Capture is running but no frame has arrived yet.
    case noFrame
    /// The system or the user stopped the stream.
    case stopped(String)

    init(_ error: any Error) {
        switch (error as NSError).code {
        case SCStreamError.Code.userDeclined.rawValue: self = .declined
        default: self = .stopped(error.localizedDescription)
        }
    }
}

private extension CMSampleBuffer {
    var image: CGImage? {
        var image: CGImage?
        guard let pixels = imageBuffer, VTCreateCGImageFromCVPixelBuffer(pixels, options: nil, imageOut: &image) == noErr else { return nil }
        return image
    }

    /// Whether this buffer holds a new image rather than an idle, blank, or suspended status.
    var carriesNewFrame: Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(self, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int
        else { return false }
        return [.complete, .started].contains(SCFrameStatus(rawValue: raw))
    }
}

/// Bridges the observer-based system picker to a single async answer.
@MainActor
private final class DisplayPicker: NSObject, SCContentSharingPickerObserver {
    private var continuation: CheckedContinuation<SCContentFilter, any Error>?

    func pick() async throws(CaptureError) -> SCContentFilter {
        let picker = SCContentSharingPicker.shared
        guard picker.isAvailable else { throw .unavailable }
        picker.isActive = true
        picker.add(self)
        defer { picker.remove(self) }
        do {
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                picker.present(using: .display)
            }
        } catch {
            throw error as? CaptureError ?? CaptureError(error)
        }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        // The system hands us a fresh, immutable filter that nothing else references.
        nonisolated(unsafe) let filter = filter
        Task { @MainActor in
            continuation?.resume(returning: filter)
            continuation = nil
        }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in fail(.declined) }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        let error = CaptureError(error)
        Task { @MainActor in fail(error) }
    }

    private func fail(_ error: CaptureError) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
