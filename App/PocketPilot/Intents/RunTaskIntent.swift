import AppIntents
import Foundation

struct RunTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Task"
    static let description = IntentDescription("Carry out a task on this iPhone using PocketPilot.")
    static var supportedModes: IntentModes { .foreground }

    @Parameter(title: "Goal", description: "The task to perform on the iPhone")
    var goal: String

    static var parameterSummary: some ParameterSummary {
        Summary("Run \(\.$goal) on this iPhone")
    }

    @Dependency private var setup: Setup
    @Dependency private var model: RunModel

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard setup.isReady, let pairing = setup.pairing else {
            throw RunTaskError.setupIncomplete
        }
        guard !model.isRunning else {
            throw RunTaskError.alreadyRunning
        }

        guard let pilot = try? setup.makePilot() else {
            throw RunTaskError.setupIncomplete
        }
        model.start(goal, pairing: pairing, pilot: pilot)
        return .result(dialog: "Starting task: \(goal)")
    }
}

enum RunTaskError: Error, CustomLocalizedStringResourceConvertible {
    case setupIncomplete
    case alreadyRunning

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .setupIncomplete:
            "PocketPilot is not configured yet. Open the app to complete device setup."
        case .alreadyRunning:
            "PocketPilot is already running a task. Stop the current task before starting a new one."
        }
    }
}

struct PocketPilotShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RunTaskIntent(),
            phrases: [
                "Ask \(.applicationName) to run a task",
                "Run a task with \(.applicationName)",
                "Carry out a task with \(.applicationName)",
                "Start a task in \(.applicationName)"
            ],
            shortTitle: "Run Task",
            systemImageName: "hand.tap"
        )
    }
}
