import DeviceLink
import MLXPilot
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
                mlxState: setup.mlxModel.state,
                isDownloadingMLX: setup.isDownloadingMLX,
                onDownloadMLX: setup.downloadMLX,
                onCancelMLX: setup.cancelMLXDownload
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
            Text("Keep LocalDevVPN connected while PocketPilot runs. It loops traffic back to this iPhone, so the app can reach its developer services without a Mac.")
        }
    }
}

private struct ModelSection: View {
    @Binding var brain: Setup.Brain
    @Binding var openAIKey: String
    let mlxState: MLXModelDownloadState
    let isDownloadingMLX: Bool
    let onDownloadMLX: () -> Void
    let onCancelMLX: () -> Void

    private let onDeviceNote: LocalizedStringResource = "Runs entirely on this iPhone with Apple's on-device model."
    private let mlxNote: LocalizedStringResource = "Runs LiquidAI LFM2.5-VL locally with MLX. The pinned model uses about 2.2 GB of storage."
    private let openAINote: LocalizedStringResource = "Sends each screenshot to OpenAI. Your API key is stored in the Keychain."

    var body: some View {
        Section {
            Picker("Pilot", selection: $brain) {
                Text("On-Device").tag(Setup.Brain.onDevice)
                Text("Local MLX (LFM2.5-VL)").tag(Setup.Brain.localMLX)
                Text("OpenAI").tag(Setup.Brain.openAI)
            }
            if brain == .openAI {
                SecureField("API Key", text: $openAIKey)
                    .textContentType(.password)
                    .autocorrectionDisabled()
            } else if brain == .localMLX {
                MLXDownloadRow(
                    state: mlxState,
                    isDownloading: isDownloadingMLX,
                    onDownload: onDownloadMLX,
                    onCancel: onCancelMLX
                )
            }
        } header: {
            Text("Model")
        } footer: {
            switch brain {
            case .onDevice: Text(onDeviceNote)
            case .localMLX: Text(mlxNote)
            case .openAI: Text(openAINote)
            }
        }
    }
}

private struct MLXDownloadRow: View {
    let state: MLXModelDownloadState
    let isDownloading: Bool
    let onDownload: () -> Void
    let onCancel: () -> Void

    var body: some View {
        switch state {
        case .notDownloaded:
            Button("Download Model (2.2 GB)", systemImage: "arrow.down.circle", action: onDownload)
        case .downloading(let completed, let total):
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: state.fractionCompleted)
                Text("Downloaded \(completed.formatted(.byteCount(style: .file))) of \(total.formatted(.byteCount(style: .file)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Cancel Download", systemImage: "xmark", role: .cancel, action: onCancel)
            }
        case .ready:
            Label("Model Ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                Button("Retry Download", systemImage: "arrow.clockwise", action: onDownload)
            }
        }
    }
}
