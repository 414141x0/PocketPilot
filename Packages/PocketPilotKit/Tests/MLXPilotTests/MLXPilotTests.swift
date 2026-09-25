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

    @Test func transportSchemaConvertsBackToSharedReply() throws {
        let content = try GeneratedContent(
            json: #"{"thought":"Did: at Home. Expect: Settings opens. Next: open Settings.","action":{"type":"open","app":"Settings"}}"#
        )
        let reply = try MLXDecisionSchema.reply(from: content, on: emptyScreen())
        #expect(
            MLXPilot.mapDecision(reply)
                == Decision(
                    thought: "Did: at Home. Expect: Settings opens. Next: open Settings.",
                    action: .open(app: "Settings")
                )
        )
    }

    @Test func transportSchemaRejectsMeaninglessAndUnsafeContent() throws {
        let numericThought = try GeneratedContent(
            json: #"{"thought":"1","action":{"type":"press","button":"home"}}"#
        )
        #expect(throws: MLXDecisionSchemaError.self) {
            _ = try MLXDecisionSchema.reply(from: numericThought, on: emptyScreen())
        }

        let absentElement = try GeneratedContent(
            json: #"{"thought":"Tap the visible control","action":{"type":"tap","element":299}}"#
        )
        #expect(throws: MLXDecisionSchemaError.self) {
            _ = try MLXDecisionSchema.reply(from: absentElement, on: emptyScreen())
        }

        let emptyApp = try GeneratedContent(
            json: #"{"thought":"Open the requested app","action":{"type":"open","app":"  "}}"#
        )
        #expect(throws: MLXDecisionSchemaError.self) {
            _ = try MLXDecisionSchema.reply(from: emptyApp, on: emptyScreen())
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
