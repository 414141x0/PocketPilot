#if DEBUG
import AVFoundation
import AVKit
import CoreMedia
import Metal
import OSLog
import SwiftUI

/// Tests whether Metal work still completes after PocketPilot is backgrounded,
/// optionally while Picture in Picture is showing. Debug builds only.
///
/// Launch with POCKETPILOT_GPU_PROBE=control (no PiP) or =pip, then send the app to the background.
@MainActor
final class GPUProbe: NSObject {
    static let shared = GPUProbe()
    private let log = Logger(subsystem: "dev.typealias.PocketPilot", category: "GPUProbe")
    private var pip: AVPictureInPictureController?
    private var displayLayer: AVSampleBufferDisplayLayer?
    private var synchronizer: AVSampleBufferRenderSynchronizer?
    private var receiver: AVSampleBufferVideoRenderer.Receiver?
    private var frameTimer: Timer?

    var mode: String? { ProcessInfo.processInfo.environment["POCKETPILOT_GPU_PROBE"] }

    func start(layer: AVSampleBufferDisplayLayer) {
        guard let mode else { return }
        log.info("mode=\(mode, privacy: .public)")
        if mode == "pip" { startPictureInPicture(on: layer) }
        Task { await dispatchForever() }
    }

    private func startPictureInPicture(on layer: AVSampleBufferDisplayLayer) {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            log.error("audio session: \(String(describing: error), privacy: .public)")
        }
        displayLayer = layer
        // iOS 27 path: enqueue through a synchronizer receiver at rate 1.
        let synchronizer = AVSampleBufferRenderSynchronizer()
        synchronizer.setRate(1, time: CMClockGetTime(CMClockGetHostTimeClock()))
        receiver = synchronizer.sampleBufferReceiver(adding: layer.sampleBufferRenderer)
        self.synchronizer = synchronizer
        frameTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { _ in
            MainActor.assumeIsolated { self.enqueueFrame() }
        }
        let controller = AVPictureInPictureController(contentSource: .init(sampleBufferDisplayLayer: layer, playbackDelegate: self))
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        pip = controller
        Task {
            try? await Task.sleep(for: .seconds(1))
            log.info("pip possible=\(controller.isPictureInPicturePossible)")
            controller.startPictureInPicture()
        }
    }

    private func enqueueFrame() {
        guard let receiver, let sample = Self.makeSample() else { return }
        let ready = CMReadySampleBuffer<CMSampleBuffer.DynamicContent>(unsafeBuffer: sample)
        _ = receiver.enqueueImmediately(ready)
    }

    private nonisolated static func makeSample() -> sending CMSampleBuffer? {
        var pixels: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels)
        guard let pixels else { return nil }
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixels, formatDescriptionOut: &format)
        guard let format else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixels, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
        return sample
    }

    /// Dispatches a trivial compute kernel every two seconds and logs whether the GPU ran it.
    private func dispatchForever() async {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let library = try? await device.makeLibrary(source: "kernel void k(device float *x [[buffer(0)]], uint i [[thread_position_in_grid]]) { x[i] = x[i] * 2 + 1; }", options: nil),
              let function = library.makeFunction(name: "k"),
              let pipeline = try? await device.makeComputePipelineState(function: function),
              let buffer = device.makeBuffer(length: 4096 * 4)
        else { log.error("metal setup failed"); return }

        for index in 1...60 {
            let state = UIApplication.shared.applicationState
            let pipActive = pip?.isPictureInPictureActive ?? false
            guard let commands = queue.makeCommandBuffer(), let encoder = commands.makeComputeCommandEncoder() else { return }
            encoder.setComputePipelineState(pipeline)
            encoder.setBuffer(buffer, offset: 0, index: 0)
            encoder.dispatchThreads(MTLSize(width: 4096, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
            encoder.endEncoding()
            await commands.commitAndWait()
            let outcome = commands.error.map { String(describing: $0) } ?? "ok"
            log.info("#\(index) appState=\(state.rawValue) pip=\(pipActive) gpu=\(outcome, privacy: .public)")
            try? await Task.sleep(for: .seconds(2))
        }
    }
}

extension GPUProbe: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {}
    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }
    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool { false }
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, skipByInterval skipInterval: CMTime) async {}
}

/// Hosts the sample-buffer layer PiP draws from; it must be on screen for PiP to start.
struct GPUProbeView: UIViewRepresentable {
    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    }

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        GPUProbe.shared.start(layer: view.layer as! AVSampleBufferDisplayLayer)
        return view
    }

    func updateUIView(_ view: LayerView, context: Context) {}
}

private extension MTLCommandBuffer {
    /// Commits and suspends until the GPU finishes; the handler must be attached before committing.
    func commitAndWait() async {
        await withCheckedContinuation { continuation in
            addCompletedHandler { _ in continuation.resume() }
            commit()
        }
    }
}
#endif
