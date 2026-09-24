import AVFoundation
import AVKit
import CoreGraphics
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
    private static let cardSize = CGSize(width: 320, height: 180)
    /// Slowest frame gap: frames only on change, at most 2 per second.
    private static let minFrameInterval: TimeInterval = 0.5

    /// Called when the user taps PiP's pause button. RunModel stops the run.
    var onPause: (() -> Void)?

    private var displayLayer: AVSampleBufferDisplayLayer?
    private var pip: AVPictureInPictureController?
    private var running = false
    private var lastSignature: String?
    private var lastFrame = Date.distantPast

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
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            Self.log.error("audio session: \(String(describing: error), privacy: .public)")
        }
        guard let layer = displayLayer else {
            Self.log.error("start with no source layer; PiP unavailable")
            return
        }
        render(step: 0, action: "", thought: "")
        let controller = AVPictureInPictureController(
            contentSource: .init(sampleBufferDisplayLayer: layer, playbackDelegate: self)
        )
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        pip = controller
        Self.log.info("pip possible=\(controller.isPictureInPicturePossible)")
    }

    /// Enqueues one status card, unless nothing changed or the last frame is
    /// too recent. Called from the chained update funnel.
    func render(step: Int, action: String, thought: String) {
        guard running else { return }
        let signature = "\(step)\n\(action)\n\(thought)"
        guard signature != lastSignature else { return }
        let now = Date()
        guard now.timeIntervalSince(lastFrame) >= Self.minFrameInterval else { return }
        guard let sample = Self.sampleBuffer(step: step, action: action, thought: thought) else { return }
        lastSignature = signature
        lastFrame = now
        displayLayer?.sampleBufferRenderer.enqueue(sample)
    }

    /// Stops PiP and releases the audio session. Safe to call when idle.
    func stop() {
        guard running else { return }
        running = false
        lastSignature = nil
        pip?.stopPictureInPicture()
        pip = nil
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    private func didPressPause() {
        onPause?()
    }

    // MARK: - Card rendering

    private static func sampleBuffer(step: Int, action: String, thought: String) -> CMSampleBuffer? {
        let image = cardImage(step: step, action: action, thought: thought)
        let width = Int(cardSize.width)
        let height = Int(cardSize.height)
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
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        guard let cgImage = image.cgImage else { return nil }
        ctx.draw(cgImage, in: CGRect(origin: .zero, size: cardSize))

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

    private static func cardImage(step: Int, action: String, thought: String) -> UIImage {
        UIGraphicsImageRenderer(size: cardSize).image { _ in
            UIColor(white: 0.08, alpha: 1).setFill()
            UIRectFill(CGRect(origin: .zero, size: cardSize))
            let paragraph: NSMutableParagraphStyle = {
                let style = NSMutableParagraphStyle()
                style.lineBreakMode = .byTruncatingTail
                return style
            }()
            ("Step \(step)" as NSString).draw(
                in: CGRect(x: 16, y: 10, width: 288, height: 36),
                withAttributes: [.font: UIFont.boldSystemFont(ofSize: 26), .foregroundColor: UIColor.white, .paragraphStyle: paragraph]
            )
            (action as NSString).draw(
                in: CGRect(x: 16, y: 50, width: 288, height: 24),
                withAttributes: [.font: UIFont.systemFont(ofSize: 17), .foregroundColor: UIColor.lightGray, .paragraphStyle: paragraph]
            )
            (thought as NSString).draw(
                in: CGRect(x: 16, y: 78, width: 288, height: 44),
                withAttributes: [.font: UIFont.systemFont(ofSize: 15), .foregroundColor: UIColor.gray, .paragraphStyle: paragraph]
            )
            ("⏸ to stop" as NSString).draw(
                in: CGRect(x: 16, y: 148, width: 288, height: 22),
                withAttributes: [.font: UIFont.systemFont(ofSize: 14), .foregroundColor: UIColor.darkGray, .paragraphStyle: paragraph]
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
