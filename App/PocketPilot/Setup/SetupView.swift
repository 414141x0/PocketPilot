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
                openAIKey: $setup.openAIKey
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
                    Text(hasPairing ? "Imported" : "Missing")
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
            Text("Keep LocalDevVPN connected while PocketPilot runs. It routes traffic back to this iPhone's RSD port so the app can reach on-device developer services without a tethered Mac.")
        }
    }
}

private struct ModelSection: View {
    @Binding var brain: Setup.Brain
    @Binding var openAIKey: String

    var body: some View {
        Section {
            Picker("Pilot", selection: $brain) {
                Text("On-Device").tag(Setup.Brain.onDevice)
                Text("OpenAI").tag(Setup.Brain.openAI)
            }
            if brain == .openAI {
                SecureField("API Key", text: $openAIKey)
                    .textContentType(.password)
                    .autocorrectionDisabled()
            }
        } header: {
            Text("Model")
        } footer: {
            Text(brain == .onDevice
                ? "Runs completely on-device using Apple Intelligence FoundationModels."
                : "Calls OpenAI Responses API using your API key stored securely in Keychain.")
        }
    }
}

