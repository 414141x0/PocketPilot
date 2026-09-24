#if os(iOS)
import AppIntents

/// Stops the current run from the Live Activity UI. Runs headless in the app
/// process, where RunModel is registered as its RunControl dependency.
public struct StopRunIntent: LiveActivityIntent {
    public static let title: LocalizedStringResource = "Stop Run"
    public static let description = IntentDescription("Stop the current PocketPilot run.")
    public static var supportedModes: IntentModes { .background }
    public static var allowedExecutionTargets: IntentExecutionTargets { .main }
    public static var isDiscoverable: Bool { false }

    @Dependency var control: any RunControl

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        control.stop()
        return .result()
    }
}
#endif
