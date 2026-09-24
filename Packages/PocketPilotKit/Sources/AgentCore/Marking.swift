import CoreGraphics
import CoreText
import Foundation

extension Screen {
    /// The screenshot with every listed element outlined and tagged with its id.
    ///
    /// Marks let a model tie the element list to what it sees, and make unlabeled
    /// icons easy to point at because everything already identified is boxed.
    @concurrent
    public func markedScreenshot() async -> Screenshot {
        let image = screenshot.image
        let size = CGSize(width: image.width, height: image.height)
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return screenshot }

        context.draw(image, in: CGRect(origin: .zero, size: size))
        // Work in top-left coordinates to match unit-space frames.
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)

        let stroke = max(2, max(size.width, size.height) / 400)
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, max(size.width, size.height) / 60, nil)
        for element in elements where element.isMeaningful {
            let box = CGRect(
                x: element.frame.origin.x * size.width, y: element.frame.origin.y * size.height,
                width: element.frame.width * size.width, height: element.frame.height * size.height
            )
            context.setStrokeColor(Mark.color)
            context.setLineWidth(stroke)
            context.stroke(box)
            Mark.tag("\(element.id)", at: box.origin, font: font, in: context)
        }
        return context.makeImage().map(Screenshot.init) ?? screenshot
    }
}

private enum Mark {
    static let color = CGColor(srgbRed: 1, green: 0.1, blue: 0.5, alpha: 1)

    /// Draws `text` in white on a filled tag whose top-left corner is `origin`.
    static func tag(_ text: String, at origin: CGPoint, font: CTFont, in context: CGContext) {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let bounds = CTLineGetImageBounds(line, context)
        let padding = CTFontGetSize(font) / 4
        let tag = CGRect(x: origin.x, y: origin.y, width: bounds.width + padding * 2, height: CTFontGetSize(font) + padding)

        context.setFillColor(color)
        context.fill(tag)
        context.textPosition = CGPoint(x: tag.minX + padding, y: tag.minY + CTFontGetAscent(font) + padding / 2)
        CTLineDraw(line, context)
    }
}
