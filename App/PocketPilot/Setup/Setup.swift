import AgentCore
import DeviceLink
import Foundation
import Observation
import OpenAIPilot
import SystemPilot

/// Everything the user configures once: the device credential and which model flies.
@Observable
final class Setup {
    enum Brain: String, CaseIterable, Identifiable {
        case onDevice, openAI
        var id: Self { self }
    }

    var brain: Brain {
        didSet { UserDefaults.standard.set(brain.rawValue, forKey: "brain") }
    }

    var openAIKey: String {
        didSet { apiKeyItem.write(openAIKey) }
    }

    private(set) var pairing: PairingFile?

    private let apiKeyItem = KeychainItem("openai-api-key")
    private let pairingURL = URL.applicationSupportDirectory.appending(path: "pairing.plist")

    init() {
        brain = UserDefaults.standard.string(forKey: "brain").flatMap(Brain.init) ?? .onDevice
        openAIKey = apiKeyItem.read() ?? ""
        pairing = (try? Data(contentsOf: pairingURL)).flatMap { try? PairingFile(data: $0) }
    }

    var isReady: Bool {
        pairing != nil && (brain == .onDevice || !openAIKey.isEmpty)
    }

    /// The pilot for the chosen brain.
    var pilot: any Pilot {
        switch brain {
        case .onDevice: SystemPilot()
        case .openAI: OpenAIPilot(apiKey: openAIKey)
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
