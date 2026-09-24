#if DEBUG
public import CoreGraphics
import AgentCore
import FoundationModels

extension SystemPilot {
    /// Runs increasingly demanding requests against the on-device model and reports each outcome,
    /// to locate which capability a failing device lacks. Debug builds only.
    public static func diagnose(screenshot: CGImage) async -> [String] {
        let model = SystemLanguageModel.default
        var report = ["availability: \(model.availability)", "contextSize: \(model.contextSize)"]
        let tiny = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!.makeImage()!

        func attempt(_ name: String, _ body: () async throws -> Void) async {
            do {
                try await body()
                report.append("\(name): ok")
            } catch {
                report.append("\(name): \(error)")
            }
        }

        await attempt("text") { _ = try await LanguageModelSession(model: model).respond(to: "Reply with one word.") }
        await attempt("guided") {
            _ = try await LanguageModelSession(model: model).respond(to: "Tap element 1.", generating: Reply.self)
        }
        await attempt("tiny image") {
            _ = try await LanguageModelSession(model: model).respond(to: Prompt { "Describe this."; Attachment(tiny) })
        }
        await attempt("screenshot") {
            _ = try await LanguageModelSession(model: model).respond(to: Prompt { "Describe this."; Attachment(screenshot) })
        }
        await attempt("guided + screenshot") {
            _ = try await LanguageModelSession(model: model, instructions: instructions)
                .respond(to: Prompt { "Open Settings."; Attachment(screenshot) }, generating: Reply.self)
        }
        return report
    }

    /// Replays `decide`'s pipeline one call at a time on a real screen.
    public static func diagnose(screen: Screen) async -> [String] {
        let model = SystemLanguageModel.default
        let step = Step(goal: "Open the Settings app", screen: screen)
        let marked = await screen.markedScreenshot().image
        var report: [String] = []

        func attempt(_ name: String, _ body: () async throws -> String) async {
            do { report.append("\(name): ok \(try await body())") } catch { report.append("\(name): \(error)") }
        }

        await attempt("tokens instructions") { "\(try await model.tokenCount(for: Instructions(instructions)))" }
        await attempt("tokens schema") { "\(try await model.tokenCount(for: Reply.generationSchema))" }
        await attempt("tokens brief") { "\(try await model.tokenCount(for: Prompt { step.brief(historyLimit: 5, elementLimit: 60) }))" }
        await attempt("tokens brief + image") {
            "\(try await model.tokenCount(for: Prompt { step.brief(historyLimit: 5, elementLimit: 60); Attachment(marked).label("screenshot") }))"
        }
        await attempt("respond brief + raw image") {
            let reply = try await LanguageModelSession(model: model, instructions: instructions)
                .respond(to: Prompt { step.brief(historyLimit: 5, elementLimit: 60); Attachment(screen.screenshot.image).label("screenshot") }, generating: Reply.self)
            return "\(reply.content.action)"
        }
        await attempt("respond brief + marked image") {
            let reply = try await LanguageModelSession(model: model, instructions: instructions)
                .respond(to: Prompt { step.brief(historyLimit: 5, elementLimit: 60); Attachment(marked).label("screenshot") }, generating: Reply.self)
            return "\(reply.content.action)"
        }
        return report
    }
}
#endif
