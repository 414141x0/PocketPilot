import AgentCore
import DeviceLink
import Foundation
import GeminiPilot
import MLXPilot
import Observation
import OpenAIPilot
import SystemPilot

/// Everything the user configures once: the device credential and which model flies.
@Observable
final class Setup {
    enum Brain: String, CaseIterable, Identifiable {
        case onDevice, localMLX, openAI, gemini
        var id: Self { self }
    }

    var brain: Brain {
        didSet { UserDefaults.standard.set(brain.rawValue, forKey: "brain") }
    }

    var openAIKey: String {
        didSet { apiKeyItem.write(openAIKey) }
    }

    var geminiKey: String {
        didSet { geminiKeyItem.write(geminiKey) }
    }

    private(set) var pairing: PairingFile?
    let mlxModel = MLXModelStore()

    private let apiKeyItem = KeychainItem("openai-api-key")
    private let geminiKeyItem = KeychainItem("gemini-api-key")
    private let pairingURL = URL.applicationSupportDirectory.appending(path: "pairing.plist")
    private var mlxDownloadTask: Task<Void, Never>?
    private var cachedMLXPilot: MLXPilot?

    init() {
        brain = UserDefaults.standard.string(forKey: "brain").flatMap(Brain.init) ?? .onDevice
        openAIKey = apiKeyItem.read() ?? ""
        geminiKey = geminiKeyItem.read() ?? ""
        pairing = (try? Data(contentsOf: pairingURL)).flatMap { try? PairingFile(data: $0) }
    }

    var isReady: Bool {
        guard pairing != nil else { return false }
        switch brain {
        case .onDevice: return true
        case .localMLX: return mlxModel.isReady
        case .openAI: return !openAIKey.isEmpty
        case .gemini: return !geminiKey.isEmpty
        }
    }

    var hasAPIKey: Bool {
        switch brain {
        case .onDevice, .localMLX: true
        case .openAI: !openAIKey.isEmpty
        case .gemini: !geminiKey.isEmpty
        }
    }

    /// The pilot for the chosen brain.
    var pilot: any Pilot {
        switch brain {
        case .onDevice: return SystemPilot()
        case .localMLX:
            if let cachedMLXPilot { return cachedMLXPilot }
            guard let directory = mlxModel.modelDirectory,
                  let pilot = try? MLXPilot(modelDirectory: directory) else {
                return SystemPilot()
            }
            cachedMLXPilot = pilot
            return pilot
        case .openAI: return OpenAIPilot(apiKey: openAIKey)
        case .gemini: return GeminiPilot(apiKey: geminiKey)
        }
    }

    /// The pilot for the chosen brain, throwing SetupError if MLX model is missing.
    func makePilot() throws -> any Pilot {
        switch brain {
        case .onDevice: return SystemPilot()
        case .localMLX:
            if let cachedMLXPilot { return cachedMLXPilot }
            guard let directory = mlxModel.modelDirectory else {
                throw SetupError.mlxModelNotDownloaded
            }
            let pilot = try MLXPilot(modelDirectory: directory)
            cachedMLXPilot = pilot
            return pilot
        case .openAI: return OpenAIPilot(apiKey: openAIKey)
        case .gemini: return GeminiPilot(apiKey: geminiKey)
        }
    }

    var isDownloadingMLX: Bool { mlxDownloadTask != nil }

    func downloadMLX() {
        guard mlxDownloadTask == nil else { return }
        mlxDownloadTask = Task {
            await mlxModel.download()
            mlxDownloadTask = nil
        }
    }

    func cancelMLXDownload() {
        mlxDownloadTask?.cancel()
        mlxDownloadTask = nil
    }

    /// Validates and stores a pairing file picked by the user.
    func importPairing(from url: URL) throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let pairing = try PairingFile(data: Data(contentsOf: url))
        try FileManager.default.createDirectory(at: .applicationSupportDirectory, withIntermediateDirectories: true)
        try pairing.data.write(to: pairingURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        self.pairing = pairing
    }
}

enum SetupError: LocalizedError {
    case mlxModelNotDownloaded

    var errorDescription: String? {
        switch self {
        case .mlxModelNotDownloaded:
            "Download the Local MLX model in Setup before starting a run."
        }
    }
}
