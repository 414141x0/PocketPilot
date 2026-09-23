import AgentCore
import CoreGraphics
import SwiftUI

struct RunView: View {
    let setup: Setup
    @State private var model = RunModel()
    @State private var goal = ""
    @State private var isShowingSetup = false

    var body: some View {
        NavigationStack {
            List {
                if case .running(let step) = model.phase {
                    ActiveStepCard(step: step, screenshot: model.latestScreenshot)
                }
                ForEach(model.entries) { entry in
                    EntryRow(thought: entry.thought, action: entry.action, failure: entry.failure)
                }
                if let conclusion = model.phase.conclusion {
                    ConclusionRow(conclusion: conclusion)
                }
            }
            .overlay {
                if !setup.isReady {
                    SetupRequiredEmptyState(
                        hasPairing: setup.pairing != nil,
                        hasAPIKey: !setup.openAIKey.isEmpty,
                        brain: setup.brain,
                        onOpenSetup: { isShowingSetup = true }
                    )
                } else if model.entries.isEmpty && !model.isRunning {
                    ContentUnavailableView(
                        "What should I do?",
                        systemImage: "hand.tap",
                        description: Text("Describe a task and PocketPilot will carry it out on this iPhone.")
                    )
                }
            }
            .safeAreaInset(edge: .bottom) {
                GoalField(goal: $goal, isRunning: model.isRunning, isEnabled: setup.isReady) {
                    if let pairing = setup.pairing {
                        model.start(goal, pairing: pairing, pilot: setup.pilot)
                    }
                } stop: {
                    model.stop()
                }
            }
            .navigationTitle("PocketPilot")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ConnectionChip(state: model.connectionState)
                }
                ToolbarItem(placement: .status) {
                    PhaseLabel(phase: model.phase)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Setup", systemImage: "gearshape") { isShowingSetup = true }
                }
            }
            .sheet(isPresented: $isShowingSetup) {
                NavigationStack {
                    SetupView(setup: setup)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done", systemImage: "checkmark") { isShowingSetup = false }
                            }
                        }
                }
            }
            .task {
                isShowingSetup = !setup.isReady
            }
        }
    }
}

private struct ConnectionChip: View {
    let state: Connection.State

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
            Text(statusText)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var dotColor: Color {
        switch state {
        case .disconnected: .secondary
        case .connecting: .blue
        case .connected(let seesScreen): seesScreen ? .green : .yellow
        case .failed: .red
        }
    }

    private var statusText: LocalizedStringResource {
        switch state {
        case .disconnected: "Ready"
        case .connecting: "Connecting…"
        case .connected(let seesScreen): seesScreen ? "Connected" : "CoreDevice"
        case .failed: "Failed"
        }
    }
}

private struct ActiveStepCard: View {
    let step: Int
    let screenshot: CGImage?

    var body: some View {
        HStack(spacing: 12) {
            if let screenshot {
                Image(decorative: screenshot, scale: 1.0, orientation: .up)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 44, height: 78)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(.separator, lineWidth: 0.5)
                    }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Step \(step)")
                        .font(.subheadline.weight(.semibold))
                }
                Text("Observing screen & deciding action…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
        .listRowSeparator(.hidden)
    }
}

private struct ConclusionRow: View {
    let conclusion: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "flag.checkered")
                .foregroundStyle(.secondary)
            Text(conclusion)
                .font(.headline)
        }
        .padding(.vertical, 4)
    }
}

private struct SetupRequiredEmptyState: View {
    let hasPairing: Bool
    let hasAPIKey: Bool
    let brain: Setup.Brain
    let onOpenSetup: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Setup Required", systemImage: "cable.connector.slash")
        } description: {
            VStack(spacing: 8) {
                if !hasPairing {
                    Text("PocketPilot requires a lockdown pairing record to connect to this iPhone.")
                    Text("Keep LocalDevVPN connected so the app can reach local developer services.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if brain == .openAI && !hasAPIKey {
                    Text("Enter your OpenAI API key in Setup to use the cloud model.")
                }
            }
        } actions: {
            Button("Configure Setup", systemImage: "gearshape", action: onOpenSetup)
                .buttonStyle(.borderedProminent)
        }
    }
}

private struct EntryRow: View {
    let thought: String
    let action: String
    let failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !thought.isEmpty {
                Text(thought)
            }
            Text(action)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}

private struct GoalField: View {
    @Binding var goal: String
    let isRunning: Bool
    let isEnabled: Bool
    let start: () -> Void
    let stop: () -> Void

    var body: some View {
        HStack {
            TextField("Turn on Low Power Mode", text: $goal, axis: .vertical)
                .lineLimit(1...4)
                .disabled(isRunning)
                .onSubmit(start)
            if isRunning {
                Button("Stop", systemImage: "stop.fill", action: stop)
            } else {
                Button("Run", systemImage: "arrow.up", action: start)
                    .disabled(!isEnabled || goal.isEmpty)
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.circle)
        .padding()
        .glassEffect(in: .rect(cornerRadius: 24))
        .padding()
    }
}

private struct PhaseLabel: View {
    let phase: RunModel.Phase

    var body: some View {
        switch phase {
        case .idle: EmptyView()
        case .connecting: Label("Connecting", systemImage: "cable.connector")
        case .running(let step): Text("Step \(step)")
        case .finished(.completed): Label("Done", systemImage: "checkmark.circle")
        case .finished(.abandoned): Label("Gave up", systemImage: "xmark.circle")
        case .finished(.outOfSteps): Label("Out of steps", systemImage: "hourglass")
        case .failed: Label("Failed", systemImage: "exclamationmark.octagon")
        }
    }
}
