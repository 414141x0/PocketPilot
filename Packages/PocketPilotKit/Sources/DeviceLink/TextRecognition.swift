public import AgentCore
import Vision

extension Screenshot {
    /// On-screen text found by on-device OCR, as elements the agent can target by id.
    ///
    /// A fallback for screens whose accessibility data is sparse or missing geometry.
    @concurrent
    public func recognizedText(firstID: Int = 1) async -> [Element] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        guard let observations = try? await request.perform(on: image, orientation: nil) else { return [] }

        return observations
            .compactMap { observation -> (String, Bool, CGRect)? in
                guard let text = observation.topCandidates(1).first, text.confidence >= 0.3 else { return nil }
                return (text.string, observation.isTitle, observation.boundingBox.verticallyFlipped().cgRect)
            }
            .enumerated()
            .map { index, found in
                let (text, isTitle, box) = found
                return Element(
                    id: firstID + index,
                    role: isTitle ? .header : .text,
                    label: text,
                    frame: Rect(x: box.minX, y: box.minY, width: box.width, height: box.height)
                )
            }
    }
}
