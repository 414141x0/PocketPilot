import AgentCore
import CoreGraphics
import CoreText
import DeviceLink
import Foundation
import Testing

@Suite struct TextRecognitionTests {
    @Test func findsTextWithTopLeftFrame() async throws {
        let screenshot = Screenshot.rendering("Settings", width: 800, height: 1600, top: 200)

        let elements = await screenshot.recognizedText(firstID: 7)
        let element = try #require(elements.first)

        #expect(element.id == 7)
        #expect(element.label == "Settings")
        #expect((0.1...0.16).contains(element.frame.center.y), "Text drawn 200pt from the top of 1600 should center near y = 0.13")
    }
}

private extension Screenshot {
    /// White canvas with black text whose top edge sits `top` pixels below the top of the image.
    static func rendering(_ text: String, width: Int, height: Int, top: CGFloat) -> Screenshot {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let font = CTFontCreateWithName("Helvetica" as CFString, 64, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.textPosition = CGPoint(x: 100, y: CGFloat(height) - top - CTFontGetAscent(font))
        CTLineDraw(line, context)
        return Screenshot(image: context.makeImage()!)
    }
}
