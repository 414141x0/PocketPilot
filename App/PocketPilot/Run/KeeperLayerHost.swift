import AVFoundation
import SwiftUI
import UIKit

/// Hosts the sample-buffer layer PiP draws from. It must stay on screen and
/// genuinely visible (PiP refuses hidden or fully transparent layers), so it
/// lives as a 2×2 pt overlay in RunView's corner rather than DEBUG-only chrome.
struct KeeperLayerHost: UIViewRepresentable {
    let keeper: BackgroundKeeper

    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    }

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        let layer = view.layer as! AVSampleBufferDisplayLayer
        keeper.attach(layer: layer)
        return view
    }

    func updateUIView(_ view: LayerView, context: Context) {}
}
