import SwiftUI
import UniformTypeIdentifiers

struct SetupView: View {
    @Bindable var setup: Setup
    @State private var isImporting = false
    @State private var importError: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Pairing file") {
                    Text(setup.pairing == nil ? "Missing" : "Imported")
                        .foregroundStyle(setup.pairing == nil ? .red : .secondary)
                }
                Button("Import Pairing File…", systemImage: "square.and.arrow.down") {
                    isImporting = true
                }
            } header: {
                Text("Device")
            } footer: {
                Text("Keep LocalDevVPN connected while PocketPilot runs. It lets the app reach this iPhone's developer services.")
            }

            Section("Model") {
                Picker("Pilot", selection: $setup.brain) {
                    Text("On-Device").tag(Setup.Brain.onDevice)
                    Text("OpenAI").tag(Setup.Brain.openAI)
                }
                if setup.brain == .openAI {
                    SecureField("API Key", text: $setup.openAIKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                }
            }
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
