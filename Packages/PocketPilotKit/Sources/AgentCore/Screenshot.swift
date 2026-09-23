public import CoreGraphics
public import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A captured frame of the whole display.
///
/// Holds the decoded image so on-device models can consume it without a
/// round trip through an encoder; network models ask for compressed bytes.
public struct Screenshot: Sendable {
    public let image: CGImage

    public init(image: CGImage) {
        self.image = image
    }

    public var width: Int { image.width }
    public var height: Int { image.height }

    /// JPEG bytes, downscaled so the longest edge is at most `maxDimension` pixels.
    @concurrent
    public func jpeg(maxDimension: Int = 1568, quality: Double = 0.8) async -> Data? {
        guard let scaled = image.scaled(toFit: maxDimension) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, scaled, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

extension CGImage {
    func scaled(toFit maxDimension: Int) -> CGImage? {
        let scale = min(1, Double(maxDimension) / Double(max(width, height)))
        guard scale < 1 else { return self }
        let size = (width: Int(Double(width) * scale), height: Int(Double(height) * scale))
        guard let context = CGContext(
            data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(self, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        return context.makeImage()
    }
}
