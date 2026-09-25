#if DEBUG
import AgentCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Saves what each pilot is shown, the text brief and the marked screenshot, to
/// tmp/steps/ in the app container, for inspecting prompt quality. Debug builds only.
/// Enable by launching with POCKETPILOT_RECORD=1.
nonisolated enum StepRecorder {
    static let isEnabled = ProcessInfo.processInfo.environment["POCKETPILOT_RECORD"] != nil
    static let directory = FileManager.default.temporaryDirectory.appending(path: "steps")

    static func reset() {
        guard isEnabled else { return }
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    @concurrent
    static func record(_ step: Step) async {
        guard isEnabled else { return }
        let name = String(format: "step-%02d", step.number)
        try? step.brief().write(to: directory.appending(path: "\(name).txt"), atomically: true, encoding: .utf8)
        let image = await step.screen.markedScreenshot().image
        let url = directory.appending(path: "\(name).png") as CFURL
        guard let destination = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
#endif
