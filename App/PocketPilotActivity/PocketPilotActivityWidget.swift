import RunActivity
import SwiftUI
import WidgetKit

struct PocketPilotActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RunAttributes.self) { context in
            RunBanner(state: context.state)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    RunExpandedLeading(state: context.state)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Button(intent: StopRunIntent()) {
                        Label("Stop", systemImage: "stop.fill")
                            .labelStyle(.iconOnly)
                    }
                    .tint(.red)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.thought)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            } compactLeading: {
                Text("Step \(context.state.step)")
            } compactTrailing: {
                Image(systemName: "bolt.fill")
            } minimal: {
                Image(systemName: "bolt.fill")
            }
        }
    }
}

/// Lock Screen banner: step progress, last action, thought, and a Stop button.
private struct RunBanner: View {
    let state: RunAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Step \(state.step)")
                    .font(.headline)
                Spacer()
                Button(intent: StopRunIntent()) {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
            Text(state.action)
                .font(.subheadline)
                .lineLimit(1)
            Text(state.thought)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding()
    }
}

/// Dynamic Island expanded leading region: step and last action.
private struct RunExpandedLeading: View {
    let state: RunAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading) {
            Text("Step \(state.step)")
                .font(.headline)
            Text(state.action)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}
