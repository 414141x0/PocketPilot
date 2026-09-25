import AVFoundation
import AVKit
import CoreGraphics
import CoreMedia
import Foundation
import OSLog
import UIKit

/// Keeps PocketPilot alive and GPU-capable while a run is active, via a
/// Picture-in-Picture status card. Device-proven: without PiP the app is
/// suspended once another app is frontmost; with PiP it stays alive and Metal
/// work completes. Generalizes the DEBUG-only GPUProbe setup (which stays as is).
///
/// Frames ride the same chained update funnel as the Live Activity, so a late
/// frame can never overwrite a newer step. PiP starts automatically when the
/// app backgrounds mid-run; its pause button stops the run.
@MainActor
final class BackgroundKeeper: NSObject {
    private static let log = Logger(subsystem: "dev.typealias.PocketPilot", category: "KeepAlive")
    // Small on purpose: the PiP window covers part of the screen the agent
    // reads, so the card defaults compact and users stash it at an edge.
    private static let cardSize = CGSize(width: 240, height: 135)

    /// Called when the user taps PiP's pause button. RunModel stops the run.
    var onPause: (() -> Void)?

    private var displayLayer: AVSampleBufferDisplayLayer?
    private var pip: AVPictureInPictureController?
    private var synchronizer: AVSampleBufferRenderSynchronizer?
    private var receiver: AVSampleBufferVideoRenderer.Receiver?
    private var running = false
    private var lastSignature: String?

    /// Attaches the on-screen source layer. Called once from KeeperLayerHost.
    /// PiP refuses hidden or fully transparent layers, so the host stays visible.
    func attach(layer: AVSampleBufferDisplayLayer) {
        displayLayer = layer
    }

    /// Starts the audio session and PiP controller for a run. Best effort: if
    /// PiP can't start, the run proceeds without it.
    func start() {
        guard !running else { return }
        running = true
        do {
            // Mixing keeps the user's own audio playing; a run may be asked to play music.
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: .mixWithOthers)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            Self.log.error("audio session: \(String(describing: error), privacy: .public)")
        }
        guard let layer = displayLayer else {
            Self.log.error("start with no source layer; PiP unavailable")
            return
        }
        // iOS 27 path: the layer's renderer enqueues through a synchronizer
        // receiver, and the synchronizer needs rate 1 or frames won't display.
        let synchronizer = AVSampleBufferRenderSynchronizer()
        synchronizer.setRate(1, time: CMClockGetTime(CMClockGetHostTimeClock()))
        receiver = synchronizer.sampleBufferReceiver(adding: layer.sampleBufferRenderer)
        self.synchronizer = synchronizer
        render(step: 0, thought: "", action: "")
        let controller = AVPictureInPictureController(
            contentSource: .init(sampleBufferDisplayLayer: layer, playbackDelegate: self)
        )
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        pip = controller
        // Start explicitly once possible (the device-proven path); auto-start covers a later background.
        Task {
            for _ in 0..<20 where !controller.isPictureInPicturePossible {
                try? await Task.sleep(for: .milliseconds(100))
            }
            Self.log.info("pip possible=\(controller.isPictureInPicturePossible)")
            guard running, pip === controller else { return }
            controller.startPictureInPicture()
        }
    }

    /// Enqueues a status card when its content changed. Updates arrive a few per step,
    /// already ordered by RunModel, so every change is drawn.
    func render(step: Int, thought: String, action: String) {
        guard running else { return }
        let signature = "\(step)\n\(action)\n\(thought)"
        guard signature != lastSignature,
              let sample = Self.sampleBuffer(step: step, thought: thought, action: action),
              let receiver
        else { return }
        lastSignature = signature
        let ready = CMReadySampleBuffer<CMSampleBuffer.DynamicContent>(unsafeBuffer: sample)
        let result = receiver.enqueueImmediately(ready)
        if case .enqueued = result {} else {
            Self.log.error("enqueue: \(String(describing: result), privacy: .public)")
        }
    }

    /// Stops PiP and releases the audio session. Safe to call when idle.
    func stop() {
        guard running else { return }
        running = false
        lastSignature = nil
        pip?.stopPictureInPicture()
        pip = nil
        receiver = nil
        synchronizer = nil
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    private func didPressPause() {
        onPause?()
    }

    // MARK: - Card rendering

    private static func sampleBuffer(step: Int, thought: String, action: String) -> sending CMSampleBuffer? {
        let image = cardImage(step: step, thought: thought, action: action)
        guard let cgImage = image.cgImage else { return nil }
        return makeSample(from: cgImage)
    }

    /// Builds the media sample off the main actor so the (non-Sendable) buffer
    /// stays in a disconnected region and can transfer to the ready wrapper.
    private nonisolated static func makeSample(from image: CGImage) -> sending CMSampleBuffer? {
        let width = image.width
        let height = image.height
        var pixels: CVPixelBuffer?
        CVPixelBufferCreate(
            nil, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels
        )
        guard let pixels else { return nil }
        CVPixelBufferLockBaseAddress(pixels, [])
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(pixels),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixels),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        // No flip: drawImage preserves CGImage row order, so row 0 lands in
        // memory row 0 (the video frame's top). A y-flip here renders upside down.
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixels, formatDescriptionOut: &format)
        guard let format else { return nil }
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: pixels, formatDescription: format,
            sampleTiming: &timing, sampleBufferOut: &sample
        )
        return sample
    }

    private static func cardImage(step: Int, thought: String, action: String) -> UIImage {
        UIGraphicsImageRenderer(size: cardSize).image { _ in
            UIColor(white: 0.08, alpha: 1).setFill()
            UIRectFill(CGRect(origin: .zero, size: cardSize))
            let paragraph: NSMutableParagraphStyle = {
                let style = NSMutableParagraphStyle()
                style.lineBreakMode = .byTruncatingTail
                return style
            }()
            (String(localized: "Step \(step)") as NSString).draw(
                in: CGRect(x: 12, y: 8, width: 216, height: 27),
                withAttributes: [.font: UIFont.boldSystemFont(ofSize: 20), .foregroundColor: UIColor.white, .paragraphStyle: paragraph]
            )
            (action as NSString).draw(
                in: CGRect(x: 12, y: 38, width: 216, height: 18),
                withAttributes: [.font: UIFont.systemFont(ofSize: 13), .foregroundColor: UIColor.lightGray, .paragraphStyle: paragraph]
            )
            (thought as NSString).draw(
                in: CGRect(x: 12, y: 59, width: 216, height: 33),
                withAttributes: [.font: UIFont.systemFont(ofSize: 11), .foregroundColor: UIColor.gray, .paragraphStyle: paragraph]
            )
            (String(localized: "⏸ to stop") as NSString).draw(
                in: CGRect(x: 12, y: 111, width: 216, height: 16),
                withAttributes: [.font: UIFont.systemFont(ofSize: 11), .foregroundColor: UIColor.darkGray, .paragraphStyle: paragraph]
            )
        }
    }
}

extension BackgroundKeeper: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {
        guard !playing else { return }
        Task { await self.didPressPause() }
    }

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
        // The controller only exists while a run is active, so playback is
        // never paused from PiP's point of view; pause means stop the run.
        false
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, skipByInterval skipInterval: CMTime) async {}
}
