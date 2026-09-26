import CoreGraphics
import Foundation
import FoundationModels
import Testing
@testable import AgentCore
@testable import MLXPilot
@testable import PilotSchema
import SystemPilot

@Suite(.serialized) @MainActor
struct MLXPilotTests {
    @Test func mapsTheSharedSchema() {
        let reply = Reply(thought: "Open Settings", action: .open(app: "Settings"))
        #expect(
            MLXPilot.mapDecision(reply)
                == Decision(thought: "Open Settings", action: .open(app: "Settings"))
        )
    }

    @Test func schemaMatchesSystemPilotExactly() {
        // MLXPilot.decisionSchema exposes Reply.generationSchema (the @Generable schema shared with
        // SystemPilot). The flat MLX transport schema (MLXDecisionSchema.generationSchema) is a
        // separate artifact; its equivalence is validated by transportSchemaBoundsAllNumericTargets
        // and transportSchemaRoundTripsAllCases below.
        #expect(MLXPilot.decisionSchema.debugDescription == SystemPilot.decisionSchema.debugDescription)
    }

    @Test func contextRetryUsesOneSmallerFixedBrief() {
        let limits = MLXPilot.contextRetryLimits(maxHistoryTurns: 5)
        #expect(limits.history == 2)
        #expect(limits.elements == 30)
        #expect(MLXPilot.contextRetryLimits(maxHistoryTurns: 1).history == 1)
    }

    @Test func transportSchemaBoundsAllNumericTargets() throws {
        let data = try JSONEncoder().encode(MLXDecisionSchema.generationSchema)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains(#""minimum":0"#))
        #expect(json.contains(#""maximum":1000"#))
        #expect(json.contains(#""minimum":1"#))
        #expect(json.contains(#""maximum":300"#))
        #expect(json.contains(#""minimum":0.25"#))
        #expect(json.contains(#""maximum":10"#))
    }

    @Test func transportSchemaContainsAllActionTypesAndReplacingField() throws {
        let data = try JSONEncoder().encode(MLXDecisionSchema.generationSchema)
        let json = String(decoding: data, as: UTF8.self)
        // All 12 action type discriminators must appear in the flat schema.
        for actionType in ["tap", "tapPoint", "longPress", "scroll", "drag", "type",
                           "press", "key", "open", "wait", "done", "giveUp"] {
            #expect(json.contains("\"\(actionType)\""), "Missing action type: \(actionType)")
        }
        // replacing field must be present so the on-device model can clear text fields.
        #expect(json.contains("\"replacing\""))
    }

    @Test func transportSchemaRoundTripsAllCases() throws {
        let screen = screenWithElement(id: 5)

        // 1. tap(element:)
        let tap = try GeneratedContent(json: #"{"thought":"Tap element 5","action":{"type":"tap","element":5}}"#)
        let tapReply = try MLXDecisionSchema.reply(from: tap, on: screen)
        #expect(MLXPilot.mapDecision(tapReply) == Decision(thought: "Tap element 5", action: .tap(.element(5))))

        // 2. tapPoint(x:y:)
        let tapPt = try GeneratedContent(json: #"{"thought":"Tap point","action":{"type":"tapPoint","x":100,"y":200}}"#)
        let tapPtReply = try MLXDecisionSchema.reply(from: tapPt, on: emptyScreen())
        #expect(MLXPilot.mapDecision(tapPtReply) == Decision(thought: "Tap point", action: .tap(.point(Point(grid: 100, 200)))))

        // 3. longPress(element:)
        let lp = try GeneratedContent(json: #"{"thought":"Long press element 5","action":{"type":"longPress","element":5}}"#)
        let lpReply = try MLXDecisionSchema.reply(from: lp, on: screen)
        #expect(MLXPilot.mapDecision(lpReply) == Decision(thought: "Long press element 5", action: .longPress(.element(5))))

        // 4. scroll(direction:element:) — with and without element
        let scrollDown = try GeneratedContent(json: #"{"thought":"Scroll down","action":{"type":"scroll","direction":"down"}}"#)
        let scrollReply = try MLXDecisionSchema.reply(from: scrollDown, on: emptyScreen())
        #expect(MLXPilot.mapDecision(scrollReply) == Decision(thought: "Scroll down", action: .scroll(.down, in: nil)))

        let scrollEl = try GeneratedContent(json: #"{"thought":"Scroll up in 5","action":{"type":"scroll","direction":"up","element":5}}"#)
        let scrollElReply = try MLXDecisionSchema.reply(from: scrollEl, on: screen)
        #expect(MLXPilot.mapDecision(scrollElReply) == Decision(thought: "Scroll up in 5", action: .scroll(.up, in: .element(5))))

        // 5. drag
        let drag = try GeneratedContent(json: #"{"thought":"Drag","action":{"type":"drag","fromX":10,"fromY":20,"toX":300,"toY":400}}"#)
        let dragReply = try MLXDecisionSchema.reply(from: drag, on: emptyScreen())
        #expect(MLXPilot.mapDecision(dragReply) == Decision(thought: "Drag", action: .drag(from: .point(Point(grid: 10, 20)), to: .point(Point(grid: 300, 400)))))

        // 6. type — replacing:false (default) and replacing:true
        let typeDefault = try GeneratedContent(json: #"{"thought":"Type hello","action":{"type":"type","text":"hello"}}"#)
        let typeDefaultReply = try MLXDecisionSchema.reply(from: typeDefault, on: emptyScreen())
        #expect(MLXPilot.mapDecision(typeDefaultReply) == Decision(thought: "Type hello", action: .type("hello", replacing: false)))

        let typeReplacing = try GeneratedContent(json: #"{"thought":"Replace text","action":{"type":"type","text":"world","replacing":true}}"#)
        let typeReplacingReply = try MLXDecisionSchema.reply(from: typeReplacing, on: emptyScreen())
        #expect(MLXPilot.mapDecision(typeReplacingReply) == Decision(thought: "Replace text", action: .type("world", replacing: true)))

        // 7. press(button:) — all four hardware buttons
        for (buttonStr, expected) in [("home", HardwareButton.home), ("lock", .lock), ("volumeUp", .volumeUp), ("volumeDown", .volumeDown)] {
            let press = try GeneratedContent(json: "{\"thought\":\"Press \(buttonStr)\",\"action\":{\"type\":\"press\",\"button\":\"\(buttonStr)\"}}")
            let pressReply = try MLXDecisionSchema.reply(from: press, on: emptyScreen())
            #expect(MLXPilot.mapDecision(pressReply) == Decision(thought: "Press \(buttonStr)", action: .press(expected)))
        }

        // 8. key(name:) — all four keys
        for (keyStr, expected) in [("return", KeyboardKey.return), ("tab", .tab), ("escape", .escape), ("delete", .delete)] {
            let key = try GeneratedContent(json: "{\"thought\":\"Press \(keyStr)\",\"action\":{\"type\":\"key\",\"name\":\"\(keyStr)\"}}")
            let keyReply = try MLXDecisionSchema.reply(from: key, on: emptyScreen())
            #expect(MLXPilot.mapDecision(keyReply) == Decision(thought: "Press \(keyStr)", action: .key(expected)))
        }

        // 9. open(app:)
        let open = try GeneratedContent(json: #"{"thought":"Open Settings","action":{"type":"open","app":"Settings"}}"#)
        let openReply = try MLXDecisionSchema.reply(from: open, on: emptyScreen())
        #expect(MLXPilot.mapDecision(openReply) == Decision(thought: "Open Settings", action: .open(app: "Settings")))

        // 10. wait(seconds:)
        let wait = try GeneratedContent(json: #"{"thought":"Wait briefly","action":{"type":"wait","seconds":2.0}}"#)
        let waitReply = try MLXDecisionSchema.reply(from: wait, on: emptyScreen())
        #expect(MLXPilot.mapDecision(waitReply) == Decision(thought: "Wait briefly", action: .wait(seconds: 2.0)))

        // 11. done(summary:)
        let done = try GeneratedContent(json: #"{"thought":"Task complete","action":{"type":"done","summary":"All steps finished."}}"#)
        let doneReply = try MLXDecisionSchema.reply(from: done, on: emptyScreen())
        #expect(MLXPilot.mapDecision(doneReply) == Decision(thought: "Task complete", action: .done(summary: "All steps finished.")))

        // 12. giveUp(reason:)
        let giveUp = try GeneratedContent(json: #"{"thought":"Cannot proceed","action":{"type":"giveUp","reason":"No matching element."}}"#)
        let giveUpReply = try MLXDecisionSchema.reply(from: giveUp, on: emptyScreen())
        #expect(MLXPilot.mapDecision(giveUpReply) == Decision(thought: "Cannot proceed", action: .giveUp(reason: "No matching element.")))
    }

    @Test func transportSchemaRejectsMeaninglessAndUnsafeContent() throws {
        // Short numeric thought (device symptom: missing thought)
        let numericThought = try GeneratedContent(
            json: #"{"thought":"1","action":{"type":"press","button":"home"}}"#
        )
        #expect(throws: MLXDecisionSchemaError.self) {
            _ = try MLXDecisionSchema.reply(from: numericThought, on: emptyScreen())
        }

        // Element absent from screen (device symptom: element 2.1e44 — JSON float parse lands as out-of-range Int)
        let absentElement = try GeneratedContent(
            json: #"{"thought":"Tap the visible control","action":{"type":"tap","element":299}}"#
        )
        #expect(throws: MLXDecisionSchemaError.self) {
            _ = try MLXDecisionSchema.reply(from: absentElement, on: emptyScreen())
        }

        // Empty app name (device symptom: empty app)
        let emptyApp = try GeneratedContent(
            json: #"{"thought":"Open the requested app","action":{"type":"open","app":"  "}}"#
        )
        #expect(throws: MLXDecisionSchemaError.self) {
            _ = try MLXDecisionSchema.reply(from: emptyApp, on: emptyScreen())
        }

        // Empty type text
        let emptyText = try GeneratedContent(
            json: #"{"thought":"Type some text","action":{"type":"type","text":""}}"#
        )
        #expect(throws: MLXDecisionSchemaError.self) {
            _ = try MLXDecisionSchema.reply(from: emptyText, on: emptyScreen())
        }

        // Out-of-bounds element (> 300)
        let outOfRange = try GeneratedContent(
            json: #"{"thought":"Tap out of range","action":{"type":"tap","element":301}}"#
        )
        #expect(throws: MLXDecisionSchemaError.self) {
            _ = try MLXDecisionSchema.reply(from: outOfRange, on: emptyScreen())
        }
    }

    @Test func initDoesNotStartANetworkDownload() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MLXModelStore(
            rootDirectory: root,
            downloader: FailingDownloader(),
            minimumHeadroomBytes: 0
        )

        #expect(store.state == .notDownloaded)
        #expect(store.modelDirectory == nil)
    }

    @Test func downloadPublishesProgressThenReadyAndExcludesBackup() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = MLXModelStore.snapshotDirectory(in: root)
        try makeCompleteSnapshot(at: snapshot)
        try FileManager.default.removeItem(at: snapshot.appending(path: "model.safetensors"))

        let store = MLXModelStore(
            rootDirectory: root,
            downloader: CompletingDownloader(snapshot: snapshot),
            minimumHeadroomBytes: 0
        )
        await store.download()

        #expect(store.state == .ready)
        #expect(store.modelDirectory == snapshot)
        let values = try root.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test func cancelledDownloadKeepsPartialFilesForResume() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let partial = root.appending(path: "partial.incomplete")
        let store = MLXModelStore(
            rootDirectory: root,
            downloader: SuspendingDownloader(partialFile: partial),
            minimumHeadroomBytes: 0
        )

        let task = Task { await store.download() }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        await task.value

        #expect(store.state == .notDownloaded)
        #expect(FileManager.default.fileExists(atPath: partial.path))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "MLXPilotTests-(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private func emptyScreen() -> Screen {
        let context = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return Screen(screenshot: Screenshot(image: context.makeImage()!))
    }

    private func screenWithElement(id: Int) -> Screen {
        let context = CGContext(
            data: nil,
            width: 430,
            height: 932,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let element = Element(
            id: id,
            role: .button,
            label: "Test Button",
            frame: Rect(x: 10, y: 10, width: 100, height: 44)
        )
        return Screen(screenshot: Screenshot(image: context.makeImage()!), elements: [element])
    }

    private func makeCompleteSnapshot(at directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in MLXModelStore.requiredFiles {
            try Data(name.utf8).write(to: directory.appending(path: name))
        }
    }
}

private struct FailingDownloader: MLXModelDownloading {
    func download(
        progressHandler: @MainActor @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        Issue.record("The store performed unexpected network work")
        throw CancellationError()
    }
}

private struct CompletingDownloader: MLXModelDownloading {
    let snapshot: URL

    func download(
        progressHandler: @MainActor @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        let progress = Progress(totalUnitCount: MLXModelStore.expectedBytes)
        progress.completedUnitCount = MLXModelStore.expectedBytes / 2
        await progressHandler(progress)
        try Data("weights".utf8).write(to: snapshot.appending(path: "model.safetensors"))
        progress.completedUnitCount = progress.totalUnitCount
        await progressHandler(progress)
        return snapshot
    }
}

private struct SuspendingDownloader: MLXModelDownloading {
    let partialFile: URL

    func download(
        progressHandler: @MainActor @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        try FileManager.default.createDirectory(
            at: partialFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("partial".utf8).write(to: partialFile)
        try await Task.sleep(for: .seconds(30))
        throw CancellationError()
    }
}
