public import AgentCore
import CoreGraphics
import Foundation
import FoundationModels
import MLXFoundationModels
import MLXLMCommon
import MLXVLM
import OSLog
import PilotSchema
import Tokenizers
import os

/// A stateless pilot backed by LiquidAI's local 4-bit LFM2.5 vision-language model.
public struct MLXPilot: Pilot {
    private static let log = Logger(subsystem: "dev.typealias.PocketPilot", category: "MLXPilot")
    private static let minimumAvailableMemory = 3_250_000_000
    private static let initialElementLimit = 60
    private static let retryElementLimit = 30

    private let model: MLXLanguageModel
    public let maxHistoryTurns: Int

    public init(modelDirectory: URL, maxHistoryTurns: Int = 5) throws {
        let available = Self.availableMemory
        guard available >= Self.minimumAvailableMemory else {
            throw MLXPilotError.insufficientMemory(
                requiredBytes: Self.minimumAvailableMemory,
                availableBytes: available
            )
        }

        let configuration = ModelConfiguration(directory: modelDirectory)
        self.model = MLXLanguageModel(
            configuration: configuration,
            capabilities: [.guidedGeneration, .vision],
            weightsLocation: { _ in modelDirectory },
            load: { _, progressHandler in
                let clock = ContinuousClock()
                let start = clock.now
                do {
                    let container = try await loadModelContainer(
                        from: modelDirectory,
                        using: TransformersTokenizerLoader()
                    )
                    let elapsed = start.duration(to: clock.now)
                    Self.log.info("Model load completed in \(Self.milliseconds(elapsed), privacy: .public) ms")
                    let progress = Progress(totalUnitCount: 1)
                    progress.completedUnitCount = 1
                    progressHandler(progress)
                    return container
                } catch {
                    Self.log.error("Model load failed: \(String(describing: error), privacy: .public)")
                    throw error
                }
            }
        )
        self.maxHistoryTurns = maxHistoryTurns
    }

    public func decide(_ step: Step) async throws -> Decision {
        let image = Self.resized(await step.screen.markedScreenshot().image, maximumDimension: 512)
        let clock = ContinuousClock()
        let start = clock.now
        do {
            let reply: Reply
            do {
                reply = try await respond(
                    to: step,
                    image: image,
                    historyLimit: maxHistoryTurns,
                    elementLimit: Self.initialElementLimit
                )
            } catch LanguageModelError.contextSizeExceeded(let context) {
                let limits = Self.contextRetryLimits(maxHistoryTurns: maxHistoryTurns)
                Self.log.notice(
                    "Step \(step.number, privacy: .public) exceeded \(context.contextSize, privacy: .public) tokens with \(context.tokenCount, privacy: .public); retrying with history \(limits.history, privacy: .public) and \(limits.elements, privacy: .public) elements"
                )
                reply = try await respond(
                    to: step,
                    image: image,
                    historyLimit: limits.history,
                    elementLimit: limits.elements
                )
            }
            Self.log.info(
                "Step \(step.number, privacy: .public) inference completed in \(Self.milliseconds(start.duration(to: clock.now)), privacy: .public) ms"
            )
            return PilotDecisionSchema.map(reply)
        } catch {
            Self.log.error(
                "Step \(step.number, privacy: .public) inference failed: \(String(describing: error), privacy: .public)"
            )
            throw error
        }
    }

    private func respond(
        to step: Step,
        image: CGImage,
        historyLimit: Int,
        elementLimit: Int
    ) async throws -> Reply {
        let prompt = Prompt {
            step.brief(historyLimit: historyLimit, elementLimit: elementLimit)
            Attachment(image).label("screenshot")
        }
        let session = LanguageModelSession(model: model, instructions: Self.instructions)
        return try await session.respond(
            to: prompt,
            generating: Reply.self,
            options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 64)
        ).content
    }

    static func contextRetryLimits(maxHistoryTurns: Int) -> (history: Int, elements: Int) {
        (history: min(max(0, maxHistoryTurns), 2), elements: retryElementLimit)
    }

    private static var availableMemory: Int {
        #if os(iOS)
        os_proc_available_memory()
        #else
        Int(ProcessInfo.processInfo.physicalMemory)
        #endif
    }

    /// Exposed so tests can prove SystemPilot and MLXPilot use byte-for-byte equivalent schemas.
    public static var decisionSchema: GenerationSchema { Reply.generationSchema }

    static func mapDecision(_ reply: Reply) -> Decision {
        PilotDecisionSchema.map(reply)
    }

    private static func resized(_ image: CGImage, maximumDimension: Int) -> CGImage {
        let largest = max(image.width, image.height)
        guard largest > maximumDimension else { return image }
        let scale = CGFloat(maximumDimension) / CGFloat(largest)
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}

private struct TransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TransformersTokenizer(
            try await Tokenizers.AutoTokenizer.from(modelFolder: directory)
        )
    }
}

private struct TransformersTokenizer: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages,
                tools: tools,
                additionalContext: additionalContext
            )
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}

public enum MLXPilotError: LocalizedError, Sendable {
    case insufficientMemory(requiredBytes: Int, availableBytes: Int)

    public var errorDescription: String? {
        switch self {
        case .insufficientMemory(let required, let available):
            "Local MLX needs about \(ByteCountFormatter.string(fromByteCount: Int64(required), countStyle: .memory)) available memory, but this process currently has \(ByteCountFormatter.string(fromByteCount: Int64(available), countStyle: .memory))."
        }
    }
}
