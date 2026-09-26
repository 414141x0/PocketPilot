import AgentCore
import DeviceLink
import Foundation
import GeminiPilot
import Observation
import OpenAIPilot
import SystemPilot

/// Everything the user configures once: the device credential and which model flies.
@Observable
final class Setup {
    enum Brain: String, CaseIterable, Identifiable {
        case onDevice, openAI, gemini
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

    private let apiKeyItem = KeychainItem("openai-api-key")
    private let geminiKeyItem = KeychainItem("gemini-api-key")
    private let pairingURL = URL.applicationSupportDirectory.appending(path: "pairing.plist")

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
        case .openAI: return !openAIKey.isEmpty
        case .gemini: return !geminiKey.isEmpty
        }
    }

    var hasAPIKey: Bool {
        switch brain {
        case .onDevice: true
        case .openAI: !openAIKey.isEmpty
        case .gemini: !geminiKey.isEmpty
        }
    }

    /// The pilot for the chosen brain.
    var pilot: any Pilot {
        switch brain {
        case .onDevice: SystemPilot()
        case .openAI: OpenAIPilot(apiKey: openAIKey)
        case .gemini: GeminiPilot(apiKey: geminiKey)
        }
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
