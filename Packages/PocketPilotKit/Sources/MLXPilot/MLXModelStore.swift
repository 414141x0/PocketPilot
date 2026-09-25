public import Foundation
public import HuggingFace
public import Observation

public enum MLXModelDownloadState: Equatable, Sendable {
    case notDownloaded
    case downloading(completedBytes: Int64, totalBytes: Int64)
    case ready
    case failed(String)

    public var fractionCompleted: Double? {
        guard case .downloading(let completed, let total) = self, total > 0 else { return nil }
        return min(1, max(0, Double(completed) / Double(total)))
    }
}

public protocol MLXModelDownloading: Sendable {
    func download(
        progressHandler: @MainActor @Sendable @escaping (Progress) -> Void
    ) async throws -> URL
}

public struct HuggingFaceMLXModelDownloader: MLXModelDownloading {
    private let client: HubClient

    public init(cacheDirectory: URL) {
        client = HubClient(cache: HubCache(cacheDirectory: cacheDirectory))
    }

    public func download(
        progressHandler: @MainActor @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        try await client.downloadSnapshot(
            of: MLXModelStore.repository,
            revision: MLXModelStore.revision,
            matching: MLXModelStore.downloadPatterns,
            maxConcurrentDownloads: 2,
            progressHandler: progressHandler
        )
    }
}

/// Owns the pinned LFM snapshot on disk. It never performs network I/O until `download()` is called.
@MainActor @Observable
public final class MLXModelStore {
    public nonisolated static let modelID = "LiquidAI/LFM2.5-VL-3B-MLX-4bit"
    public nonisolated static let revision = "7fad79d26092c1145aa8dde873896a07d3e96a3b"
    public nonisolated static let expectedBytes: Int64 = 2_388_157_351
    public nonisolated static let repository: Repo.ID = "LiquidAI/LFM2.5-VL-3B-MLX-4bit"

    nonisolated static let downloadPatterns = ["*.json", "*.jinja", "*.model", "*.safetensors"]
    nonisolated static let requiredFiles = [
        "config.json",
        "model.safetensors",
        "processor_config.json",
        "tokenizer.json",
        "tokenizer_config.json",
    ]

    public private(set) var state: MLXModelDownloadState
    public private(set) var modelDirectory: URL?
    public let rootDirectory: URL

    private let downloader: any MLXModelDownloading
    private let minimumHeadroomBytes: Int64

    public convenience init() {
        let root = URL.applicationSupportDirectory
            .appending(path: "Models/HuggingFace", directoryHint: .isDirectory)
        self.init(
            rootDirectory: root,
            downloader: HuggingFaceMLXModelDownloader(cacheDirectory: root)
        )
    }

    public init(
        rootDirectory: URL,
        downloader: any MLXModelDownloading,
        minimumHeadroomBytes: Int64 = 512 * 1_024 * 1_024
    ) {
        self.rootDirectory = rootDirectory
        self.downloader = downloader
        self.minimumHeadroomBytes = minimumHeadroomBytes
        let snapshot = Self.snapshotDirectory(in: rootDirectory)
        if Self.isComplete(snapshot) {
            state = .ready
            modelDirectory = snapshot
        } else {
            state = .notDownloaded
            modelDirectory = nil
        }
    }

    public var isReady: Bool { modelDirectory != nil }

    /// Starts or resumes the pinned snapshot download and validates it before publishing `ready`.
    public func download() async {
        if case .downloading = state { return }
        do {
            try prepareStorage()
            state = .downloading(completedBytes: 0, totalBytes: Self.expectedBytes)
            let directory = try await downloader.download { [weak self] progress in
                guard let self else { return }
                self.state = .downloading(
                    completedBytes: progress.completedUnitCount,
                    totalBytes: max(progress.totalUnitCount, Self.expectedBytes)
                )
            }
            try Task.checkCancellation()
            guard Self.isComplete(directory) else { throw MLXModelStoreError.incompleteSnapshot }
            try excludeFromBackup()
            modelDirectory = directory
            state = .ready
        } catch is CancellationError {
            refreshFromDisk()
        } catch {
            modelDirectory = nil
            state = .failed(error.localizedDescription)
        }
    }

    public func refreshFromDisk() {
        let snapshot = Self.snapshotDirectory(in: rootDirectory)
        if Self.isComplete(snapshot) {
            modelDirectory = snapshot
            state = .ready
        } else {
            modelDirectory = nil
            state = .notDownloaded
        }
    }

    private func prepareStorage() throws {
        try FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )
        try excludeFromBackup()

        let values = try rootDirectory.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
        ])
        guard let available = values.volumeAvailableCapacityForImportantUsage else { return }
        let remaining = max(0, Self.expectedBytes - Self.allocatedBytes(in: rootDirectory))
        guard available >= remaining + minimumHeadroomBytes else {
            throw MLXModelStoreError.insufficientDiskSpace(
                requiredBytes: remaining + minimumHeadroomBytes,
                availableBytes: available
            )
        }
    }

    private func excludeFromBackup() throws {
        var root = rootDirectory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try root.setResourceValues(values)
    }

    static func snapshotDirectory(in rootDirectory: URL) -> URL {
        let cache = HubCache(cacheDirectory: rootDirectory)
        return try! cache.snapshotPath(
            repo: repository,
            kind: .model,
            commitHash: revision
        )
    }

    static func isComplete(_ directory: URL) -> Bool {
        requiredFiles.allSatisfy {
            FileManager.default.fileExists(atPath: directory.appending(path: $0).path)
        }
    }

    static func allocatedBytes(in directory: URL) -> Int64 {
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .fileSizeKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true
            else { continue }
            total += Int64(
                values.totalFileAllocatedSize
                    ?? values.fileAllocatedSize
                    ?? values.fileSize
                    ?? 0
            )
        }
        return total
    }
}

public enum MLXModelStoreError: LocalizedError, Sendable {
    case incompleteSnapshot
    case insufficientDiskSpace(requiredBytes: Int64, availableBytes: Int64)

    public var errorDescription: String? {
        switch self {
        case .incompleteSnapshot:
            "The downloaded MLX model is incomplete. Retry the download."
        case .insufficientDiskSpace(let required, let available):
            "The MLX model needs \(ByteCountFormatter.string(fromByteCount: required, countStyle: .file)) free, but only \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)) is available."
        }
    }
}
