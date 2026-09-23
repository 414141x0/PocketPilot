import AgentCore
import SwiftUI

struct RunView: View {
    let agent: Agent?
    @State private var model = RunModel()
    @State private var goal = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.entries) { entry in
                    EntryRow(thought: entry.thought, action: entry.action, failure: entry.failure)
                }
            }
            .overlay {
                if model.entries.isEmpty {
                    ContentUnavailableView("What should I do?", systemImage: "hand.tap", description: Text("Describe a task and PocketPilot will carry it out on this iPhone."))
                }
            }
            .safeAreaInset(edge: .bottom) {
                GoalField(goal: $goal, isRunning: model.isRunning, isEnabled: agent != nil) {
                    if let agent { model.start(goal, with: agent) }
                } stop: {
                    model.stop()
                }
            }
            .navigationTitle("PocketPilot")
            .toolbar {
                ToolbarItem(placement: .status) {
                    PhaseLabel(phase: model.phase)
                }
            }
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
        case .running(let step): Text("Step \(step)")
        case .finished(.completed): Label("Done", systemImage: "checkmark.circle")
        case .finished(.abandoned): Label("Gave up", systemImage: "xmark.circle")
        case .finished(.outOfSteps): Label("Out of steps", systemImage: "hourglass")
        case .failed: Label("Failed", systemImage: "exclamationmark.octagon")
        }
    }
}
