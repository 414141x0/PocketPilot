import DeviceLink
import SwiftUI
import UniformTypeIdentifiers

struct SetupView: View {
    @Bindable var setup: Setup
    @State private var isImporting = false
    @State private var importError: String?

    var body: some View {
        Form {
            DeviceSection(
                hasPairing: setup.pairing != nil,
                udid: setup.pairing?.udid,
                onImport: { isImporting = true }
            )
            ModelSection(
                brain: $setup.brain,
                openAIKey: $setup.openAIKey,
                geminiKey: $setup.geminiKey
            )
        }
        .navigationTitle("Setup")
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.propertyList, .data]) { result in
            do {
                try setup.importPairing(from: result.get())
            } catch {
                importError = String(describing: error)
            }
        }
        .alert("Couldn't Import Pairing File", item: $importError) { _ in
            Button("OK") {}
        } message: { error in
            Text(error)
        }
    }
}

private struct DeviceSection: View {
    let hasPairing: Bool
    let udid: String?
    let onImport: () -> Void

    var body: some View {
        Section {
            LabeledContent("Pairing record") {
                HStack(spacing: 6) {
                    Circle()
                        .fill(hasPairing ? .green : .red)
                        .frame(width: 8, height: 8)
                    Text(hasPairing ? LocalizedStringResource("Imported") : "Missing")
                        .foregroundStyle(hasPairing ? Color.secondary : Color.red)
                }
            }
            if let udid {
                LabeledContent("UDID") {
                    Text(udid)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            Button("Import Pairing File…", systemImage: "square.and.arrow.down", action: onImport)
        } header: {
            Text("Device")
        } footer: {
            Text("Join a Wi-Fi network (any network works — no internet needed), then connect LocalDevVPN. iOS only exposes this iPhone's developer services while joined to Wi-Fi, even though traffic stays on this device.")
        }
    }
}

private struct ModelSection: View {
    @Binding var brain: Setup.Brain
    @Binding var openAIKey: String
    @Binding var geminiKey: String

    private let onDeviceNote: LocalizedStringResource = "Runs entirely on this iPhone with Apple's on-device model."
    private let openAINote: LocalizedStringResource = "Sends each screenshot to OpenAI. Your API key is stored in the Keychain."
    private let geminiNote: LocalizedStringResource = "Sends each screenshot to Google Gemini. Your API key is stored in the Keychain."

    var body: some View {
        Section {
            Picker("Pilot", selection: $brain) {
                Text("On-Device").tag(Setup.Brain.onDevice)
                Text("OpenAI").tag(Setup.Brain.openAI)
                Text("Gemini").tag(Setup.Brain.gemini)
            }
            switch brain {
            case .openAI:
                SecureField("API Key", text: $openAIKey)
                    .textContentType(.password)
                    .autocorrectionDisabled()
            case .gemini:
                SecureField("API Key", text: $geminiKey)
                    .textContentType(.password)
                    .autocorrectionDisabled()
            case .onDevice:
                EmptyView()
            }
        } header: {
            Text("Model")
        } footer: {
            Text(footerNote)
        }
    }

    private var footerNote: LocalizedStringResource {
        switch brain {
        case .onDevice: onDeviceNote
        case .openAI: openAINote
        case .gemini: geminiNote
        }
    }
}

