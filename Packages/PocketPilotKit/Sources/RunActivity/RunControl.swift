/// The slice of RunModel the Live Activity's Stop button needs.
/// Lives here (not in the app) so StopRunIntent compiles in the widget extension.
public protocol RunControl: Sendable {
    @MainActor func stop()
}
